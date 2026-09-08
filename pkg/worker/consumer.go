package worker

import (
	"context"
	"errors"
	"log/slog"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

// MessageHandler processes a single delivery. A returned error triggers a
// negative acknowledgement with requeue (transient failure); nil acks the
// message. Parse/dropped messages should be acked inside the handler.
type MessageHandler func(ctx context.Context, delivery amqp.Delivery) error

// Consumer is a durable RabbitMQ consumer with prefetch batching, automatic
// reconnect and manual per-message acks.
type Consumer struct {
	url      string
	queue    string
	prefetch int
	handler  MessageHandler
	logger   *slog.Logger
}

// NewConsumer builds a Consumer for the given URL and queue.
func NewConsumer(url, queue string, prefetch int, handler MessageHandler, logger *slog.Logger) *Consumer {
	return &Consumer{
		url:      url,
		queue:    queue,
		prefetch: prefetch,
		handler:  handler,
		logger:   logger,
	}
}

// Run blocks and consumes until ctx is cancelled, reconnecting on failures.
func (c *Consumer) Run(ctx context.Context) error {
	if c.prefetch <= 0 {
		c.prefetch = 1
	}

	for {
		err := c.runOnce(ctx)
		if err == nil {
			return nil // graceful shutdown
		}
		select {
		case <-ctx.Done():
			c.logger.Info("consumer shutting down")
			return nil
		default:
			c.logger.Warn("consumer loop error, reconnecting in 1s", "error", err)
			select {
			case <-ctx.Done():
				return nil
			case <-time.After(time.Second):
			}
		}
	}
}

func (c *Consumer) runOnce(ctx context.Context) error {
	conn, err := amqp.Dial(c.url)
	if err != nil {
		return err
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		return err
	}
	defer ch.Close()

	if err := ch.Qos(c.prefetch, 0, false); err != nil {
		return err
	}

	if _, err := ch.QueueDeclare(c.queue, true, false, false, false, nil); err != nil {
		return err
	}

	deliveries, err := ch.Consume(c.queue, "", false, false, false, false, nil)
	if err != nil {
		return err
	}

	// Fail fast if the channel dies so we can re-dial.
	closeCh := make(chan *amqp.Error, 1)
	ch.NotifyClose(closeCh)

	c.logger.Info("consumer connected", "queue", c.queue, "prefetch", c.prefetch)

	for {
		select {
		case <-ctx.Done():
			_ = ch.Cancel("", false)
			return nil
		case amqpErr := <-closeCh:
			if amqpErr == nil {
				return errors.New("amqp channel closed")
			}
			return amqpErr
		case d, ok := <-deliveries:
			if !ok {
				return errors.New("delivery channel closed")
			}
			c.process(ctx, d)
		}
	}
}

func (c *Consumer) process(ctx context.Context, d amqp.Delivery) {
	// Acknowledge as quickly as possible; each delivery runs through the
	// handler with its own timeout so a stuck settlement never blocks the
	// prefetch window indefinitely.
	hctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	if err := c.handler(hctx, d); err != nil {
		c.logger.Error("message processing failed",
			"delivery_tag", d.DeliveryTag,
			"error", err,
			"redelivered", d.Redelivered,
		)
		// First failure requeues (transient AMQP hiccup / worker restart race).
		// A redelivered message that STILL fails is a poison pill (data
		// integrity issue) — rejecting it forever would hot-loop the queue.
		if !d.Redelivered {
			_ = d.Nack(false, true)
			return
		}
		c.logger.Error("dropping poison-pill settlement message",
			"delivery_tag", d.DeliveryTag,
			"error", err,
		)
		_ = d.Nack(false, false)
		return
	}
	_ = d.Ack(false)
}
