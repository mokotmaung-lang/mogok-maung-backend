package wallet

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/shopspring/decimal"
)

// Engine provides atomic wallet operations with pessimistic row-level locking
// and a mandatory double-entry audit ledger (unit_ledger append-only).
//
// Spec reference: Atomic Wallet Engine — Anti-Race Condition.
//
// Every mutation follows the pattern:
//   1. BeginTx (Repeatable Read)
//   2. SELECT ... FOR UPDATE on every affected row
//   3. Sufficiency / hierarchy checks
//   4. UPDATE balances
//   5. INSERT ledger rows (double-entry: every credit has a corresponding debit)
//   6. Commit

type Engine struct {
	DB *sql.DB
}

// Direction indicates which way units move between an agent and one of its
// downline users.
type Direction string

const (
	// DirectionDeposit moves units from the agent's balance to the user's
	// balance (agent -> user). Agent ledger leg is WITHDRAW, user leg DEPOSIT.
	DirectionDeposit Direction = "DEPOSIT"

	// DirectionWithdraw moves units from the user's balance back to the
	// agent's balance (user -> agent). User ledger leg is WITHDRAW, agent leg
	// DEPOSIT.
	DirectionWithdraw Direction = "WITHDRAW"
)

// TransferRequest describes an agent⇄downline units movement.
type TransferRequest struct {
	AgentID     int64
	UserID      int64
	Amount      float64
	Direction   Direction
	Description string // optional human-readable context
}

// TransferResult reports the post-transfer balances so the HTTP layer can
// echo the updated figures without a second read.
type TransferResult struct {
	AgentBalance float64
	UserBalance  float64
}

// TransferError is the domain error surfaced to the HTTP handler.
type TransferError struct {
	Reason string
}

// Sentinel errors distinguish wallet failures at the HTTP mapping layer.
var (
	ErrInsufficientBalance = TransferError{Reason: "insufficient balance for transfer"}
	ErrHierarchyViolation  = TransferError{Reason: "user does not belong to agent"}
	ErrInvalidAmount       = TransferError{Reason: "amount must be greater than zero"}
	ErrInvalidDirection    = TransferError{Reason: "direction must be DEPOSIT or WITHDRAW"}
)

func (e TransferError) Error() string { return e.Reason }

// TransferUnits moves [Request.Amount] between an Agent's current_balance and
// one of its downline User's current_balance, atomically. Both ledger rows
// (a debit on one side and an equal credit on the other) are written inside
// the same ACID transaction under pessimistic FOR UPDATE row locks. This is
// safe to call concurrently.
//
// DEADLOCK GUARDRAIL: both affected rows are locked in ascending user_id
// order. Every multi-user wallet operation must acquire locks in the same
// canonical order; any other ordering lets two concurrent transfers on the
// same agent/user pair lock in opposite sequence and deadlock under load.
func (w *Engine) TransferUnits(ctx context.Context, req TransferRequest) (*TransferResult, error) {
	if req.Amount <= 0 {
		return nil, ErrInvalidAmount
	}
	if req.Direction != DirectionDeposit && req.Direction != DirectionWithdraw {
		return nil, ErrInvalidDirection
	}

	tx, err := w.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead})
	if err != nil {
		return nil, fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback()

	// 1. Lock both affected rows in ascending user_id order (see guardrail
	//    comment). Reuse a small struct so the two rows are validated together
	//    after both locks are held.
	lockOrder := [2]int64{req.AgentID, req.UserID}
	if lockOrder[0] > lockOrder[1] {
		lockOrder[0], lockOrder[1] = lockOrder[1], lockOrder[0]
	}

	type walletRow struct {
		id       int64
		role     string
		balance  float64
		parentID sql.NullInt64
	}
	rows := make(map[int64]walletRow, 2)
	for _, id := range lockOrder {
		var row walletRow
		err = tx.QueryRowContext(ctx,
			`SELECT id, role, current_balance, parent_id
			   FROM users
			  WHERE id = $1
			    FOR UPDATE`, id).Scan(&row.id, &row.role, &row.balance, &row.parentID)
		if err != nil {
			return nil, fmt.Errorf("wallet row lock failed (id %d): %w", id, err)
		}
		rows[id] = row
	}

	agent := rows[req.AgentID]
	user := rows[req.UserID]

	// 2. Role & hierarchy checks under both locks.
	if agent.role != "AGENT" && agent.role != "SUPER_ADMIN" {
		return nil, fmt.Errorf("agent balance lock failed: invalid role %q", agent.role)
	}
	if user.role != "USER" {
		return nil, fmt.Errorf("user balance lock failed: invalid role %q", user.role)
	}
	if !user.parentID.Valid || user.parentID.Int64 != req.AgentID {
		return nil, ErrHierarchyViolation
	}

	// Fixed-point decimal arithmetic (guardrail): never raw float64 for
	// currency math. Round to 2dp at the monetary boundary; float64 only at
	// the DB scan/write boundary below.
	amount := decimal.NewFromFloat(req.Amount).Round(2)
	agentBal := decimal.NewFromFloat(agent.balance).Round(2)
	userBal := decimal.NewFromFloat(user.balance).Round(2)

	var (
		newAgentBal decimal.Decimal
		newUserBal  decimal.Decimal
	)
	switch req.Direction {
	case DirectionDeposit:
		// 2b. Sufficiency: the agent must own the units being distributed.
		if agentBal.LessThan(amount) {
			return nil, ErrInsufficientBalance
		}
		newAgentBal = agentBal.Sub(amount)
		newUserBal = userBal.Add(amount)
	case DirectionWithdraw:
		// 2b. Sufficiency: the user must have the units being pulled back.
		if userBal.LessThan(amount) {
			return nil, ErrInsufficientBalance
		}
		newAgentBal = agentBal.Add(amount)
		newUserBal = userBal.Sub(amount)
	}

	agentBalAfter := newAgentBal.InexactFloat64()
	userBalAfter := newUserBal.InexactFloat64()

	// 3. Update Balances.
	_, err = tx.ExecContext(ctx,
		`UPDATE users SET current_balance = $1, updated_at = CURRENT_TIMESTAMP WHERE id = $2`,
		agentBalAfter, req.AgentID)
	if err != nil {
		return nil, fmt.Errorf("failed to update agent balance: %w", err)
	}

	_, err = tx.ExecContext(ctx,
		`UPDATE users SET current_balance = $1, updated_at = CURRENT_TIMESTAMP WHERE id = $2`,
		userBalAfter, req.UserID)
	if err != nil {
		return nil, fmt.Errorf("failed to update user balance: %w", err)
	}

	// 4. Record Double-Entry Ledger. Every movement writes exactly two rows:
	//    a debit on the side that loses units and a credit on the side that
	//    gains them (amount_change sums to zero).
	ledgerQuery := `
		INSERT INTO unit_ledger
		    (user_id, ref_user_id, request_id, bet_id, type, amount_change,
		     balance_before, balance_after, description)
		 VALUES ($1, $2, NULL, NULL, $3, $4, $5, $6, $7)`

	switch req.Direction {
	case DirectionDeposit:
		// Agent Ledger (Negative Change — debit).
		if _, err := tx.ExecContext(ctx, ledgerQuery,
			req.AgentID, req.UserID, "WITHDRAW", amount.Neg().InexactFloat64(),
			agent.balance, agentBalAfter,
			ledgerDescription("Transfer to User %d", req.UserID, req.Description),
		); err != nil {
			return nil, fmt.Errorf("agent ledger write failed: %w", err)
		}
		// User Ledger (Positive Change — credit).
		if _, err := tx.ExecContext(ctx, ledgerQuery,
			req.UserID, req.AgentID, "DEPOSIT", amount.InexactFloat64(),
			user.balance, userBalAfter,
			ledgerDescription("Transfer from Agent %d", req.AgentID, req.Description),
		); err != nil {
			return nil, fmt.Errorf("user ledger write failed: %w", err)
		}
	case DirectionWithdraw:
		// User Ledger first (debit from the user's balance).
		if _, err := tx.ExecContext(ctx, ledgerQuery,
			req.UserID, req.AgentID, "WITHDRAW", amount.Neg().InexactFloat64(),
			user.balance, userBalAfter,
			ledgerDescription("Transfer back to Agent %d", req.AgentID, req.Description),
		); err != nil {
			return nil, fmt.Errorf("user ledger write failed: %w", err)
		}
		// Agent Ledger (credit back to the agent's balance).
		if _, err := tx.ExecContext(ctx, ledgerQuery,
			req.AgentID, req.UserID, "DEPOSIT", amount.InexactFloat64(),
			agent.balance, agentBalAfter,
			ledgerDescription("Transfer from User %d", req.UserID, req.Description),
		); err != nil {
			return nil, fmt.Errorf("agent ledger write failed: %w", err)
		}
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit transfer: %w", err)
	}

	return &TransferResult{AgentBalance: agentBalAfter, UserBalance: userBalAfter}, nil
}

// ledgerDescription builds a stable ledger description, appending the optional
// operator note so auditors can trace who/what triggered the movement.
func ledgerDescription(format string, counterparty int64, note string) string {
	if note == "" {
		return fmt.Sprintf(format, counterparty)
	}
	return fmt.Sprintf("%s: %s", fmt.Sprintf(format, counterparty), note)
}
