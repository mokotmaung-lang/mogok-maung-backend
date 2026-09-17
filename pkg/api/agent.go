package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/lib/pq"
	"github.com/shopspring/decimal"
	"golang.org/x/crypto/bcrypt"
	"mogok-maung-backend/pkg/auth"
	"mogok-maung-backend/pkg/bet"
	"mogok-maung-backend/pkg/wallet"
)

// DefaultDownlinePassword is the bootstrap credential assigned when an agent
// provisions a new user account. The user is expected to change it on first
// login.
const DefaultDownlinePassword = "Default@123"

// downlineNotYours is the canonical 403 body when an agent targets a user that
// is not one of its own downlines (Strict Tenant Isolation Law). Kept as a
// single constant so the allocate-units guard, the direct transfer, the
// unit-request relay, the toggle and the sandbox bench all surface the same
// message.
const downlineNotYours = "ခွင့်ပြုချက်မရှိပါ။ ဤယူဆာသည် သင်၏လက်အောက်ခံ (Downline) မဟုတ်ပါ။"

// AgentHandler exposes AGENT-tier management endpoints.
type AgentHandler struct {
	db *sql.DB
}

// NewAgentHandler builds an AgentHandler.
func NewAgentHandler(db *sql.DB) *AgentHandler {
	return &AgentHandler{db: db}
}

type createUserRequest struct {
	Username       string  `json:"username"`
	Phone          string  `json:"phone"`
	InitialBalance float64 `json:"initial_balance"`
}

// CreateDownlineUser provisions a USER account owned by the calling agent.
//
// An optional initial_balance opens the player wallet in the same atomic
// transaction as the account row. The agent's own wallet row is locked
// pessimistically (SELECT ... FOR UPDATE), verified for role/activity and
// sufficiency, then debited while the new user is credited — with the standard
// double-entry ledger written for both legs. Every step runs inside ONE
// transaction, so a failure anywhere rolls the whole provisioning back:
// no half-created account, no units vanishing off the agent's balance.
//
//	POST /api/v1/agent/users/create
//	{ "username": "mg_min", "phone": "09...", "initial_balance": 50000 }
func (h *AgentHandler) CreateDownlineUser(w http.ResponseWriter, r *http.Request) {
	var req createUserRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	req.Phone = strings.TrimSpace(req.Phone)
	if req.Username == "" || req.Phone == "" {
		writeError(w, http.StatusBadRequest, "username and phone are required")
		return
	}
	if len(req.Username) > 50 {
		writeError(w, http.StatusBadRequest, "username must be 50 characters or fewer")
		return
	}
	if len(req.Phone) > 30 {
		writeError(w, http.StatusBadRequest, "phone must be 30 characters or fewer")
		return
	}

	opening, ok := validateWalletAmount(req.InitialBalance)
	if !ok {
		writeError(w, http.StatusBadRequest, "initial_balance must be a finite, non-negative amount")
		return
	}

	agentID, _ := auth.PrincipalFrom(r.Context())

	hash, err := bcrypt.GenerateFromPassword([]byte(DefaultDownlinePassword), bcrypt.DefaultCost)
	if err != nil {
		log.Printf("agent: hash default password: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	tx, err := h.db.BeginTx(r.Context(), nil)
	if err != nil {
		log.Printf("agent: begin create user: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	defer tx.Rollback() // no-op after Commit.

	var agentBalance float64
	if opening > 0 {
		// Pessimistic lock on the calling agent's wallet row. Only one
		// pre-existing row is locked here (the new user row does not exist
		// yet), so the ascending-lock-order deadlock guardrail is trivially
		// satisfied.
		var (
			role     string
			isActive bool
			current  float64
		)
		err = tx.QueryRowContext(r.Context(),
			`SELECT role, current_balance, is_active
			   FROM users WHERE id = $1 FOR UPDATE`,
			agentID.UserID,
		).Scan(&role, &current, &isActive)
		if isNoRows(err) {
			writeError(w, http.StatusNotFound, "agent account not found")
			return
		}
		if err != nil {
			log.Printf("agent: lock agent %d: %v", agentID.UserID, err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
		if role != "AGENT" && role != "SUPER_ADMIN" {
			writeError(w, http.StatusForbidden, "only AGENT or SUPER_ADMIN accounts may provision users with a balance")
			return
		}
		if !isActive {
			writeError(w, http.StatusForbidden, "agent account is suspended; users cannot be created with a balance")
			return
		}
		if current < opening {
			writeError(w, http.StatusUnprocessableEntity,
				"agent current balance is insufficient for the requested initial balance")
			return
		}
		agentBalance = current
	}

	var userID int64
	err = tx.QueryRowContext(r.Context(), `
		INSERT INTO users (username, password_hash, name, role, parent_id,
		                    current_balance, hold_balance, is_active, phone,
		                    must_change_password)
		VALUES ($1, $2, $3, 'USER', $4, $5, 0.0, TRUE, $6, TRUE)
		RETURNING id`,
		req.Username, string(hash), req.Username, agentID.UserID, opening, req.Phone,
	).Scan(&userID)
	if err != nil {
		var pqErr *pq.Error
		if errors.As(err, &pqErr) && pqErr.Code == "23505" { // unique_violation
			writeError(w, http.StatusConflict, "username or phone already exists")
			return
		}
		log.Printf("agent: create downline user: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	agentBalanceAfter := 0.0
	if opening > 0 {
		amount := decimal.NewFromFloat(opening).Round(2)
		agentBalanceAfter = decimal.NewFromFloat(agentBalance).
			Sub(amount).Round(2).InexactFloat64()

		if _, err := tx.ExecContext(r.Context(),
			`UPDATE users SET current_balance = $1, updated_at = CURRENT_TIMESTAMP WHERE id = $2`,
			agentBalanceAfter, agentID.UserID,
		); err != nil {
			log.Printf("agent: debit agent %d: %v", agentID.UserID, err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}

		// Double-entry ledger: credit the new user, debit the agent. The two
		// amount_changes sum to zero and every leg carries the counterparty.
		if _, err := tx.ExecContext(r.Context(), `
			INSERT INTO unit_ledger
			    (user_id, ref_user_id, request_id, bet_id, type, amount_change,
			     balance_before, balance_after, description)
			 VALUES ($1, $2, NULL, NULL, 'DEPOSIT', $3, 0.0, $4, $5)`,
			userID, agentID.UserID, amount.InexactFloat64(), opening,
			fmt.Sprintf("Initial balance granted on account creation (Agent %d)", agentID.UserID),
		); err != nil {
			log.Printf("agent: user ledger leg: %v", err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
		if _, err := tx.ExecContext(r.Context(), `
			INSERT INTO unit_ledger
			    (user_id, ref_user_id, request_id, bet_id, type, amount_change,
			     balance_before, balance_after, description)
			 VALUES ($1, $2, NULL, NULL, 'WITHDRAW', $3, $4, $5, $6)`,
			agentID.UserID, userID, amount.Neg().InexactFloat64(), agentBalance, agentBalanceAfter,
			fmt.Sprintf("Initial balance top-up to User %d", userID),
		); err != nil {
			log.Printf("agent: agent ledger leg: %v", err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
	}

	if err := tx.Commit(); err != nil {
		log.Printf("agent: commit create user: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"user_id":         userID,
		"username":        req.Username,
		"phone":           req.Phone,
		"role":            "USER",
		"initial_balance": opening,
		"user_balance":    opening,
		"agent_balance":   agentBalanceAfter,
	})
}

// validateWalletAmount normalises a money amount for wallet writes: NaN/Inf is
// rejected, negatives are rejected, values beyond NUMERIC(15,2) capacity are
// rejected, and positive values are rounded to 2dp at the monetary boundary.
func validateWalletAmount(v float64) (float64, bool) {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, false
	}
	if v < 0 {
		return 0, false
	}
	if v > nineTrillion {
		return 0, false
	}
	return decimal.NewFromFloat(v).Round(2).InexactFloat64(), true
}

type forwardRequest struct {
	UserID int64   `json:"user_id"`
	Amount float64 `json:"amount"`
	Type   string  `json:"type"` // DEPOSIT | WITHDRAW
}

// CreateUnitRequest forwards a downline's deposit/withdraw request to the
// SUPER_ADMIN approval queue.
func (h *AgentHandler) CreateUnitRequest(w http.ResponseWriter, r *http.Request) {
	var req forwardRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.UserID <= 0 || req.Amount <= 0 {
		writeError(w, http.StatusBadRequest, "user_id and positive amount are required")
		return
	}
	if req.Type != "DEPOSIT" && req.Type != "WITHDRAW" {
		writeError(w, http.StatusBadRequest, "type must be DEPOSIT or WITHDRAW")
		return
	}

	agentID, _ := auth.PrincipalFrom(r.Context())

	// Only an agent may forward requests for its own downlines.
	var parentID sql.NullInt64
	err := h.db.QueryRowContext(r.Context(),
		`SELECT parent_id FROM users WHERE id = $1`, req.UserID,
	).Scan(&parentID)
	if isNoRows(err) {
		writeError(w, http.StatusNotFound, "downline user not found")
		return
	}
	if err != nil {
		log.Printf("agent: load downline %d: %v", req.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if !parentID.Valid || parentID.Int64 != agentID.UserID {
		writeError(w, http.StatusForbidden, downlineNotYours)
		return
	}

	var requestID int64
	err = h.db.QueryRowContext(r.Context(), `
		INSERT INTO unit_requests (requester_id, approver_id, amount, type, status)
		VALUES ($1, NULL, $2, $3, 'PENDING')
		RETURNING id`,
		req.UserID, req.Amount, req.Type,
	).Scan(&requestID)
	if err != nil {
		log.Printf("agent: forward unit request: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"request_id": requestID,
		"status":     "PENDING",
		"type":       req.Type,
		"amount":     req.Amount,
	})
}

type transferDownlineUnitsRequest struct {
	UserID int64   `json:"user_id"`
	Amount float64 `json:"amount"`
	Type   string  `json:"type"` // DEPOSIT (agent -> user) | WITHDRAW (user -> agent)
}

// TransferDownlineUnits moves units directly between the calling agent's own
// balance and one of its downline users — no admin approval involved. The
// wallet engine locks both rows in ascending user_id order inside one
// transaction and writes the double-entry ledger (debit + credit) atomically.
//
//	POST /api/v1/agent/units/transfer
//	{ "user_id": 42, "amount": 50000, "type": "DEPOSIT" | "WITHDRAW" }
func (h *AgentHandler) TransferDownlineUnits(w http.ResponseWriter, r *http.Request) {
	var req transferDownlineUnitsRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.UserID <= 0 {
		writeError(w, http.StatusBadRequest, "user_id must be a positive integer")
		return
	}
	if req.Amount <= 0 {
		writeError(w, http.StatusBadRequest, "amount must be greater than zero")
		return
	}
	trxType := strings.ToUpper(strings.TrimSpace(req.Type))
	if trxType != "DEPOSIT" && trxType != "WITHDRAW" {
		writeError(w, http.StatusBadRequest, "type must be DEPOSIT or WITHDRAW")
		return
	}

	agentID, _ := auth.PrincipalFrom(r.Context())
	if agentID.UserID == req.UserID {
		writeError(w, http.StatusBadRequest, "cannot transfer units to yourself")
		return
	}

	engine := wallet.Engine{DB: h.db}
	res, err := engine.TransferUnits(r.Context(), wallet.TransferRequest{
		AgentID:     agentID.UserID,
		UserID:      req.UserID,
		Amount:      req.Amount,
		Direction:   wallet.Direction(trxType),
		Description: "Agent dashboard direct transfer",
	})
	if err != nil {
		var terr wallet.TransferError
		switch {
		case errors.As(err, &terr):
			switch {
			case errors.Is(terr, wallet.ErrInsufficientBalance):
				if trxType == "DEPOSIT" {
					writeError(w, http.StatusUnprocessableEntity,
						"လက်ကျန် Unit မလုံလောက်ပါ။ Admin ထံ Unit တောင်းဆိုပါ (Insufficient Agent Balance)")
				} else {
					writeError(w, http.StatusUnprocessableEntity,
						"ယူဆာ လက်ကျန် Unit မလုံလောက်ပါ (Insufficient User Balance)")
				}
			case errors.Is(terr, wallet.ErrHierarchyViolation):
				writeError(w, http.StatusForbidden, downlineNotYours)
			case errors.Is(terr, wallet.ErrInvalidAmount):
				writeError(w, http.StatusBadRequest, terr.Error())
			case errors.Is(terr, wallet.ErrInvalidDirection):
				writeError(w, http.StatusBadRequest, terr.Error())
			default:
				log.Printf("agent: transfer units %d: %v", req.UserID, err)
				writeError(w, http.StatusInternalServerError, "internal server error")
			}
		case errors.Is(err, sql.ErrNoRows):
			writeError(w, http.StatusNotFound, "downline user not found")
		default:
			log.Printf("agent: transfer units %d: %v", req.UserID, err)
			writeError(w, http.StatusInternalServerError, "internal server error")
		}
		return
	}

	var message string
	if trxType == "DEPOSIT" {
		message = fmt.Sprintf("ယူဆာ ထံ ယူနစ် %.2f ထည့်သွင်းပြီးပါပြီ (Agent → Downline)", req.Amount)
	} else {
		message = fmt.Sprintf("ယူဆာ ထံမှ ယူနစ် %.2f ပြန်ရယူပြီးပါပြီ (Downline → Agent)", req.Amount)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": message,
		"data": map[string]interface{}{
			"user_id":       req.UserID,
			"amount":        req.Amount,
			"type":          trxType,
			"agent_balance": res.AgentBalance,
			"user_balance":  res.UserBalance,
		},
	})
}

type allocateDownlineUnitsRequest struct {
	Amount float64 `json:"amount"`
	Type   string  `json:"type"` // DEPOSIT (agent -> user) | WITHDRAW (user -> agent)
	Note   string  `json:"note"` // optional free-text context for the ledger
}

// AllocateDownlineUnits is the strict-tenant unit allocation endpoint an agent
// uses to move units between its own balance and one of its downline users:
//
//	POST /api/v1/agent/users/{id}/allocate-units
//	{ "amount": 50000, "type": "DEPOSIT" | "WITHDRAW", "note": "..." }
//
// One secure transaction drives the whole request: the calling agent and the
// target user rows are locked FOR UPDATE (ascending user_id — deadlock
// guardrail), an explicit hierarchy mapping check runs first
// (`id = $1 AND parent_id = $2 AND role = 'USER'`), then the fixed-point
// balance movement and the double-entry ledger complete through
// wallet.ApplyTransfer inside the same tx. Any mapping failure returns 403 with
// the canonical downline message. Target users NOT owned by the calling agent
// are completely unreachable.
func (h *AgentHandler) AllocateDownlineUnits(w http.ResponseWriter, r *http.Request) {
	targetUserID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || targetUserID <= 0 {
		writeError(w, http.StatusBadRequest, "invalid user id path parameter")
		return
	}
	agentID, _ := auth.PrincipalFrom(r.Context())
	if agentID.UserID == targetUserID {
		writeError(w, http.StatusBadRequest, "cannot allocate units to yourself")
		return
	}

	var req allocateDownlineUnitsRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.Amount <= 0 {
		writeError(w, http.StatusBadRequest, "amount must be greater than zero")
		return
	}
	req.Note = strings.TrimSpace(req.Note)
	if len(req.Note) > 500 {
		writeError(w, http.StatusBadRequest, "note must be 500 characters or fewer")
		return
	}
	trxType := strings.ToUpper(strings.TrimSpace(req.Type))
	if trxType != "DEPOSIT" && trxType != "WITHDRAW" {
		writeError(w, http.StatusBadRequest, "type must be DEPOSIT or WITHDRAW")
		return
	}

	tx, err := h.db.BeginTx(r.Context(), nil)
	if err != nil {
		log.Printf("agent: allocate begin tx: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	defer tx.Rollback() // no-op after Commit.

	// Explicit hierarchy mapping validation inside the enclosing transaction.
	// Strict Tenant Isolation Law: the target must be a USER whose parent_id is
	// an EXACT match to the calling agent's id.
	var isDownline bool
	err = tx.QueryRowContext(r.Context(),
		`SELECT EXISTS(
		     SELECT 1 FROM users
		      WHERE id = $1 AND parent_id = $2 AND role = 'USER'
		   )`, targetUserID, agentID.UserID,
	).Scan(&isDownline)
	if err != nil {
		log.Printf("agent: allocate hierarchy check %d: %v", targetUserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if !isDownline {
		writeError(w, http.StatusForbidden, downlineNotYours)
		return
	}

	res, err := wallet.ApplyTransfer(r.Context(), tx, wallet.TransferRequest{
		AgentID:     agentID.UserID,
		UserID:      targetUserID,
		Amount:      req.Amount,
		Direction:   wallet.Direction(trxType),
		Description: req.Note,
	})
	if err != nil {
		var terr wallet.TransferError
		switch {
		case errors.As(err, &terr):
			switch {
			case errors.Is(terr, wallet.ErrInsufficientBalance):
				if trxType == "DEPOSIT" {
					writeError(w, http.StatusUnprocessableEntity,
						"လက်ကျန် Unit မလုံလောက်ပါ။ Admin ထံ Unit တောင်းဆိုပါ (Insufficient Agent Balance)")
				} else {
					writeError(w, http.StatusUnprocessableEntity,
						"ယူဆာ လက်ကျန် Unit မလုံလောက်ပါ (Insufficient User Balance)")
				}
			case errors.Is(terr, wallet.ErrHierarchyViolation):
				writeError(w, http.StatusForbidden, downlineNotYours)
			case errors.Is(terr, wallet.ErrInvalidAmount):
				writeError(w, http.StatusBadRequest, terr.Error())
			case errors.Is(terr, wallet.ErrInvalidDirection):
				writeError(w, http.StatusBadRequest, terr.Error())
			default:
				log.Printf("agent: allocate units to %d: %v", targetUserID, err)
				writeError(w, http.StatusInternalServerError, "internal server error")
			}
		case errors.Is(err, sql.ErrNoRows):
			writeError(w, http.StatusNotFound, "downline user not found")
		default:
			log.Printf("agent: allocate units to %d: %v", targetUserID, err)
			writeError(w, http.StatusInternalServerError, "internal server error")
		}
		return
	}

	if err := tx.Commit(); err != nil {
		log.Printf("agent: allocate commit %d: %v", targetUserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	var message string
	if trxType == "DEPOSIT" {
		message = fmt.Sprintf("ယူဆာ ထံ ယူနစ် %.2f ထည့်သွင်းပြီးပါပြီ (Agent → Downline)", req.Amount)
	} else {
		message = fmt.Sprintf("ယူဆာ ထံမှ ယူနစ် %.2f ပြန်ရယူပြီးပါပြီ (Downline → Agent)", req.Amount)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": message,
		"data": map[string]interface{}{
			"user_id":       targetUserID,
			"amount":        req.Amount,
			"type":          trxType,
			"agent_balance": res.AgentBalance,
			"user_balance":  res.UserBalance,
		},
	})
}

type agentUnitRequest struct {
	Amount float64 `json:"amount"`
	Type   string  `json:"type"` // DEPOSIT (top-up) | WITHDRAW (cash-out)
	Note   string  `json:"note"` // optional free-text context for the Super Admin
}

// CreateAgentUnitRequest requests a top-up (DEPOSIT) or cash-out (WITHDRAW) of
// the calling AGENT's own balance from the SUPER_ADMIN approval queue. The
// requester of record is the agent itself (not a downline), so on approval the
// approved units land in exactly that agent's Unit Balance:
//
//	POST /api/v1/agent/unit-requests
//	{ "amount": 100000, "type": "DEPOSIT", "note": "weekly top-up" }
func (h *AgentHandler) CreateAgentUnitRequest(w http.ResponseWriter, r *http.Request) {
	var req agentUnitRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.Amount <= 0 {
		writeError(w, http.StatusBadRequest, "amount must be greater than zero")
		return
	}
	trxType := strings.ToUpper(strings.TrimSpace(req.Type))
	if trxType != "DEPOSIT" && trxType != "WITHDRAW" {
		writeError(w, http.StatusBadRequest, "type must be DEPOSIT or WITHDRAW")
		return
	}
	req.Note = strings.TrimSpace(req.Note)
	if len(req.Note) > 500 {
		writeError(w, http.StatusBadRequest, "note must be 500 characters or fewer")
		return
	}

	agentID, _ := auth.PrincipalFrom(r.Context())

	// Stash the optional note inside the JSONB payment_info column so the
	// Super Admin can see the agent's context without a schema change.
	var paymentInfo []byte
	if req.Note != "" {
		noteJSON, err := json.Marshal(map[string]string{"note": req.Note})
		if err != nil {
			log.Printf("agent: marshal note %d: %v", agentID.UserID, err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
		paymentInfo = noteJSON
	}

	var requestID int64
	err := h.db.QueryRowContext(r.Context(), `
		INSERT INTO unit_requests (requester_id, approver_id, amount, type, status, payment_info)
		VALUES ($1, NULL, $2, $3, 'PENDING', $4)
		RETURNING id`,
		agentID.UserID, req.Amount, trxType, paymentInfo,
	).Scan(&requestID)
	if err != nil {
		log.Printf("agent: create unit request %d: %v", agentID.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"success": true,
		"message": "Super Admin ထံ ယူနစ်တောင်းခံမှုကို ပေးပို့ပြီးပါပြီ။ အတည်ပြုပြီးပါက Agent Unit Balance သို့ အလိုအလျောက် ထည့်သွင်းပေးပါမည်။",
		"data": map[string]interface{}{
			"request_id": requestID,
			"status":     "PENDING",
			"type":       trxType,
			"amount":     req.Amount,
			"note":       req.Note,
		},
	})
}

// ListDownlines returns the calling agent's direct users with balances.
func (h *AgentHandler) ListDownlines(w http.ResponseWriter, r *http.Request) {
	agentID, _ := auth.PrincipalFrom(r.Context())

	rows, err := h.db.QueryContext(r.Context(), `
		SELECT u.id, u.username, u.name, u.phone,
		       u.current_balance, u.hold_balance, u.is_active, u.created_at,
		       (SELECT COUNT(*) FROM bets b WHERE b.user_id = u.id AND b.status = 'PENDING')
		  FROM users u
		 WHERE u.parent_id = $1
		 ORDER BY u.created_at DESC`,
		agentID.UserID,
	)
	if err != nil {
		log.Printf("agent: list downlines: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	defer rows.Close()

	type downline struct {
		ID             int64     `json:"id"`
		Username       string    `json:"username"`
		Name           string    `json:"name"`
		Phone          string    `json:"phone"`
		CurrentBalance float64   `json:"current_balance"`
		HoldBalance    float64   `json:"hold_balance"`
		IsActive       bool      `json:"is_active"`
		ActiveBets     int       `json:"active_bets"`
		CreatedAt      time.Time `json:"created_at"`
	}

	out := make([]downline, 0, 16)
	for rows.Next() {
		var d downline
		var phone sql.NullString
		var createdAt sql.NullTime
		if err := rows.Scan(&d.ID, &d.Username, &d.Name, &phone,
			&d.CurrentBalance, &d.HoldBalance, &d.IsActive, &createdAt, &d.ActiveBets); err != nil {
			log.Printf("agent: scan downline: %v", err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
		if phone.Valid {
			d.Phone = phone.String
		}
		if createdAt.Valid {
			d.CreatedAt = createdAt.Time
		}
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		log.Printf("agent: iterate downlines: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"downlines": out})
}

// agentContactProfile is the editable contact info an agent exposes to its
// downline users (deep-link sources for Viber / Telegram / phone) plus an
// optional webhook for the agent's own bot integration.
//
// The nullable DB columns map to pointers so an unset value serializes as an
// omitted JSON key (omitempty) instead of a misleading empty string.
type agentContactProfile struct {
	ViberNumber      *string   `json:"viber_number,omitempty"`
	TelegramUsername *string   `json:"telegram_username,omitempty"`
	PhoneNumber      *string   `json:"phone_number,omitempty"`
	WebhookURL       *string   `json:"webhook_url,omitempty"`
	UpdatedAt        time.Time `json:"updated_at"`
}

type updateContactProfileRequest struct {
	ViberNumber      string `json:"viber_number"`
	TelegramUsername string `json:"telegram_username"`
	PhoneNumber      string `json:"phone_number"`
	WebhookURL       string `json:"webhook_url"`
}

var (
	phonePattern       = regexp.MustCompile(`^\+?[0-9][0-9 \-]{6,19}$`)
	telegramPattern    = regexp.MustCompile(`^[a-zA-Z0-9_]{5,32}$`)
	webhookURLPatterns = []regexp.Regexp{
		*regexp.MustCompile(`(?i)^https?://`),
	}
)

func validPhone(v string) bool { return phonePattern.MatchString(strings.TrimSpace(v)) }

func validWebhookURL(v string) bool {
	v = strings.TrimSpace(v)
	if v == "" {
		return true // optional
	}
	for _, re := range webhookURLPatterns {
		if re.MatchString(v) {
			return true
		}
	}
	return false
}

// GetAgentContactProfile returns the calling agent's stored contact info.
func (h *AgentHandler) GetAgentContactProfile(w http.ResponseWriter, r *http.Request) {
	agentID, _ := auth.PrincipalFrom(r.Context())

	var p agentContactProfile
	var vb, tg, ph, wh sql.NullString
	err := h.db.QueryRowContext(r.Context(), `
		SELECT viber_number,
		       telegram_username,
		       phone_number,
		       webhook_url,
		       updated_at
		  FROM agent_profiles
		 WHERE agent_id = $1`,
		agentID.UserID,
	).Scan(&vb, &tg, &ph, &wh, &p.UpdatedAt)
	if isNoRows(err) {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"message": "ဆက်သွယ်ရန် အချက်အလက် မသတ်မှတ်ရသေးပါ။",
			"data": map[string]interface{}{
				"agent_id":          agentID.UserID,
				"viber_number":      "",
				"telegram_username": "",
				"phone_number":      "",
				"webhook_url":       "",
			},
		})
		return
	}
	if err != nil {
		log.Printf("agent: load contact profile %d: %v", agentID.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	p.ViberNumber = nullStrPtr(vb)
	p.TelegramUsername = nullStrPtr(tg)
	p.PhoneNumber = nullStrPtr(ph)
	p.WebhookURL = nullStrPtr(wh)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"agent_id":          agentID.UserID,
			"viber_number":      p.ViberNumber,
			"telegram_username": p.TelegramUsername,
			"phone_number":      p.PhoneNumber,
			"webhook_url":       p.WebhookURL,
			"updated_at":        p.UpdatedAt,
		},
	})
}

// nullStrPtr maps an optional DB column to a *string (nil when NULL), keeping
// optional columns honest in JSON responses via omitempty.
func nullStrPtr(v sql.NullString) *string {
	if !v.Valid {
		return nil
	}
	return &v.String
}

// UpdateAgentContactProfile upserts the caller agent's contact info:
//
//	PUT /api/v1/agent/profile/contact-info
func (h *AgentHandler) UpdateAgentContactProfile(w http.ResponseWriter, r *http.Request) {
	agentID, _ := auth.PrincipalFrom(r.Context())

	var req updateContactProfileRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	if req.ViberNumber != "" && !validPhone(req.ViberNumber) {
		writeError(w, http.StatusBadRequest, "viber_number must be a valid phone number (e.g. +959123456789)")
		return
	}
	if req.TelegramUsername != "" && !telegramPattern.MatchString(strings.TrimSpace(req.TelegramUsername)) {
		writeError(w, http.StatusBadRequest, "telegram_username must be 5-32 letters, digits or underscores")
		return
	}
	if req.PhoneNumber != "" && !validPhone(req.PhoneNumber) {
		writeError(w, http.StatusBadRequest, "phone_number must be a valid phone number (e.g. +959123456789)")
		return
	}
	if !validWebhookURL(req.WebhookURL) {
		writeError(w, http.StatusBadRequest, "webhook_url must start with http:// or https://")
		return
	}

	_, err := h.db.ExecContext(r.Context(), `
		INSERT INTO agent_profiles
		    (agent_id, viber_number, telegram_username, phone_number, webhook_url, updated_at)
		 VALUES ($1, NULLIF(TRIM($2), ''), NULLIF(TRIM($3), ''), NULLIF(TRIM($4), ''),
		         NULLIF(TRIM($5), ''), CURRENT_TIMESTAMP)
		 ON CONFLICT (agent_id) DO UPDATE
		 SET viber_number      = EXCLUDED.viber_number,
		     telegram_username = EXCLUDED.telegram_username,
		     phone_number      = EXCLUDED.phone_number,
		     webhook_url       = EXCLUDED.webhook_url,
		     updated_at        = CURRENT_TIMESTAMP`,
		agentID.UserID,
		req.ViberNumber, req.TelegramUsername, req.PhoneNumber, req.WebhookURL,
	)
	if err != nil {
		log.Printf("agent: save contact profile %d: %v", agentID.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "လူမှုကွန်ရက် ဆက်သွယ်ရန် အချက်အလက်များကို အောင်မြင်စွာ ပြင်ဆင်ပြီးပါပြီ။",
		"data": map[string]interface{}{
			"agent_id":   agentID.UserID,
			"updated_at": time.Now().UTC(),
		},
	})
}

// agentUserSummary is the downline view the Agent dashboard datatable renders:
// balances, active state, and join date for one downline user.
type agentUserSummary struct {
	UserID         int64     `json:"user_id"`
	Name           string    `json:"name"`
	Username       string    `json:"username"`
	CurrentBalance float64   `json:"current_balance"`
	HoldBalance    float64   `json:"hold_balance"`
	IsActive       bool      `json:"is_active"`
	CreatedAt      time.Time `json:"created_at"`
}

// ListAgentUserSummary returns the calling agent's downline users with
// balances, server-side pagination and name/username search:
//
//	GET /api/v1/agent/users/summary?page=1&limit=10&search=mgmg
//
// Response: { "success", "message", "data": [...], "pagination":
// { "current_page", "total_pages", "total_records" } }
func (h *AgentHandler) ListAgentUserSummary(w http.ResponseWriter, r *http.Request) {
	agentID, _ := auth.PrincipalFrom(r.Context())

	page := 1
	if v := r.URL.Query().Get("page"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 {
			page = n
		}
	}
	limit := 10
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 && n <= 100 {
			limit = n
		}
	}
	search := strings.TrimSpace(r.URL.Query().Get("search"))

	filter := "u.parent_id = $1"
	args := []interface{}{agentID.UserID}
	if search != "" {
		filter += " AND (u.username ILIKE $2 OR u.name ILIKE $2)"
		args = append(args, "%"+search+"%")
	}

	var total int64
	if err := h.db.QueryRowContext(r.Context(),
		`SELECT COUNT(*) FROM users u WHERE `+filter, args...,
	).Scan(&total); err != nil {
		log.Printf("agent: count downlines: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	rows, err := h.db.QueryContext(r.Context(), `
		SELECT u.id, u.name, u.username, u.current_balance, u.hold_balance,
		       u.is_active, u.created_at
		  FROM users u
		 WHERE `+filter+`
		 ORDER BY u.created_at DESC, u.id DESC
		 LIMIT $`+fmt.Sprintf("%d", len(args)+1)+` OFFSET $`+fmt.Sprintf("%d", len(args)+2),
		append(args, limit, (page-1)*limit)...,
	)
	if err != nil {
		log.Printf("agent: list downline summary: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	defer rows.Close()

	out := make([]agentUserSummary, 0, limit)
	for rows.Next() {
		var s agentUserSummary
		if err := rows.Scan(&s.UserID, &s.Name, &s.Username, &s.CurrentBalance,
			&s.HoldBalance, &s.IsActive, &s.CreatedAt,
		); err != nil {
			log.Printf("agent: scan downline summary: %v", err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		log.Printf("agent: iterate downline summary: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	totalPages := int64(0)
	if total > 0 {
		totalPages = (total + int64(limit) - 1) / int64(limit)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "လက်အောက်ခံ ယူဆာစာရင်းချုပ်ကို အောင်မြင်စွာ ရယူပြီးပါပြီ။",
		"data":    out,
		"pagination": map[string]interface{}{
			"current_page":  page,
			"total_pages":   totalPages,
			"total_records": total,
		},
	})
}

type toggleAgentUserRequest struct {
	UserID   int64 `json:"user_id"`
	IsActive bool  `json:"is_active"`
}

// ToggleAgentUserStatus suspends/activates one of the agent's own downline
// users. Ownership is locked down: the target must be a USER role whose
// parent_id equals the calling agent, otherwise the toggle is rejected.
func (h *AgentHandler) ToggleAgentUserStatus(w http.ResponseWriter, r *http.Request) {
	agentID, _ := auth.PrincipalFrom(r.Context())

	var req toggleAgentUserRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.UserID <= 0 {
		writeError(w, http.StatusBadRequest, "user_id must be a positive integer")
		return
	}

	var parentID sql.NullInt64
	err := h.db.QueryRowContext(r.Context(),
		`SELECT parent_id FROM users WHERE id = $1 AND role = 'USER'`, req.UserID,
	).Scan(&parentID)
	if isNoRows(err) {
		writeError(w, http.StatusNotFound, "downline user not found")
		return
	}
	if err != nil {
		log.Printf("agent: load downline %d: %v", req.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if !parentID.Valid || parentID.Int64 != agentID.UserID {
		writeError(w, http.StatusForbidden, downlineNotYours)
		return
	}

	var username string
	err = h.db.QueryRowContext(r.Context(), `
		UPDATE users
		   SET is_active = $1, updated_at = CURRENT_TIMESTAMP
		 WHERE id = $2 AND role = 'USER'
		 RETURNING username`,
		req.IsActive, req.UserID,
	).Scan(&username)
	if err != nil {
		log.Printf("agent: toggle downline %d: %v", req.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	message := fmt.Sprintf("ယူဆာ '%s' ၏ အကောင့်ကို ပိတ်ထားလိုက်ပါပြီ။", username)
	if req.IsActive {
		message = fmt.Sprintf("ယူဆာ '%s' ၏ အကောင့်ကို ပြန်လည်ဖွင့်လိုက်ပါပြီ။", username)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": message,
		"data": map[string]interface{}{
			"user_id":   req.UserID,
			"is_active": req.IsActive,
		},
	})
}

type sandboxTestBetRequest struct {
	UserID       int64   `json:"user_id"`
	BetType      string  `json:"bet_type"` // BODY | MAUNG
	TotalStake   float64 `json:"total_stake"`
	MatchID      int64   `json:"match_id"`
	Pick         string  `json:"pick"` // HOME | AWAY | DRAW | OVER | UNDER
	BodyOddsType string  `json:"body_odds_type"`
}

// SandboxTestBet lets an agent run a verified BODY/MAUNG bet-slip against one
// of its own downline users — the sandbox test-bench trigger. The bet is
// placed through the exact same atomic wallet engine as a real user wager
// (row-locked hold allocation + immutable BET_HOLD ledger row), then the
// handler re-reads the user's wallet and the ledger to prove the hold actually
// landed. The agent never sees the user's password/session; the bet runs on
// the user's own balance, so a sandbox slip holding units is fully visible to
// the end user and settles normally if it goes PENDING -> WIN/LOSE.
//
//	POST /api/v1/agent/sandbox/test-bet
//	{ "user_id": 42, "bet_type": "BODY", "total_stake": 10000,
//	  "match_id": 7, "pick": "HOME", "body_odds_type": "0+00" }
func (h *AgentHandler) SandboxTestBet(w http.ResponseWriter, r *http.Request) {
	agentID, _ := auth.PrincipalFrom(r.Context())

	var req sandboxTestBetRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.UserID <= 0 || req.MatchID <= 0 {
		writeError(w, http.StatusBadRequest, "user_id and match_id must be positive integers")
		return
	}

	placeReq := bet.PlaceBetRequest{
		BetType:    bet.BetType(strings.ToUpper(strings.TrimSpace(req.BetType))),
		TotalStake: req.TotalStake,
		Selections: []bet.Selection{{
			MatchID:      req.MatchID,
			Pick:         bet.SelectionPick(strings.ToUpper(strings.TrimSpace(req.Pick))),
			BodyOddsType: strings.TrimSpace(req.BodyOddsType),
		}},
	}
	if err := placeReq.Validate(); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	// Ownership + activity gate: the sandbox only exercises the agent's own
	// downline, and a suspended user cannot wager (the toggle widget is
	// exactly what proves the gate by flipping the flag first).
	var (
		parentID sql.NullInt64
		isActive bool
	)
	if err := h.db.QueryRowContext(r.Context(),
		`SELECT parent_id, is_active FROM users WHERE id = $1 AND role = 'USER'`, req.UserID,
	).Scan(&parentID, &isActive); err != nil {
		if isNoRows(err) {
			writeError(w, http.StatusNotFound, "downline user not found")
			return
		}
		log.Printf("agent: sandbox load user %d: %v", req.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if !parentID.Valid || parentID.Int64 != agentID.UserID {
		writeError(w, http.StatusForbidden, downlineNotYours)
		return
	}
	if !isActive {
		writeError(w, http.StatusForbidden, "user account is suspended; enable it before running a sandbox bet")
		return
	}

	resp, err := bet.NewRepository(h.db).PlaceBet(r.Context(), req.UserID, placeReq)
	if err != nil {
		switch {
		case errors.Is(err, bet.ErrInsufficientBalance):
			writeError(w, http.StatusUnprocessableEntity, err.Error())
		case errors.Is(err, bet.ErrClosedMatch):
			writeError(w, http.StatusConflict, err.Error())
		case errors.Is(err, bet.ErrInvalidRequest):
			writeError(w, http.StatusBadRequest, err.Error())
		default:
			log.Printf("agent: sandbox bet for user %d: %v", req.UserID, err)
			writeError(w, http.StatusInternalServerError, "internal server error")
		}
		return
	}

	// Post-bet reconciliation: re-read the wallet and the immutable ledger so
	// the dashboard can show hold allocation and ledger tracking in one pane.
	var (
		userCurrent float64
		userHold    float64
		ledgerRows  int
	)
	if err := h.db.QueryRowContext(r.Context(),
		`SELECT current_balance, hold_balance FROM users WHERE id = $1`, req.UserID,
	).Scan(&userCurrent, &userHold); err != nil {
		log.Printf("agent: sandbox wallet read %d: %v", req.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if err := h.db.QueryRowContext(r.Context(),
		`SELECT COUNT(*) FROM unit_ledger WHERE bet_id = $1`, resp.BetID,
	).Scan(&ledgerRows); err != nil {
		log.Printf("agent: sandbox ledger read %d: %v", resp.BetID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	balanceReconciled := math.Abs(userCurrent-resp.CurrentBalance) <= 0.005
	holdReconciled := userHold >= resp.HoldAmount-0.005
	ledgerVerified := ledgerRows >= 1

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"code":    "SANDBOX_TEST_BET_PLACED",
		"data": map[string]interface{}{
			"bet_id":               resp.BetID,
			"bet_type":             strings.ToUpper(strings.TrimSpace(req.BetType)),
			"total_stake":          placeReq.TotalStake,
			"hold_amount":          resp.HoldAmount,
			"potential_payout":     resp.PotentialPayout,
			"user_current_balance": userCurrent,
			"user_hold_balance":    userHold,
			"ledger_rows":          ledgerRows,
			"balance_reconciled":   balanceReconciled,
			"hold_reconciled":      holdReconciled,
			"ledger_verified":      ledgerVerified,
			"verified":             balanceReconciled && holdReconciled && ledgerVerified,
		},
	})
}
