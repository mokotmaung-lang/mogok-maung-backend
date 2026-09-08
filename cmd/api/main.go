package main

import (
	"context"
	"log"
	"net"
	"net/http"
	"os"

	"github.com/go-redis/redis/v8"

	"mogok-maung-backend/pkg/database"
	"mogok-maung-backend/pkg/httpapi"
	"mogok-maung-backend/pkg/websocket"
	"mogok-maung-backend/pkg/worker"
)

func main() {
	db, err := database.Connect(database.DefaultConfig())
	if err != nil {
		log.Fatal("Failed to connect to database:", err)
	}
	defer db.Close()

	log.Println("Database connection healthy")

	// Auto-apply pending schema migrations on boot (production spec).
	// Disable with AUTO_MIGRATE=false when migrations run out-of-band.
	if os.Getenv("AUTO_MIGRATE") != "false" {
		dir := database.NormalizeMigrationDir(os.Getenv("MIGRATIONS_DIR"))
		if err := database.NewMigrator(db, dir).Run(context.Background()); err != nil {
			log.Fatal("Database migration failed:", err)
		}
	}

	jwtSecret := os.Getenv("JWT_SECRET")
	if jwtSecret == "" {
		log.Println("WARNING: JWT_SECRET not set, using insecure development secret")
		jwtSecret = "dev-insecure-change-me"
	}

	// Match-result dispatch: when the admin records a final result we enqueue a
	// SettlementEvent for the worker's match_settlement_queue. Without AMQP_URL
	// results still persist to DB; only worker notification is skipped.
	var onMatchResult func(ctx context.Context, ev worker.SettlementEvent)
	amqpURL := os.Getenv("AMQP_URL")
	if amqpURL != "" {
		pub := worker.NewPublisher(amqpURL, os.Getenv("SETTLEMENT_QUEUE"))
		onMatchResult = func(ctx context.Context, ev worker.SettlementEvent) {
			if err := pub.PublishMatchResult(ctx, ev); err != nil {
				log.Printf("WARNING: result dispatched for match %d but broker publish failed: %v", ev.MatchID, err)
			}
		}
	} else {
		log.Println("WARNING: AMQP_URL not set; match results will not be dispatched to the settlement worker")
	}

	// Realtime gateway: Redis Pub/Sub fan-out for /ws/live-odds plus the AMQP
	// agent-request consumer that feeds /ws/agent/requests. Both degrade
	// gracefully — no Redis/broker means no WS endpoints and no fan-out, and
	// the REST + settlement paths keep working exactly as before.
	redisAddr := redisAddress()
	var live *websocket.Hub
	var onOddsChange func(ctx context.Context, matchID int64, payload interface{})

	if redisAddr != "" {
		rdb := redis.NewClient(&redis.Options{
			Addr:     redisAddr,
			Password: os.Getenv("REDIS_PASSWORD"),
		})
		if err := rdb.Ping(context.Background()).Err(); err != nil {
			log.Printf("WARNING: Redis unreachable at %s (%v); live gateway disabled", redisAddr, err)
		} else {
			live = websocket.NewHub(rdb)
			go live.Run(context.Background())
			go live.SubscribeLoop(context.Background())

			if amqpURL != "" {
				queue := os.Getenv("AGENT_UNIT_REQUEST_QUEUE")
				if queue == "" {
					queue = "agent_unit_request_queue"
				}
				go live.AgentConsumerLoop(context.Background(), amqpURL, queue)
				log.Printf("Realtime gateway enabled (redis=%s, agent queue=%s)", redisAddr, queue)
			} else {
				log.Printf("Realtime gateway enabled (redis=%s); agent-request fan-out disabled (no AMQP_URL)", redisAddr)
			}

			// Build the fresh snapshot and push it through Redis after every
			// admin status/odds commit; replicas re-broadcast to their peers.
			onOddsChange = func(ctx context.Context, matchID int64, _ interface{}) {
				snap, err := websocket.BuildSnapshot(ctx, db, matchID)
				if err != nil {
					log.Printf("WARNING: live-odds snapshot for match %d failed: %v", matchID, err)
					return
				}
				frame, err := websocket.MarshalOddsFrame(snap)
				if err != nil {
					log.Printf("WARNING: marshal live-odds snapshot %d: %v", matchID, err)
					return
				}
				if err := rdb.Publish(ctx, websocket.LiveOddsChannel, frame).Err(); err != nil {
					log.Printf("WARNING: publish live-odds snapshot %d: %v", matchID, err)
				}
			}
		}
	} else {
		log.Println("WARNING: REDIS_ADDR/REDIS_HOST not set; realtime gateway disabled")
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	handler := httpapi.NewRouter(db, jwtSecret, onMatchResult, live, onOddsChange)

	log.Printf("Server starting on port %s", port)
	log.Fatal(http.ListenAndServe(":"+port, handler))
}

// redisAddress resolves the Redis address from REDIS_ADDR (host:port) or, for
// compose/ElastiCache, REDIS_HOST plus optional REDIS_PORT. Empty string means
// "realtime gateway disabled".
func redisAddress() string {
	if a := os.Getenv("REDIS_ADDR"); a != "" {
		return a
	}
	host := os.Getenv("REDIS_HOST")
	if host == "" {
		return ""
	}
	port := os.Getenv("REDIS_PORT")
	if port == "" {
		port = "6379"
	}
	return net.JoinHostPort(host, port)
}
