// Package feed implements the real-time fixture sync pipeline that backs
// POST /api/v1/admin/fixtures/sync. It decouples the sports-data provider
// (API-Football in production, a deterministic mock for offline staging) from
// the atomic matches-table merge, and exposes the set of changed match ids so
// the API layer can fan fresh live-odds snapshots out through Redis/WS and
// invalidate the active-fixtures cache.
package feed

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// FeedStatus classifies a provider match lifecycle into the coarse buckets the
// betting control plane needs. Provider-specific code strings (API-Football
// shorts, Sportradar codes, ...) are normalised to these by the provider.
type FeedStatus string

const (
	// StatusScheduled means the event has not kicked off yet.
	StatusScheduled FeedStatus = "SCHEDULED"
	// StatusLive means the event is underway (live betting may still apply).
	StatusLive FeedStatus = "LIVE"
	// StatusFinished means the event reached a definitive end state.
	StatusFinished FeedStatus = "FINISHED"
	// StatusCanceled means the event was cancelled/postponed/suspended.
	StatusCanceled FeedStatus = "CANCELED"
)

// ErrProviderNotConfigured is returned when the sync layer has no usable
// provider (no mock flag and no API credentials). Handlers surface it as 503.
var ErrProviderNotConfigured = errors.New("fixture provider not configured")

// FeedMatch is a provider-normalised fixture row.
type FeedMatch struct {
	ExternalID string
	League     string
	HomeTeam   string
	AwayTeam   string
	Kickoff    time.Time
	Status     FeedStatus
}

// match is the parameter bundle handed to the upsert statement.
type match struct {
	externalID     string
	league         string
	homeTeam       string
	awayTeam       string
	kickoff        time.Time
	handicapTeam   string
	bodyOddsType   string
	handicap       string
	homeBodyPayout float64
	awayBodyPayout float64
	maungHome      float64
	maungAway      float64
	maungDraw      float64
	status         string // OPEN when upcoming, CLOSED when over/canceled
}

// Myanmar odds defaults applied to freshly inserted matches. The provider feed
// carries no Myanmar odds pixels, so a new row starts from the neutral parity
// line and the Super Admin refines it — updates to existing rows never touch
// the odds profile.
const (
	defaultHandicapTeam = "HOME"
	defaultBodyOddsType = "0+00"
	defaultBodyPayout   = 0.90
	defaultMaungHome    = 1.80
	defaultMaungAway    = 1.80
	defaultMaungDraw    = 2.00
)

// ToMatch hydrates the upsert bundle, or reports unmergeable rows (empty team
// names, missing external id) so the driver can count them as skipped. Rows
// whose feed status is finished/canceled are inserted CLOSED when brand-new
// (never bettable until a Super Admin opens them); the conflict branch never
// overwrites an existing row's status, so admin status control is preserved.
func (f FeedMatch) ToMatch(now time.Time) (match, bool) {
	home := strings.TrimSpace(f.HomeTeam)
	away := strings.TrimSpace(f.AwayTeam)
	league := strings.TrimSpace(f.League)
	if home == "" || away == "" || strings.EqualFold(home, away) {
		return match{}, false
	}
	if strings.TrimSpace(f.ExternalID) == "" || f.Kickoff.IsZero() {
		return match{}, false
	}
	status := "OPEN"
	if f.Status == StatusFinished || f.Status == StatusCanceled {
		status = "CLOSED"
	}
	return match{
		externalID:     f.ExternalID,
		league:         league,
		homeTeam:       home,
		awayTeam:       away,
		kickoff:        f.Kickoff,
		handicapTeam:   defaultHandicapTeam,
		bodyOddsType:   defaultBodyOddsType,
		handicap:       defaultBodyOddsType,
		homeBodyPayout: defaultBodyPayout,
		awayBodyPayout: defaultBodyPayout,
		maungHome:      defaultMaungHome,
		maungAway:      defaultMaungAway,
		maungDraw:      defaultMaungDraw,
		status:         status,
	}, true
}

// Report summarises one sync run for the control-plane dashboard.
type Report struct {
	Pulled          int     `json:"pulled"`
	Inserted        int     `json:"inserted"`
	Updated         int     `json:"updated"`
	Skipped         int     `json:"skipped"`
	ChangedMatchIDs []int64 `json:"changed_matches"`
}

// Provider fetches provider-normalised fixtures.
type Provider interface {
	Fetch(ctx context.Context) ([]FeedMatch, error)
}

// Driver merges provider fixtures into the matches table in one ACID
// transaction. New provider matches are inserted; existing ones are updated in
// place (same local id, preserving bet/settlement references) via ON CONFLICT.
type Driver struct {
	db       *sql.DB
	provider Provider
	now      func() time.Time
}

// NewDriver builds a Driver. now is optional and may be nil (defaults to
// time.Now) — it exists only to make kickoff-edge logic deterministic in tests.
func NewDriver(db *sql.DB, provider Provider, clock func() time.Time) *Driver {
	if clock == nil {
		clock = time.Now
	}
	return &Driver{db: db, provider: provider, now: clock}
}

const upsertSQL = `
	INSERT INTO matches
	    (external_match_id, league_name, home_team, away_team, match_time,
	     handicap_team, body_odds_type, handicap,
	     home_body_payout, away_body_payout,
	     maung_home_multiplier, maung_away_multiplier, maung_draw_multiplier,
	     status)
	VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
	ON CONFLICT (external_match_id) DO UPDATE SET
	    league_name       = EXCLUDED.league_name,
	    home_team         = EXCLUDED.home_team,
	    away_team         = EXCLUDED.away_team,
	    match_time        = EXCLUDED.match_time,
	    updated_at        = CURRENT_TIMESTAMP
	RETURNING id, (xmax = 0) AS inserted`

// Sync pulls the provider feed and merges every mergeable row. It returns the
// changed local match ids so callers can fan live-odds frames and invalidate
// caches; ErrProviderNotConfigured is returned when no provider is configured.
func (d *Driver) Sync(ctx context.Context) (Report, error) {
	if d.provider == nil {
		return Report{}, ErrProviderNotConfigured
	}

	fixtures, err := d.provider.Fetch(ctx)
	if err != nil {
		return Report{}, fmt.Errorf("fetch fixtures: %w", err)
	}

	rpt := Report{Pulled: len(fixtures)}
	now := d.now()

	tx, err := d.db.BeginTx(ctx, nil)
	if err != nil {
		return Report{}, fmt.Errorf("begin sync tx: %w", err)
	}
	defer tx.Rollback() // no-op after Commit.

	for _, f := range fixtures {
		m, ok := f.ToMatch(now)
		if !ok {
			rpt.Skipped++
			continue
		}
		var (
			matchID  int64
			inserted bool
		)
		err := tx.QueryRowContext(ctx, upsertSQL,
			m.externalID, m.league, m.homeTeam, m.awayTeam, m.kickoff,
			m.handicapTeam, m.bodyOddsType, m.handicap,
			m.homeBodyPayout, m.awayBodyPayout,
			m.maungHome, m.maungAway, m.maungDraw,
			m.status,
		).Scan(&matchID, &inserted)
		if err != nil {
			return Report{}, fmt.Errorf("upsert fixture %q: %w", m.externalID, err)
		}
		if inserted {
			rpt.Inserted++
		} else {
			rpt.Updated++
		}
		rpt.ChangedMatchIDs = append(rpt.ChangedMatchIDs, matchID)
	}

	if err := tx.Commit(); err != nil {
		return Report{}, fmt.Errorf("commit sync tx: %w", err)
	}
	return rpt, nil
}
