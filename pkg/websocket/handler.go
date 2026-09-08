package websocket

import (
	"context"
	"database/sql"
	"log/slog"
	"net/http"
	"time"

	"github.com/gorilla/websocket"

	"mogok-maung-backend/pkg/auth"
	"mogok-maung-backend/pkg/models"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 65536,
	// The app is served behind Cloudflare/ALB which mediate CORS for the
	// normal AUTHENTICATED JSON API; WebSocket upgrade carries its own
	// token and a browser origin check is not meaningful here.
	CheckOrigin: func(r *http.Request) bool { return true },
}

const wsReadLimit = 512

// wsAuthorize resolves the principal from the ?token=JWT query param (used by
// the mobile/web WS clients that cannot set custom headers on upgrade) and
// falls back to the standard Authorization: Bearer header.
func wsAuthorize(r *http.Request, jwtSecret string) (auth.Principal, bool) {
	token := r.URL.Query().Get("token")
	if token == "" {
		token = bearerToken(r.Header.Get("Authorization"))
	}
	if token == "" {
		return auth.Principal{}, false
	}
	claims, err := auth.ParseToken(token, []byte(jwtSecret))
	if err != nil {
		slog.Warn("ws: rejected token", "error", err)
		return auth.Principal{}, false
	}
	return auth.Principal{UserID: claims.UserID, Role: claims.Role}, true
}

func bearerToken(header string) string {
	const prefix = "Bearer "
	if len(header) > len(prefix) && header[:len(prefix)] == prefix {
		return header[len(prefix):]
	}
	return ""
}

// serveConnection upgrades the request and registers a client. onReady, when
// non-nil, runs right after registration so the caller can queue an initial
// snapshot (e.g. current live fixtures) to the fresh connection.
func (h *Hub) serveConnection(w http.ResponseWriter, r *http.Request,
	role models.UserRole, onReady func(*Client)) {

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		slog.Warn("ws: upgrade failed", "error", err)
		return
	}

	client := &Client{
		hub:  h,
		conn: conn,
		send: make(chan []byte, 256),
		role: role,
	}

	h.register <- client
	if onReady != nil {
		onReady(client)
	}

	go h.writePump(client)
	go h.readPump(client)
}

// HandleLiveOdds upgrades /ws/live-odds. Any authenticated role may connect.
// The client immediately receives the current OPEN/SUSPENDED snapshot, then
// hands off to the Redis fan-out.
func (h *Hub) HandleLiveOdds(db *sql.DB, jwtSecret string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		p, ok := wsAuthorize(r, jwtSecret)
		if !ok {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}

		h.serveConnection(w, r, p.Role, func(c *Client) {
			snaps, err := BuildAllLiveSnapshots(context.Background(), db)
			if err != nil {
				slog.Warn("ws: initial live snapshot failed", "error", err)
				return
			}
			for i := range snaps {
				frame, err := MarshalOddsFrame(snaps[i])
				if err != nil {
					slog.Warn("ws: marshal initial snapshot", "match", snaps[i].MatchID, "error", err)
					continue
				}
				h.enqueue(c, frame, true)
			}
		})
	}
}

// HandleAgentRequests upgrades /ws/agent/requests. Only AGENT and SUPER_ADMIN
// principals may connect; inbound AMQP frames are filtered to the same set in
// the Hub Run loop, so a client session never sees another tier's events.
func (h *Hub) HandleAgentRequests(jwtSecret string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		p, ok := wsAuthorize(r, jwtSecret)
		if !ok {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		if p.Role != models.RoleAgent && p.Role != models.RoleSuperAdmin {
			http.Error(w, `{"error":"forbidden"}`, http.StatusForbidden)
			return
		}
		h.serveConnection(w, r, p.Role, nil)
	}
}

// writePump serialises outbound writes for one client: 30s pings keep
// middleboxes (Cloudflare/ALB) from dropping the "idle" connection.
func (h *Hub) writePump(c *Client) {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		_ = c.conn.Close()
	}()

	for {
		select {
		case payload, ok := <-c.send:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				// Hub closed the send channel — terminate politely.
				_ = c.conn.WriteMessage(websocket.CloseMessage, nil)
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, payload); err != nil {
				h.unregisterClient(c)
				return
			}
		case <-ticker.C:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				h.unregisterClient(c)
				return
			}
		}
	}
}

// unregisterClient requests removal without blocking; the Hub Run loop may be
// mid-shutdown, in which case the map is already being cleared.
func (h *Hub) unregisterClient(c *Client) {
	select {
	case h.unregister <- c:
	default:
	}
}

// readPump consumes (and discards) client frames; this gateway is push-only.
// A missing pong or a client-initiated close trips the unregister path.
func (h *Hub) readPump(c *Client) {
	defer h.unregisterClient(c)
	c.conn.SetReadLimit(wsReadLimit)
	_ = c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(pongWait))
	})
	for {
		// ReadMessage also processes control frames (ping/pong/close).
		if _, _, err := c.conn.ReadMessage(); err != nil {
			return
		}
	}
}
