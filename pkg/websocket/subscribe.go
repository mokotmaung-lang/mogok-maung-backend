package websocket

import (
	"context"
	"time"
)

// SubscribeLoop fans live_odds_channel frames into the Hub's live broadcast.
// It runs forever (until ctx is cancelled), re-subscribing with exponential
// backoff so a transient Redis outage never strands the gateway — clients
// keep their sockets open and resume mid-stream once Redis is back.
func (h *Hub) SubscribeLoop(ctx context.Context) {
	backoff := time.Second
	const maxBackoff = 30 * time.Second

	for {
		err := h.runSubscription(ctx)
		if ctx.Err() != nil {
			return
		}
		h.logger.Warn("ws: live-odds subscription dropped, reconnecting",
			"backoff", backoff.String(), "error", err)

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

// runSubscription subscribes once and relays payloads until the subscription
// fails or ctx is cancelled.
func (h *Hub) runSubscription(ctx context.Context) error {
	sub := h.rdb.Subscribe(ctx, LiveOddsChannel)
	defer sub.Close()

	// sub.Receive() blocks on the sync API and returns (or errors) on
	// disconnect, which lets SubscribeLoop drive the reconnect/backoff.
	_, err := sub.Receive(ctx)
	if err != nil {
		return err
	}

	ch := sub.Channel()
	for {
		select {
		case msg := <-ch:
			if msg == nil {
				return errNilMessage
			}
			h.BroadcastLive([]byte(msg.Payload))
		case <-ctx.Done():
			return nil
		}
	}
}

var errNilMessage = &subscribeClosedError{}

type subscribeClosedError struct{}

func (*subscribeClosedError) Error() string {
	return "live-odds channel closed"
}
