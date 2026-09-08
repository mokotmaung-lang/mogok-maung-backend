package worker

import (
	"encoding/json"
	"fmt"
)

// TeamResult describes the traditional Myanmar outcome of a single team
// after a match has finished.
type TeamResult struct {
	Team   string `json:"team"`
	Status string `json:"status"`
}

// SettlementEvent is the RabbitMQ payload published when a match finishes.
// Statuses are one of: WIN, LOSE, DRAW, HALF_WIN, HALF_LOSE.
type SettlementEvent struct {
	MatchID     int64        `json:"match_id"`
	HomeScore   int          `json:"home_score"`
	AwayScore   int          `json:"away_score"`
	TeamResults []TeamResult `json:"team_results"`
}

// ParseSettlementEvent decodes a raw AMQP payload into a SettlementEvent and
// performs shape validation. Malformed payloads must be routed to the dead-letter
// path (acked) so they cannot poison the queue.
func ParseSettlementEvent(payload []byte) (SettlementEvent, error) {
	var ev SettlementEvent
	if err := json.Unmarshal(payload, &ev); err != nil {
		return ev, fmt.Errorf("decode settlement event: %w", err)
	}
	if ev.MatchID <= 0 {
		return ev, fmt.Errorf("settlement event missing match_id")
	}
	if len(ev.TeamResults) == 0 {
		return ev, fmt.Errorf("settlement event missing team_results")
	}
	return ev, nil
}
