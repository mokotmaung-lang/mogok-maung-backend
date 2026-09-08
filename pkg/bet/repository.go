package bet

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math"
	"strings"
)

// Repository encapsulates the data-access logic for bet placement.
// All writes run inside a single strict transaction guarded by a
// pessimistic lock (SELECT ... FOR UPDATE) on the user's wallet row.
type Repository struct {
	db *sql.DB
}

// NewRepository builds a Repository backed by the given *sql.DB.
func NewRepository(db *sql.DB) *Repository {
	return &Repository{db: db}
}

// sentinel errors surfaced to the handler for HTTP mapping.
var (
	ErrInsufficientBalance = errors.New("insufficient balance to place bet")
	ErrClosedMatch         = errors.New("one or more matches are not open")
	ErrInvalidRequest      = errors.New("invalid bet request")
)

// PlaceBet atomically validates, holds funds and records a bet.
// It is safe to call concurrently: the wallet row lock serialises writers.
func (r *Repository) PlaceBet(ctx context.Context, userID int64, req PlaceBetRequest) (PlaceBetResponse, error) {
	if err := req.Validate(); err != nil {
		return PlaceBetResponse{}, fmt.Errorf("%w: %v", ErrInvalidRequest, err)
	}

	// Open a strict serialisable-ish transaction.
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return PlaceBetResponse{}, fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback() // no-op after a successful Commit.

	// 1) Verify all matches are OPEN, capturing each odds type for risk.
	//    Row-level lock on matches is not strictly required since their
	//    status is set by an admin-side writer, but we read within the
	//    same transaction to get a consistent snapshot.
	oddsTypes := make([]string, 0, len(req.Selections))
	winLegs := make([]PotentialWinLeg, 0, len(req.Selections))
	for _, sel := range req.Selections {
		var (
			status                 string
			homeBody, awayBody     sql.NullFloat64
			maungH, maungA, maungD sql.NullFloat64
		)
		err := tx.QueryRowContext(ctx,
			`SELECT status,
			        home_body_payout, away_body_payout,
			        maung_home_multiplier, maung_away_multiplier, maung_draw_multiplier
			   FROM matches WHERE id = $1 FOR SHARE`,
			sel.MatchID,
		).Scan(&status, &homeBody, &awayBody, &maungH, &maungA, &maungD)
		if errors.Is(err, sql.ErrNoRows) {
			return PlaceBetResponse{}, fmt.Errorf("%w: match %d not found", ErrClosedMatch, sel.MatchID)
		}
		if err != nil {
			return PlaceBetResponse{}, fmt.Errorf("query match %d: %w", sel.MatchID, err)
		}
		if !strings.EqualFold(status, "OPEN") {
			return PlaceBetResponse{}, fmt.Errorf("%w: match %d is %s", ErrClosedMatch, sel.MatchID, status)
		}
		oddsTypes = append(oddsTypes, sel.BodyOddsType)
		winLegs = append(winLegs, PotentialWinLeg{
			Pick:                sel.Pick,
			BodyOddsType:        sel.BodyOddsType,
			HomeBodyPayout:      homeBody.Float64,
			AwayBodyPayout:      awayBody.Float64,
			MaungHomeMultiplier: maungH.Float64,
			MaungAwayMultiplier: maungA.Float64,
			MaungDrawMultiplier: maungD.Float64,
		})
	}

	// 2) Compute maximum potential loss for the whole bet.
	holdAmount, err := MaxPotentialLoss(string(req.BetType), req.TotalStake, oddsTypes)
	if err != nil {
		return PlaceBetResponse{}, fmt.Errorf("%w: %v", ErrInvalidRequest, err)
	}

	// 2b) Best-case payout snapshot (schema contract: always populated, never
	//     NULL, rounded to the column's NUMERIC(15,2)).
	potentialPayout, err := MaxPotentialWin(string(req.BetType), req.TotalStake, winLegs)
	if err != nil {
		return PlaceBetResponse{}, fmt.Errorf("%w: %v", ErrInvalidRequest, err)
	}
	potentialPayout = math.Round(potentialPayout*100) / 100

	// 3) Pessimistically lock the user's wallet row.
	var (
		currentBalance float64
		holdBalance    float64
	)
	err = tx.QueryRowContext(ctx,
		`SELECT current_balance, hold_balance FROM users WHERE id = $1 FOR UPDATE`,
		userID,
	).Scan(&currentBalance, &holdBalance)
	if errors.Is(err, sql.ErrNoRows) {
		return PlaceBetResponse{}, errors.New("user not found")
	}
	if err != nil {
		return PlaceBetResponse{}, fmt.Errorf("lock user %d: %w", userID, err)
	}

	// 4) Sufficiency check against maximum potential loss.
	if currentBalance < holdAmount {
		return PlaceBetResponse{}, ErrInsufficientBalance
	}

	// 5) Atomic wallet update: deduct max loss from current, hold it.
	newCurrent := currentBalance - holdAmount
	newHold := holdBalance + holdAmount
	res, err := tx.ExecContext(ctx,
		`UPDATE users
		   SET current_balance = $1, hold_balance = $2, updated_at = CURRENT_TIMESTAMP
		 WHERE id = $3`,
		newCurrent, newHold, userID,
	)
	if err != nil {
		return PlaceBetResponse{}, fmt.Errorf("update user wallet: %w", err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return PlaceBetResponse{}, errors.New("wallet update affected unexpected row count")
	}

	// 6) Insert the bet record (potential_payout = best-case payout).
	var betID int64
	err = tx.QueryRowContext(ctx,
		`INSERT INTO bets (user_id, bet_type, total_stake, hold_amount, potential_payout, status)
		 VALUES ($1, $2, $3, $4, $5, 'PENDING')
		 RETURNING id`,
		userID, string(req.BetType), req.TotalStake, holdAmount, potentialPayout,
	).Scan(&betID)
	if err != nil {
		return PlaceBetResponse{}, fmt.Errorf("insert bet: %w", err)
	}

	// 7) Insert the bet selections.
	for _, sel := range req.Selections {
		_, err = tx.ExecContext(ctx,
			`INSERT INTO bet_selections (bet_id, match_id, pick, body_odds_type)
			 VALUES ($1, $2, $3, $4)`,
			betID, sel.MatchID, string(sel.Pick), sel.BodyOddsType,
		)
		if err != nil {
			return PlaceBetResponse{}, fmt.Errorf("insert bet selection: %w", err)
		}
	}

	// 8) Append the immutable ledger entry for the hold.
	_, err = tx.ExecContext(ctx,
		`INSERT INTO unit_ledger
		    (user_id, request_id, bet_id, type, amount_change,
		     balance_before, balance_after, description)
		 VALUES ($1, NULL, $2, 'BET_HOLD', $3, $4, $5, $6)`,
		userID, betID, -holdAmount, currentBalance, newCurrent,
		fmt.Sprintf("Hold for bet %d (%s)", betID, req.BetType),
	)
	if err != nil {
		return PlaceBetResponse{}, fmt.Errorf("insert ledger: %w", err)
	}

	// 9) Commit the transaction.
	if err := tx.Commit(); err != nil {
		return PlaceBetResponse{}, fmt.Errorf("commit tx: %w", err)
	}

	return PlaceBetResponse{
		BetID:           betID,
		HoldAmount:      holdAmount,
		PotentialPayout: potentialPayout,
		CurrentBalance:  newCurrent,
	}, nil
}
