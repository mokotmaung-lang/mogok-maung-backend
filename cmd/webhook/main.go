package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"mogok-maung-backend/pkg/amqpcfg"
	"mogok-maung-backend/pkg/database"
	"mogok-maung-backend/pkg/worker"
)

// BotWebhookPayload is the normalized message shape the agent's Viber/Telegram
// bot forwards to this service: the platform's unique sender id, the platform
// name and the free-text instruction (e.g. "DEPOSIT 5000"). The draft used a
// shadowing `SenderID String` (and a `type String string` at file scope that
// breaks the builtin) — both fixed here.
type BotWebhookPayload struct {
	SenderID string `json:"sender_id"`
	Platform string `json:"platform"` // "VIBER" | "TELEGRAM"
	Message  string `json:"message"`
}

// unitRequestEvent is what the worker pushes to the agent dashboard via AMQP
// the moment a bot request is persisted as PENDING.
type unitRequestEvent struct {
	Type       string    `json:"type"`
	RequestID  int64     `json:"request_id"`
	UserID     int64     `json:"user_id"`
	Platform   string    `json:"platform"`
	ActionType string    `json:"action_type"`
	Amount     float64   `json:"amount"`
	CreatedAt  time.Time `json:"created_at"`
}

// BotWebhookServer verifies inbound bot traffic, maps sender ids to platform
// users, writes audit-trailed PENDING unit_requests and fans the event out to
// the agent dashboard over AMQP.
type BotWebhookServer struct {
	db        *sql.DB
	publisher *worker.Publisher

	telegramSecret string // X-Telegram-Bot-Api-Secret-Token expected value
	viberToken     string // account token used as HMAC key for Viber bodies
}

func (s *BotWebhookServer) HandleBotRequest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Cap the body so a malicious platform cannot exhaust memory.
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)

	var payload BotWebhookPayload
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		http.Error(w, `{"error":"bad request"}`, http.StatusBadRequest)
		return
	}

	platform := strings.ToUpper(strings.TrimSpace(payload.Platform))
	if platform != "VIBER" && platform != "TELEGRAM" {
		http.Error(w, `{"error":"unknown platform"}`, http.StatusBadRequest)
		return
	}

	// Verify authenticity BEFORE trusting any field. Telegram signs webhooks
	// with X-Telegram-Bot-Api-Secret-Token; Viber signs the raw body with an
	// HMAC-SHA256 over the account token.
	if platform == "TELEGRAM" {
		if s.telegramSecret == "" {
			slog.Error("telegram webhook secret not configured")
			http.Error(w, `{"error":"server not configured"}`, http.StatusInternalServerError)
			return
		}
		if !secureEquals(r.Header.Get("X-Telegram-Bot-Api-Secret-Token"), s.telegramSecret) {
			slog.Warn("telegram webhook rejected: bad secret token")
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
	} else if !s.verifyViberSignature(r) {
		slog.Warn("viber webhook rejected: bad signature")
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}

	if strings.TrimSpace(payload.SenderID) == "" {
		http.Error(w, `{"error":"sender_id required"}`, http.StatusBadRequest)
		return
	}

	actionType, amount, err := parseInstruction(payload.Message)
	if err != nil {
		http.Error(w, `{"error":"invalid message format. Use: DEPOSIT 5000 or WITHDRAW 10000"}`, http.StatusBadRequest)
		return
	}

	// Map the platform sender to its active link (404: user never paired the
	// bot — they must complete the pairing flow from the app first).
	userID, err := s.resolveUserID(r.Context(), platform, payload.SenderID)
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, `{"error":"sender is not linked to an active account"}`, http.StatusNotFound)
		return
	}
	if err != nil {
		slog.Error("resolve bot sender", "platform", platform, "error", err)
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	requestID, alreadyPending, err := s.persistRequest(ctx, userID, actionType, amount, platform, payload.SenderID)
	if err != nil {
		slog.Error("persist bot unit request", "user_id", userID, "error", err)
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	// Real-time push to the agent dashboard. Best-effort: the PENDING row is
	// already durable; the dashboard can always pull the backend again. A
	// redelivered request goes out with already_pending=true so dashboards can
	// dedupe.
	if pubErr := s.publisher.Publish(ctx, requestID, "unit_request",
		unitRequestEvent{
			Type:       "unit_request_created",
			RequestID:  requestID,
			UserID:     userID,
			Platform:   platform,
			ActionType: actionType,
			Amount:     amount,
			CreatedAt:  time.Now().UTC(),
		}); pubErr != nil {
		slog.Warn("publish unit request event failed", "request_id", requestID, "error", pubErr)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"success":         true,
		"message":         "တောင်းဆိုမှုအား အေးဂျင့်ထံ ပို့ဆောင်ပြီးပါပြီ။",
		"request_id":      requestID,
		"already_pending": alreadyPending,
	})
}

// verifyViberSignature checks X-Viber-Content-Signature (hex HMAC-SHA256 of
// the raw body using the account token). The body is consumed once and then
// restored for the JSON decoder.
func (s *BotWebhookServer) verifyViberSignature(r *http.Request) bool {
	if s.viberToken == "" {
		slog.Error("viber auth token not configured")
		return false
	}

	raw, err := io.ReadAll(r.Body)
	if err != nil {
		return false
	}
	r.Body = io.NopCloser(bytes.NewReader(raw))

	expected := r.Header.Get("X-Viber-Content-Signature")
	if expected == "" {
		return false
	}

	mac := hmac.New(sha256.New, []byte(s.viberToken))
	_, _ = mac.Write(raw)
	got := hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(got), []byte(expected))
}

// resolveUserID looks up the active bot_links entry for the platform sender.
func (s *BotWebhookServer) resolveUserID(ctx context.Context, platform, senderID string) (int64, error) {
	var userID int64
	err := s.db.QueryRowContext(ctx, `
		SELECT user_id
		  FROM bot_links
		 WHERE platform = $1 AND platform_user_id = $2 AND is_active = TRUE`,
		platform, senderID,
	).Scan(&userID)
	return userID, err
}

// persistRequest writes the PENDING unit_request with bot metadata in
// payment_info. A duplicate instruction inside the 60s window is treated as a
// bot/network redelivery and returns the existing request (idempotent).
func (s *BotWebhookServer) persistRequest(ctx context.Context, userID int64, actionType string, amount float64, platform, senderID string) (int64, bool, error) {
	var existing int64
	err := s.db.QueryRowContext(ctx, `
		SELECT id FROM unit_requests
		 WHERE requester_id = $1 AND type = $2 AND status = 'PENDING'
		   AND created_at > CURRENT_TIMESTAMP - INTERVAL '60 seconds'
		 ORDER BY id DESC LIMIT 1`,
		userID, actionType,
	).Scan(&existing)
	if err == nil {
		return existing, true, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, false, err
	}

	meta, _ := json.Marshal(map[string]interface{}{
		"platform":         platform,
		"platform_user_id": senderID,
		"source":           "bot_webhook",
	})

	var requestID int64
	err = s.db.QueryRowContext(ctx, `
		INSERT INTO unit_requests (requester_id, amount, type, status, payment_info)
		VALUES ($1, $2, $3, 'PENDING', $4::jsonb)
		RETURNING id`,
		userID, amount, actionType, string(meta),
	).Scan(&requestID)
	return requestID, false, err
}

// parseInstruction splits "DEPOSIT 5000" / "WITHDRAW 10000".
func parseInstruction(msg string) (string, float64, error) {
	parts := strings.Fields(strings.TrimSpace(msg))
	if len(parts) < 2 {
		return "", 0, errors.New("not enough tokens")
	}
	action := strings.ToUpper(parts[0])
	if action != "DEPOSIT" && action != "WITHDRAW" {
		return "", 0, errors.New("unsupported action")
	}
	amount, err := strconv.ParseFloat(strings.ReplaceAll(parts[1], ",", ""), 64)
	if err != nil || amount <= 0 {
		return "", 0, errors.New("invalid amount")
	}
	return action, amount, nil
}

// secureEquals is constant-time string comparison for secrets.
func secureEquals(a, b string) bool {
	return len(a) == len(b) && hmac.Equal([]byte(a), []byte(b))
}

// ---------------------------------------------------------------------------

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	srv, err := newServer()
	if err != nil {
		logger.Error("bot webhook worker failed to start", "error", err)
		os.Exit(1)
	}

	httpAddr := getenv("HTTP_ADDR", ":8090")
	httpServer := &http.Server{
		Addr:              httpAddr,
		Handler:           http.HandlerFunc(srv.HandleBotRequest),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		logger.Info("bot webhook worker listening", "addr", httpAddr)
		errCh <- httpServer.ListenAndServe()
	}()
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	select {
	case <-ctx.Done():
		logger.Info("bot webhook worker stopped cleanly")
	case err := <-errCh:
		logger.Error("bot webhook worker exited", "error", err)
		os.Exit(1)
	}
}

func newServer() (*BotWebhookServer, error) {
	db, err := database.Connect(database.DefaultConfig())
	if err != nil {
		return nil, err
	}

	// RabbitMQ is REQUIRED in production — never fall back to guest defaults.
	// go-live.sh auto-generates RABBITMQ_USER/RABBITMQ_PASS into .env.production;
	// amqpcfg percent-encodes them via net/url.UserPassword so base64 passwords
	// with '+', '/', '=' never corrupt the DSN.
	amqpURL := amqpcfg.DSN()
	if amqpURL == "" {
		return nil, errors.New("RabbitMQ is not configured — set RABBITMQ_USER and RABBITMQ_PASS in .env.production")
	}
	queue := getenv("AGENT_UNIT_REQUEST_QUEUE", "agent_unit_request_queue")

	return &BotWebhookServer{
		db:             db,
		publisher:      worker.NewPublisher(amqpURL, queue),
		telegramSecret: getenv("TELEGRAM_WEBHOOK_SECRET", ""),
		viberToken:     getenv("VIBER_AUTH_TOKEN", ""),
	}, nil
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
