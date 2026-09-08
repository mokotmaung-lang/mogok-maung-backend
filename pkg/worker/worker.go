package worker

import (
	"context"
	"database/sql"
	"log/slog"

	amqp "github.com/rabbitmq/amqp091-go"
)

// Worker is the background settlement processor: it bridges the RabbitMQ
// consumer with the ACID settlement engine.
type Worker struct {
	consumer *Consumer
}

// NewWorker wires a Settler behind a Consumer for the given queue.
func NewWorker(db *sql.DB, amqpURL, queue string, prefetch int, logger *slog.Logger) *Worker {
	settler := NewSettler(db)

	handler := func(ctx context.Context, d amqp.Delivery) error {
		ev, err := ParseSettlementEvent(d.Body)
		if err != nil {
			// Malformed payload: ack so it cannot poison the queue.
			logger.Warn("dropping malformed settlement event",
				"delivery_tag", d.DeliveryTag, "error", err)
			return nil
		}

		if err := settler.HandleSettlementEvent(ctx, ev); err != nil {
			logger.Error("match settlement failed",
				"match_id", ev.MatchID, "error", err)
			return err // requeue
		}

		logger.Info("match settled",
			"match_id", ev.MatchID,
			"home_score", ev.HomeScore,
			"away_score", ev.AwayScore,
		)
		return nil
	}

	return &Worker{
		consumer: NewConsumer(amqpURL, queue, prefetch, handler, logger),
	}
}

// Run blocks until ctx is cancelled or an unrecoverable error occurs.
func (w *Worker) Run(ctx context.Context) error {
	slog.Info("match settlement worker started")
	return w.consumer.Run(ctx)
}
