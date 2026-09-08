package websocket

import (
	"context"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

// AgentConsumerLoop drains the `agent_unit_request_queue` and pushes each
// unitRequestEvent frame to every connected AGENT/SUPER_ADMIN dashboard client
// (the Hub filters them in its Run loop).
//
// The webhook worker publishes these events durably (Publisher.Publish) and
// the PENDING row already lives in unit_requests, so this consumer is strictly
// an accelerator — a failure here only delays a push, never loses a request.
//
// It reconnects with exponential backoff so a broker restart self-heals.
func (h *Hub) AgentConsumerLoop(ctx context.Context, amqpURL, queue string) {
	backoff := time.Second
	const maxBackoff = 30 * time.Second

	for {
		err := h.agentConsumeOnce(ctx, amqpURL, queue)
		if ctx.Err() != nil {
			return
		}
		h.logger.Warn("ws: agent request consumer dropped, reconnecting",
			"queue", queue, "backoff", backoff.String(), "error", err)

		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff < maxBackoff {
			backoff *= 2
		}
	}
}

// agentConsumeOnce runs one AMQP consumption session: declare the durable
// queue (mirrors the webhook Publisher so messages buffer before we start),
// then Ack each delivery after fan-out.
func (h *Hub) agentConsumeOnce(ctx context.Context, amqpURL, queue string) error {
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		return err
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		return err
	}
	defer ch.Close()

	if _, err := ch.QueueDeclare(queue, true, false, false, false, nil); err != nil {
		return err
	}
	if err := ch.Qos(10, 0, false); err != nil {
		return err
	}

	deliveries, err := ch.Consume(queue, "agent-dashboard-pusher", false, false, false, false, nil)
	if err != nil {
		return err
	}

	for {
		select {
		case msg, ok := <-deliveries:
			if !ok {
				return errConsumerClosed
			}
			// Re-publish exactly what the webhook sent (frame type
			// "unit_request_created" + payload fields) to the dashboard.
			h.BroadcastAgent(msg.Body)
			_ = msg.Ack(false) // fan-out is fire-and-forget; the row is durable
		case <-ctx.Done():
			return nil
		}
	}
}

var errConsumerClosed = &consumerClosedError{}

type consumerClosedError struct{}

func (*consumerClosedError) Error() string {
	return "agent request consumer channel closed"
}
