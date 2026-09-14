package worker

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/shopspring/decimal"

	"mogok-maung-backend/pkg/bet"
)

// Settler applies MatchFinished RabbitMQ events to pending bets, releasing
// hold balances and crediting winnings inside strict ACID transactions.
//
// Concurrency & isolation model:
//   - Equilibrium computed per bet, each bet settled in its OWN transaction, so
//     one failing bet never blocks the rest of the match's tickets.
//   - Selection rows are locked with SELECT ... FOR UPDATE (SKIP LOCKED) so
//     competing workers / redelivered messages cannot double-settle a ticket.
//   - The bet row is locked before wallet mutation and its status transition
//     PENDING -> APPROVED/REJECTED is guarded, making at-least-once delivery
//     idempotent.
type Settler struct {
	db *sql.DB
}

// NewSettler builds a Settler backed by the given pool.
func NewSettler(db *sql.DB) *Settler {
	return &Settler{db: db}
}

// pendingSelection is a selection row awaiting settlement for this event.
type pendingSelection struct {
	ID       int64
	BetID    int64
	MatchID  int64
	Pick     string
	BodyOdds string
}

// betRecord is a locked bet row being settled.
type betRecord struct {
	ID         int64
	UserID     int64
	Type       string
	TotalStake float64
	HoldAmount float64
	Status     string
}

// HandleSettlementEvent settles every pending bet that references the finished
// match. Every bet is settled inside its own isolated transaction; a failure in
// one ticket rolls back only that ticket and requeues the message without
// corrupting the others.
func (s *Settler) HandleSettlementEvent(ctx context.Context, ev SettlementEvent) error {
	// Snapshot the bet ids that currently carry a pending selection on this
	// match. Locks happen per-bet below; this read is only an enumeration.
	betIDs, err := s.pendingBetIDs(ctx, ev.MatchID)
	if err != nil {
		return err
	}

	for _, betID := range betIDs {
		if err := s.settleBet(ctx, ev, betID); err != nil {
			return fmt.Errorf("settle bet %d: %w", betID, err)
		}
	}
	return nil
}

func (s *Settler) pendingBetIDs(ctx context.Context, matchID int64) ([]int64, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT DISTINCT bs.bet_id
		  FROM bet_selections bs
		  JOIN bets b ON b.id = bs.bet_id
		 WHERE bs.match_id = $1
		   AND bs.status   = 'PENDING'
		   AND b.status    = 'PENDING'`,
		matchID,
	)
	if err != nil {
		return nil, fmt.Errorf("query pending bets for match %d: %w", matchID, err)
	}
	defer rows.Close()

	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scan pending bet id: %w", err)
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate pending bets: %w", err)
	}
	return ids, nil
}

// settleBet settles a single bet in a dedicated transaction.
func (s *Settler) settleBet(ctx context.Context, ev SettlementEvent, betID int64) error {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return fmt.Errorf("begin settlement tx: %w", err)
	}
	defer tx.Rollback() // no-op after a successful Commit.

	// Lock this bet's still-pending selections for the finished match.
	// SKIP LOCKED lets a competing worker that already owns these rows finish
	// the settlement; we then find nothing to do and commit an empty tx.
	rows, err := tx.QueryContext(ctx, `
		SELECT bs.id, bs.bet_id, bs.match_id, bs.pick, bs.body_odds_type
		  FROM bet_selections bs
		  JOIN bets b ON b.id = bs.bet_id
		 WHERE bs.bet_id  = $1
		   AND bs.match_id = $2
		   AND bs.status   = 'PENDING'
		   AND b.status    = 'PENDING'
		 FOR UPDATE OF bs SKIP LOCKED`,
		betID, ev.MatchID,
	)
	if err != nil {
		return fmt.Errorf("lock pending selections: %w", err)
	}
	defer rows.Close()

	var sels []pendingSelection
	for rows.Next() {
		var sel pendingSelection
		if err := rows.Scan(&sel.ID, &sel.BetID, &sel.MatchID, &sel.Pick, &sel.BodyOdds); err != nil {
			return fmt.Errorf("scan pending selection: %w", err)
		}
		sels = append(sels, sel)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate pending selections: %w", err)
	}
	rows.Close()

	if len(sels) == 0 {
		return tx.Commit() // already settled by a concurrent worker
	}

	var rec betRecord
	err = tx.QueryRowContext(ctx, `
		SELECT id, user_id, bet_type, total_stake, hold_amount, status
		  FROM bets
		 WHERE id = $1
		 FOR UPDATE`,
		betID,
	).Scan(&rec.ID, &rec.UserID, &rec.Type, &rec.TotalStake, &rec.HoldAmount, &rec.Status)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("bet %d not found", betID)
	}
	if err != nil {
		return fmt.Errorf("lock bet %d: %w", betID, err)
	}
	if rec.Status != "PENDING" {
		return tx.Commit() // idempotency guard: already settled
	}

	// Persist the outcome of every selection of this match touched by the event.
	for _, sel := range sels {
		outcome, err := resolveOutcome(ctx, tx, ev, sel)
		if err != nil {
			return err
		}
		res, err := tx.ExecContext(ctx,
			`UPDATE bet_selections SET status = $2 WHERE id = $1`,
			sel.ID, string(outcome),
		)
		if err != nil {
			return fmt.Errorf("update selection %d status: %w", sel.ID, err)
		}
		if n, _ := res.RowsAffected(); n != 1 {
			return fmt.Errorf("selection %d status update affected %d rows", sel.ID, n)
		}
	}

	// A Maung ticket is the product of every inner match. If any selection is
	// still pending, defer the wallet settlement until its match finishes.
	if strings.EqualFold(rec.Type, "MAUNG") {
		var pending int
		if err := tx.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM bet_selections WHERE bet_id = $1 AND status = 'PENDING'`,
			rec.ID,
		).Scan(&pending); err != nil {
			return fmt.Errorf("count pending maung selections: %w", err)
		}
		if pending > 0 {
			return tx.Commit() // ticket not complete yet
		}
	}

	combined, err := s.ticketMultiplier(ctx, tx, rec)
	if err != nil {
		return err
	}
	// Guardrail: ALL money math runs in fixed-point decimal — never raw float64
	// for currency/multiplier arithmetic (0.1+0.2 != 0.3 float bias). Float64
	// exists only at the DB scan/write boundary below.
	money := func(v float64) decimal.Decimal { return decimal.NewFromFloat(v) }
	payout := money(rec.TotalStake).Mul(money(combined)).Round(2).InexactFloat64()

	// Lock the user's wallet row to serialize against concurrent operations
	// (place-bet, withdraw, other settlements).
	var current, hold float64
	err = tx.QueryRowContext(ctx,
		`SELECT current_balance, hold_balance FROM users WHERE id = $1 FOR UPDATE`,
		rec.UserID,
	).Scan(&current, &hold)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("user %d not found", rec.UserID)
	}
	if err != nil {
		return fmt.Errorf("lock user %d: %w", rec.UserID, err)
	}

	// Wallet release: the original hold is cleared; wins are credited on top.
	// Computed in decimal (guardrail), converted to float64 only for the SQL write.
	newHold := money(hold).Sub(money(rec.HoldAmount))
	if newHold.LessThan(decimal.Zero) {
		newHold = decimal.Zero // guard against float drift / partial holds
	}
	newCurrent := money(current).Add(money(payout)).Round(2)

	res, err := tx.ExecContext(ctx,
		`UPDATE users
		    SET current_balance = $1, hold_balance = $2, updated_at = CURRENT_TIMESTAMP
		  WHERE id = $3`,
		newCurrent.InexactFloat64(), newHold.InexactFloat64(), rec.UserID,
	)
	if err != nil {
		return fmt.Errorf("update user %d wallet: %w", rec.UserID, err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return fmt.Errorf("wallet update for user %d affected %d rows", rec.UserID, n)
	}

	// Mark the bet settled. The status guard makes redelivery idempotent.
	betStatus := "REJECTED"
	ledgerType := "BET_LOSE"
	if payout > 0 {
		betStatus = "APPROVED"
		ledgerType = "BET_WIN"
	}
	res, err = tx.ExecContext(ctx,
		`UPDATE bets
		    SET status = $1, updated_at = CURRENT_TIMESTAMP, settled_at = CURRENT_TIMESTAMP
		  WHERE id = $2 AND status = 'PENDING'`,
		betStatus, rec.ID,
	)
	if err != nil {
		return fmt.Errorf("update bet %d status: %w", rec.ID, err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return fmt.Errorf("bet %d already settled by a concurrent worker", rec.ID)
	}

	// Append the immutable ledger entry; balance_before/after reflect the
	// current_balance delta produced by this settlement.
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO unit_ledger
		    (user_id, request_id, bet_id, type, amount_change,
		     balance_before, balance_after, description)
		 VALUES ($1, NULL, $2, $3, $4, $5, $6, $7)`,
		rec.UserID, rec.ID, ledgerType, payout, current, newCurrent,
		fmt.Sprintf("Settle bet %d (%s): %s, payout %v", rec.ID, rec.Type, betStatus, payout),
	); err != nil {
		return fmt.Errorf("insert settlement ledger: %w", err)
	}

	return tx.Commit()
}

// ticketMultiplier computes the parlay product of every selection's multiplier
// from its stored status and odds source (maung multipliers for MAUNG tickets,
// body odds profile for BODY tickets).
func (s *Settler) ticketMultiplier(ctx context.Context, tx *sql.Tx, rec betRecord) (float64, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT bs.pick, bs.status, bs.body_odds_type,
		       m.maung_home_multiplier, m.maung_away_multiplier, m.maung_draw_multiplier,
		       m.home_body_payout, m.away_body_payout
		  FROM bet_selections bs
		  JOIN matches m ON m.id = bs.match_id
		 WHERE bs.bet_id = $1
		 FOR SHARE`,
		rec.ID,
	)
	if err != nil {
		return 0, fmt.Errorf("load ticket selections: %w", err)
	}
	defer rows.Close()

	multipliers := make([]float64, 0, 8)
	for rows.Next() {
		var pick, status, bodyOdds string
		var homeMult, awayMult, drawMult, homeBody, awayBody float64
		if err := rows.Scan(&pick, &status, &bodyOdds, &homeMult, &awayMult, &drawMult, &homeBody, &awayBody); err != nil {
			return 0, fmt.Errorf("scan ticket selection: %w", err)
		}

		var raw float64
		if strings.EqualFold(rec.Type, "MAUNG") {
			switch strings.ToUpper(strings.TrimSpace(pick)) {
			case "HOME":
				raw = homeMult
			case "AWAY":
				raw = awayMult
			case "DRAW":
				raw = drawMult
			default:
				return 0, fmt.Errorf("unsupported maung pick %q", pick)
			}
		} else {
			profile, err := bet.BodyOddsProfile(bodyOdds)
			if err != nil {
				return 0, fmt.Errorf("bet %d selection odds: %w", rec.ID, err)
			}
			switch strings.ToUpper(strings.TrimSpace(pick)) {
			case "HOME":
				raw = homeBody
			case "AWAY":
				raw = awayBody
			default:
				// BODY legs that are not side-priced use the profile payout —
				// same fallback as bet.MaxPotentialWin so the payout never
				// diverges from the preview shown at placement.
				raw = profile.PayoutMultiplier
			}
			// A stored payout of 0 means the column was never provisioned;
			// fall back to the odds-profile payout. Mirror bet.MaxPotentialWin
			// exactly: payout never prices below the settled 1.0x minimum.
			if raw <= 0 {
				raw = profile.PayoutMultiplier
			}
			if raw < 1.0 {
				raw = 1.0
			}
		}

		outcome, err := ParseOutcome(status)
		if err != nil {
			return 0, err
		}
		m, err := SelectionMultiplier(outcome, raw)
		if err != nil {
			return 0, fmt.Errorf("bet %d selection %q: %w", rec.ID, pick, err)
		}
		multipliers = append(multipliers, m)
	}
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("iterate ticket selections: %w", err)
	}

	return TicketMultiplier(multipliers), nil
}

// resolveOutcome maps a selection pick to its traditional Myanmar outcome
// using the finished match event's per-team statuses.
func resolveOutcome(ctx context.Context, tx *sql.Tx, ev SettlementEvent, sel pendingSelection) (Outcome, error) {
	pick := strings.ToUpper(strings.TrimSpace(sel.Pick))
	var teamStatus map[string]string
	switch pick {
	case "HOME", "AWAY", "DRAW":
	default:
		return "", fmt.Errorf("unsupported pick %q for settlement", sel.Pick)
	}

	// TeamResults uses the HOME/AWAY role keys (same convention as the
	// match_results table). Map by role, NOT by team name — team names are not
	// part of the settlement contract.
	teamStatus = make(map[string]string, len(ev.TeamResults))
	for _, tr := range ev.TeamResults {
		team := strings.ToLower(strings.TrimSpace(tr.Team))
		switch team {
		case "home", "away", "draw":
		default:
			return "", fmt.Errorf("unsupported team %q in settlement event", tr.Team)
		}
		teamStatus[team] = strings.ToUpper(strings.TrimSpace(tr.Status))
	}

	switch pick {
	case "HOME":
		return parseTeamOutcome(teamStatus["home"])
	case "AWAY":
		return parseTeamOutcome(teamStatus["away"])
	case "DRAW":
		if s, ok := teamStatus["draw"]; ok {
			return parseTeamOutcome(s)
		}
		if teamStatus["home"] == "DRAW" {
			return OutcomeWin, nil
		}
		return OutcomeLose, nil
	default:
		return "", fmt.Errorf("unsupported pick %q", pick)
	}
}

func parseTeamOutcome(raw string) (Outcome, error) {
	o, err := ParseOutcome(raw)
	if err != nil {
		return "", fmt.Errorf("team outcome: %w", err)
	}
	return o, nil
}
