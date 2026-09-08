package worker

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

// Publisher enqueues finished-match results for the settlement worker.
// It is a stateless per-call AMQP client: the admin API holds no permanent
// broker connection, and a transient broker outage must never block the
// result endpoint indefinitely (the ACID commit of the result already
// happened before we publish; the worker replays from match_results if a
// message is lost).
type Publisher struct {
	url   string
	queue string
}

// NewPublisher builds a Publisher for the settlement queue.
// Default queue name matches cmd/worker/main.go (match_settlement_queue).
func NewPublisher(url, queue string) *Publisher {
	if queue == "" {
		queue = "match_settlement_queue"
	}
	return &Publisher{url: url, queue: queue}
}

// PublishMatchResult marshals a SettlementEvent and publishes it durably to
// the queue. Retries with short backoff (~3s total); the caller decides what
// to do on the final failure (log + rely on manual re-dispatch).
func (p *Publisher) PublishMatchResult(ctx context.Context, ev SettlementEvent) error {
	payload, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("encode settlement event: %w", err)
	}
	return p.publishEncoded(ctx, ev.MatchID, "settlement event", payload)
}

// Publish enqueues an arbitrary JSON event with the same durable/retry
// guarantees. Used by auxiliary senders (e.g. the bot webhook worker) that
// must surface a unit request to the agent dashboard in real time.
func (p *Publisher) Publish(ctx context.Context, eventID int64, label string, v any) error {
	payload, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("encode %s: %w", label, err)
	}
	return p.publishEncoded(ctx, eventID, label, payload)
}

// publishEncoded publishes a pre-marshalled payload durably to the queue with
// short retry backoff (~3s total).
func (p *Publisher) publishEncoded(ctx context.Context, eventID int64, label string, payload []byte) error {
	if p == nil {
		return fmt.Errorf("%s publisher not configured", label)
	}

	const attempts = 5
	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		lastErr = p.publishOnce(ctx, payload)
		if lastErr == nil {
			return nil
		}
		slog.Warn("publish event failed",
			"label", label, "attempt", attempt, "id", eventID, "error", lastErr)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(attempt) * 100 * time.Millisecond):
		}
	}
	return fmt.Errorf("publish %s (id %d) after %d attempts: %w",
		label, eventID, attempts, lastErr)
}

// publishOnce opens a connection, declares the durable queue (mirroring the
// consumer's QueueDeclare so results buffer even before the worker starts)
// and publishes the payload on the default exchange keyed by queue name.
func (p *Publisher) publishOnce(ctx context.Context, payload []byte) error {
	conn, err := amqp.Dial(p.url)
	if err != nil {
		return err
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		return err
	}
	defer ch.Close()

	if _, err := ch.QueueDeclare(p.queue, true, false, false, false, nil); err != nil {
		return err
	}

	return ch.PublishWithContext(ctx, "", p.queue, false, false,
		amqp.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp.Persistent,
			Timestamp:    time.Now().UTC(),
			Body:         payload,
		})
}
