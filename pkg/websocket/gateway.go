// Package websocket implements the production live-gateway for the Mogok
// Maung betting platform:
//
//	/ws/live-odds      — real-time odds fan-out to authenticated clients
//	                     (mobile app, web). Frames are JSON envelopes
//	                     {"type":"odds_update","data":{snapshot...}} that
//	                     match the Flutter LiveOddsEnvelope wire contract.
//	/ws/agent/requests — real-time AGENT/SUPER_ADMIN push of bot deposit /
//	                     withdraw requests drained from the AMQP
//	                     `agent_unit_request_queue`.
//
// The gateway follows the "epoll / goroutine high-throughput" production
// spec: Redis Pub/Sub is the fan-out backbone (so API replicas share a single
// stream), and each connected client gets one buffered outbound channel plus
// a dedicated write goroutine. The Go runtime multiplexes those goroutines on
// the epoll scheduler — no manual epoll loop required.
package websocket

import (
	"context"
	"log/slog"
	"time"

	"github.com/go-redis/redis/v8"
	"github.com/gorilla/websocket"

	"mogok-maung-backend/pkg/models"
)

// LiveOddsChannel is the Redis Pub/Sub channel the admin API publishes
// odds-update envelopes to and every gateway replica subscribes to.
const LiveOddsChannel = "live_odds_channel"

// liveBroadcastBuffer bounds fan-out buffering; live odds are self-correcting
// (the next tick overwrites a dropped frame), so dropping under pressure is
// correct behaviour.
const liveBroadcastBuffer = 10_000

// agentBroadcastBuffer bounds AgentDashboard fan-out. Requests stay durable
// in the queue + unit_requests table, so a drop under load only delays a
// notification that the dashboard can pull.
const agentBroadcastBuffer = 10_000

// pingPeriod / pongWait / writeWait are the keep-alive tuning: the server
// pings every 30s and drops dead peers after 90s of silence.
const (
	pingPeriod = 30 * time.Second
	pongWait   = 90 * time.Second
	writeWait  = 10 * time.Second
)

// Client is one upgraded WebSocket peer. All outbound frames flow through the
// buffered send channel consumed by writePump — writes are serialised so
// concurrent broadcasts can never issue overlapping frames on a single conn.
type Client struct {
	hub  *Hub
	conn *websocket.Conn
	send chan []byte
	role models.UserRole
}

// Hub manages client lifecycle and role-scoped fan-out.
type Hub struct {
	rdb *redis.Client

	// register / unregister / broadcast channels are consumed by the single
	// Run loop, so the client map is only touched from one goroutine.
	register   chan *Client
	unregister chan *Client
	live       chan []byte
	agent      chan []byte

	// clients holds every connected peer; /ws/live-odds reaches all of them,
	// /ws/agent/requests only the AGENT + SUPER_ADMIN subset.
	clients map[*Client]struct{}

	done   chan struct{}
	logger *slog.Logger
}

// NewHub builds a Hub backed by the given Redis client. Pass a non-nil rdb to
// enable live odds; run AgentConsumerLoop separately to feed /ws/agent/requests.
func NewHub(rdb *redis.Client) *Hub {
	h := &Hub{
		rdb:        rdb,
		register:   make(chan *Client),
		unregister: make(chan *Client),
		live:       make(chan []byte, liveBroadcastBuffer),
		agent:      make(chan []byte, agentBroadcastBuffer),
		clients:    make(map[*Client]struct{}),
		done:       make(chan struct{}),
		logger:     slog.Default(),
	}
	return h
}

// Run is the single-threaded lifecycle loop. Launch as a goroutine at startup;
// it exits when ctx is cancelled.
func (h *Hub) Run(ctx context.Context) {
	defer close(h.done)
	logger := slog.Default()
	for {
		select {
		case c := <-h.register:
			h.clients[c] = struct{}{}
			logger.Debug("ws: client registered", "role", c.role)

		case c := <-h.unregister:
			if _, ok := h.clients[c]; ok {
				delete(h.clients, c)
				close(c.send)
				_ = c.conn.Close()
				logger.Debug("ws: client unregistered", "role", c.role)
			}

		case payload := <-h.live:
			for c := range h.clients {
				h.enqueue(c, payload, true)
			}

		case payload := <-h.agent:
			for c := range h.clients {
				if c.role == models.RoleAgent || c.role == models.RoleSuperAdmin {
					h.enqueue(c, payload, false)
				}
			}

		case <-ctx.Done():
			logger.Info("ws: hub shutting down")
			for c := range h.clients {
				close(c.send)
				_ = c.conn.Close()
			}
			h.clients = map[*Client]struct{}{}
			return
		}
	}
}

// Done reports when the Run loop has exited.
func (h *Hub) Done() <-chan struct{} {
	return h.done
}

// Ping reports Redis connectivity for the /health probe. Returns nil when the
// gateway is backed by a reachable Redis, or an error when the cache is down.
func (h *Hub) Ping(ctx context.Context) error {
	return h.rdb.Ping(ctx).Err()
}

// enqueue forwards a frame to a client without blocking the broadcast loop.
// Live frames are dropped when a client's buffer is full (next tick replaces
// them); agent frames are also dropped rather than stalling the fan-out
// because the source request is already durable.
func (h *Hub) enqueue(c *Client, payload []byte, dropWhenFull bool) {
	select {
	case c.send <- payload:
	default:
		if !dropWhenFull {
			// Try once more with a slim timeout so an agent request is almost
			// never lost to a transiently full buffer.
			select {
			case c.send <- payload:
			case <-time.After(50 * time.Millisecond):
			}
		}
	}
}

// BroadcastLive and BroadcastAgent queue frames into the fan-out channels.
// They never block: the Run loop drains them, dropping under pressure.
func (h *Hub) BroadcastLive(payload []byte) {
	select {
	case h.live <- payload:
	default:
		h.logger.Warn("ws: live broadcast overflow, frame dropped")
	}
}

func (h *Hub) BroadcastAgent(payload []byte) {
	select {
	case h.agent <- payload:
	default:
		h.logger.Warn("ws: agent broadcast overflow, frame dropped")
	}
}
