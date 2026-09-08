package wallet

import (
	"context"
	"database/sql"
	"fmt"
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

// TransferRequest describes an agent→user or admin→user units transfer.
type TransferRequest struct {
	AgentID     int64
	UserID      int64
	Amount      float64
	Description string
}

// TransferError is the domain error surfaced to the HTTP handler.
type TransferError struct {
	Reason string
}

// Sentinel errors distinguish wallet failures at the HTTP mapping layer.
var (
	ErrInsufficientBalance = TransferError{Reason: "insufficient agent balance"}
	ErrHierarchyViolation  = TransferError{Reason: "user does not belong to agent"}
	ErrInvalidAmount       = TransferError{Reason: "amount must be greater than zero"}
)

func (e TransferError) Error() string { return e.Reason }

// TransferUnits moves [Amount] from Agent's current_balance to User's
// current_balance atomically. Both ledger rows (debit on agent, credit on
// user) are written inside the same ACID transaction under pessimistic
// FOR UPDATE row locks. This is safe to call concurrently.
//
// DEADLOCK GUARDRAIL: both affected rows are locked in ascending user_id
// order. Every multi-user wallet operation must acquire locks in the same
// canonical order; any other ordering lets two concurrent transfers on the
// same agent/user pair lock in opposite sequence and deadlock under load.
func (w *Engine) TransferUnits(ctx context.Context, req TransferRequest) error {
	if req.Amount <= 0 {
		return ErrInvalidAmount
	}

	tx, err := w.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead})
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
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
			return fmt.Errorf("wallet row lock failed (id %d): %w", id, err)
		}
		rows[id] = row
	}

	agent := rows[req.AgentID]
	user := rows[req.UserID]

	// 2. Role & hierarchy checks under both locks.
	if agent.role != "AGENT" && agent.role != "SUPER_ADMIN" {
		return fmt.Errorf("agent balance lock failed: invalid role %q", agent.role)
	}
	if user.role != "USER" {
		return fmt.Errorf("user balance lock failed: invalid role %q", user.role)
	}
	if !user.parentID.Valid || user.parentID.Int64 != req.AgentID {
		return ErrHierarchyViolation
	}
	if agent.balance < req.Amount {
		return ErrInsufficientBalance
	}

	agentBalance := agent.balance
	userBalance := user.balance

	// 3. Update Balances.
	newAgentBal := agentBalance - req.Amount
	newUserBal := userBalance + req.Amount

	_, err = tx.ExecContext(ctx,
		`UPDATE users SET current_balance = $1, updated_at = CURRENT_TIMESTAMP WHERE id = $2`,
		newAgentBal, req.AgentID)
	if err != nil {
		return fmt.Errorf("failed to deduct agent balance: %w", err)
	}

	_, err = tx.ExecContext(ctx,
		`UPDATE users SET current_balance = $1, updated_at = CURRENT_TIMESTAMP WHERE id = $2`,
		newUserBal, req.UserID)
	if err != nil {
		return fmt.Errorf("failed to credit user balance: %w", err)
	}

	// 4. Record Double-Entry Ledger.
	ledgerQuery := `
		INSERT INTO unit_ledger
		    (user_id, ref_user_id, bet_id, type, amount_change,
		     balance_before, balance_after, description)
		 VALUES ($1, $2, NULL, $3, $4, $5, $6, $7)`

	// Agent Ledger (Negative Change — debit).
	_, err = tx.ExecContext(ctx, ledgerQuery,
		req.AgentID, req.UserID, "WITHDRAW", -req.Amount,
		agentBalance, newAgentBal,
		fmt.Sprintf("Transfer to User %d: %s", req.UserID, req.Description))
	if err != nil {
		return fmt.Errorf("agent ledger write failed: %w", err)
	}

	// User Ledger (Positive Change — credit).
	_, err = tx.ExecContext(ctx, ledgerQuery,
		req.UserID, req.AgentID, "DEPOSIT", req.Amount,
		userBalance, newUserBal,
		fmt.Sprintf("Received from Agent %d: %s", req.AgentID, req.Description))
	if err != nil {
		return fmt.Errorf("user ledger write failed: %w", err)
	}

	return tx.Commit()
}
