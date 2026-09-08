package websocket

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"
)

// LiveOddsSnapshot is the full odds row for one live match. Its JSON keys are
// the exact wire contract consumed by the Flutter LiveOddsSnapshot.fromJson
// (mobile/lib/features/live_match/domain/live_odds_models.dart).
type LiveOddsSnapshot struct {
	MatchID             int64     `json:"match_id"`
	LeagueName          string    `json:"league_name,omitempty"`
	HomeTeam            string    `json:"home_team"`
	AwayTeam            string    `json:"away_team"`
	HomeScore           int       `json:"home_score,omitempty"`
	AwayScore           int       `json:"away_score,omitempty"`
	Status              string    `json:"status"` // OPEN / SUSPENDED / CLOSED / FINISHED
	BodyOddsType        string    `json:"body_odds_type,omitempty"`
	Handicap            string    `json:"handicap,omitempty"`         // e.g. "1+25"
	HandicapTeam        string    `json:"handicap_team,omitempty"`    // HOME / AWAY
	HomeBodyPayout      float64   `json:"home_body_payout,omitempty"` // mapped to Dart home_odds fallback
	AwayBodyPayout      float64   `json:"away_body_payout,omitempty"`
	MaungHomeMultiplier float64   `json:"maung_home_multiplier,omitempty"`
	MaungAwayMultiplier float64   `json:"maung_away_multiplier,omitempty"`
	MaungDrawMultiplier float64   `json:"maung_draw_multiplier,omitempty"`
	StreamURL           string    `json:"stream_url,omitempty"` // future; no column yet
	UpdatedAt           time.Time `json:"updated_at"`
}

// oddsFrame is the envelope shape the gateway sends: the Flutter client checks
// decoded['type'] == "odds_update" and unwraps decoded['data'].
type oddsFrame struct {
	Type string           `json:"type"`
	Data LiveOddsSnapshot `json:"data"`
}

// MarshalOddsFrame wraps a snapshot in the wire envelope (exported so the
// admin API's onOddsChange hook in cmd/api can push frames through Redis).
func MarshalOddsFrame(s LiveOddsSnapshot) ([]byte, error) {
	return json.Marshal(oddsFrame{Type: "odds_update", Data: s})
}

const snapshotSelect = `
	SELECT id, league_name, home_team, away_team,
	       0, 0,
	       status, body_odds_type, handicap_team,
	       COALESCE(NULLIF(handicap, ''), body_odds_type),
	       COALESCE(home_body_payout, 0), COALESCE(away_body_payout, 0),
	       COALESCE(maung_home_multiplier, 0), COALESCE(maung_away_multiplier, 0),
	       COALESCE(maung_draw_multiplier, 0), updated_at
	  FROM matches `

// scanSnapshot decodes one row produced by snapshotSelect.
func scanSnapshot(row interface{ Scan(...any) error }) (LiveOddsSnapshot, error) {
	var s LiveOddsSnapshot
	err := row.Scan(&s.MatchID, &s.LeagueName, &s.HomeTeam, &s.AwayTeam,
		&s.HomeScore, &s.AwayScore,
		&s.Status, &s.BodyOddsType, &s.HandicapTeam, &s.Handicap,
		&s.HomeBodyPayout, &s.AwayBodyPayout,
		&s.MaungHomeMultiplier, &s.MaungAwayMultiplier, &s.MaungDrawMultiplier,
		&s.UpdatedAt)
	return s, err
}

// BuildSnapshot loads the live-odds snapshot for one match (used by the admin
// onOddsChange hook after any status/odds commit).
func BuildSnapshot(ctx context.Context, db *sql.DB, matchID int64) (LiveOddsSnapshot, error) {
	return scanSnapshot(db.QueryRowContext(ctx, snapshotSelect+` WHERE id = $1`, matchID))
}

// BuildAllLiveSnapshots loads every currently wagering match (OPEN /
// SUSPENDED) — the payload streamed to a freshly connected /ws/live-odds
// client so it can render odds without a separate REST poll.
func BuildAllLiveSnapshots(ctx context.Context, db *sql.DB) ([]LiveOddsSnapshot, error) {
	rows, err := db.QueryContext(ctx,
		snapshotSelect+` WHERE status IN ('OPEN', 'SUSPENDED') ORDER BY match_time ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	snaps := make([]LiveOddsSnapshot, 0, 16)
	for rows.Next() {
		s, err := scanSnapshot(rows)
		if err != nil {
			return nil, err
		}
		snaps = append(snaps, s)
	}
	return snaps, rows.Err()
}
