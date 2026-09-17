package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/lib/pq"
	"github.com/shopspring/decimal"
	"golang.org/x/crypto/bcrypt"

	"mogok-maung-backend/pkg/auth"
	"mogok-maung-backend/pkg/worker"
)

// AdminHandler exposes SUPER_ADMIN-only control-plane endpoints.
type AdminHandler struct {
	db            *sql.DB
	onOddsChange  func(ctx context.Context, matchID int64, payload interface{})
	onMatchResult func(ctx context.Context, ev worker.SettlementEvent)
}

// NewAdminHandler builds an AdminHandler. onOddsChange is an optional hook
// called after a match status/odds commit (Redis/WS fanout); pass nil if no
// fanout is wired yet — the endpoint returns redis_invalidated/ws_broadcast_sent = false.
// onMatchResult is called after a final result is committed so the result can
// be dispatched to the settlement worker queue; pass nil to skip dispatch.
func NewAdminHandler(db *sql.DB,
	onOddsChange func(ctx context.Context, matchID int64, payload interface{}),
	onMatchResult func(ctx context.Context, ev worker.SettlementEvent)) *AdminHandler {
	return &AdminHandler{db: db, onOddsChange: onOddsChange, onMatchResult: onMatchResult}
}

// adminAgent is the control-plane view of an AGENT-role user.
type adminAgent struct {
	ID               int64     `json:"id"`
	Username         string    `json:"username"`
	Name             string    `json:"name"`
	CurrentBalance   float64   `json:"current_balance"`
	HoldBalance      float64   `json:"hold_balance"`
	ActiveUsersCount int       `json:"active_users_count"`
	Status           string    `json:"status"` // ACTIVE | SUSPENDED
	CreatedAt        time.Time `json:"created_at"`
}

// ListAgents returns every AGENT-role user (with their active downline count)
// for the Super Admin's allocation / overview dashboard, oldest agent first.
func (h *AdminHandler) ListAgents(w http.ResponseWriter, r *http.Request) {
	rows, err := h.db.QueryContext(r.Context(), `
		SELECT u.id, u.username, u.name, u.current_balance, u.hold_balance,
		       (SELECT COUNT(*) FROM users d
		         WHERE d.parent_id = u.id AND d.is_active = TRUE) AS active_users_count,
		       u.is_active, u.created_at
		  FROM users u
		 WHERE u.role = 'AGENT'
		 ORDER BY u.created_at ASC`)
	if err != nil {
		log.Printf("admin: list agents: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	defer rows.Close()

	agents := make([]adminAgent, 0, 32)
	for rows.Next() {
		var a adminAgent
		var isActive bool
		if err := rows.Scan(&a.ID, &a.Username, &a.Name, &a.CurrentBalance,
			&a.HoldBalance, &a.ActiveUsersCount, &isActive, &a.CreatedAt,
		); err != nil {
			log.Printf("admin: scan agent: %v", err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
		a.Status = "SUSPENDED"
		if isActive {
			a.Status = "ACTIVE"
		}
		agents = append(agents, a)
	}
	if err := rows.Err(); err != nil {
		log.Printf("admin: iterate agents: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "Agent များ အောင်မြင်စွာ ရရှိပါပြီ။",
		"data":    map[string]interface{}{"agents": agents},
	})
}

type toggleAgentRequest struct {
	AgentID  int64 `json:"agent_id"`
	IsActive bool  `json:"is_active"`
}

// ToggleAgent suspends/activates an AGENT account (is_active), the same toggle
// the admin overview datatable exposes.
func (h *AdminHandler) ToggleAgent(w http.ResponseWriter, r *http.Request) {
	var req toggleAgentRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.AgentID <= 0 {
		writeError(w, http.StatusBadRequest, "agent_id must be a positive integer")
		return
	}

	var username string
	err := h.db.QueryRowContext(r.Context(), `
		UPDATE users
		   SET is_active = $1, updated_at = CURRENT_TIMESTAMP
		 WHERE id = $2 AND role = 'AGENT'
		 RETURNING username`,
		req.IsActive, req.AgentID,
	).Scan(&username)
	if isNoRows(err) {
		writeError(w, http.StatusNotFound, "agent not found")
		return
	}
	if err != nil {
		log.Printf("admin: toggle agent %d: %v", req.AgentID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	status := "SUSPENDED"
	message := fmt.Sprintf("အေးဂျင့် '%s' အကောင့်ကို ပိတ်ထားလိုက်ပါပြီ။", username)
	if req.IsActive {
		status = "ACTIVE"
		message = fmt.Sprintf("အေးဂျင့် '%s' အကောင့်ကို ပြန်လည်ဖွင့်လိုက်ပါပြီ။", username)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": message,
		"data": map[string]interface{}{
			"agent_id": req.AgentID,
			"status":   status,
		},
	})
}

type createAgentRequest struct {
	Username string `json:"username"`
	Name     string `json:"name"`
	Phone    string `json:"phone"`
	Password string `json:"password"`
}

// CreateAgent provisions a new AGENT-role account under the calling SUPER_ADMIN
// (the first link of the delegation chain: SUPER_ADMIN opens an Agent, the
// Agent opens Users and splits received units downline). A playwright-provided
// password is honoured; an empty one falls back to the shared bootstrap
// credential with must_change_password=TRUE forcing rotation on first login —
// the same contract agent-provisioned downline users already get.
func (h *AdminHandler) CreateAgent(w http.ResponseWriter, r *http.Request) {
	adminID, _ := auth.PrincipalFrom(r.Context())

	var req createAgentRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	if req.Username == "" {
		writeError(w, http.StatusBadRequest, "username is required")
		return
	}
	if len(req.Username) > 50 {
		writeError(w, http.StatusBadRequest, "username must be 50 characters or fewer")
		return
	}

	name := strings.TrimSpace(req.Name)
	if name == "" {
		name = req.Username
	}
	if len(name) > 100 {
		writeError(w, http.StatusBadRequest, "name must be 100 characters or fewer")
		return
	}

	phone := strings.TrimSpace(req.Phone)
	if len(phone) > 30 {
		writeError(w, http.StatusBadRequest, "phone must be 30 characters or fewer")
		return
	}

	password := req.Password
	mustChange := false
	if password == "" {
		password = DefaultDownlinePassword
		mustChange = true
	} else if len(password) < 8 {
		writeError(w, http.StatusBadRequest, "password must be at least 8 characters")
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		log.Printf("admin: hash agent password: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	var agentID int64
	err = h.db.QueryRowContext(r.Context(), `
		INSERT INTO users (username, password_hash, name, role, parent_id,
		                    current_balance, hold_balance, is_active, phone,
		                    must_change_password)
		VALUES ($1, $2, $3, 'AGENT', $4, 0.0, 0.0, TRUE, $5, $6)
		RETURNING id`,
		req.Username, string(hash), name, adminID.UserID, phone, mustChange,
	).Scan(&agentID)
	if err != nil {
		var pqErr *pq.Error
		if errors.As(err, &pqErr) && pqErr.Code == "23505" { // unique_violation
			writeError(w, http.StatusConflict, "username already exists")
			return
		}
		log.Printf("admin: create agent: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("အေးဂျင့် '%s' အကောင့်ကို အောင်မြင်စွာ ဖွင့်လိုက်ပါပြီ။", req.Username),
		"data": map[string]interface{}{
			"agent_id": agentID,
			"username": req.Username,
			"role":     "AGENT",
		},
	})
}

type allocateUnitsRequest struct {
	AgentUserID int64   `json:"agent_user_id"`
	Amount      float64 `json:"amount"`
	ActionType  string  `json:"action_type"` // DEPOSIT | WITHDRAW
	Note        string  `json:"note"`
}

// AllocateUnits is the Super Admin unit-allocation endpoint backing the web
// "Agent Unit Allocation" panel. One ACID transaction: the agent's wallet is
// locked FOR UPDATE (pessimistic row lock), adjusted, and both the approval
// trail (unit_requests) and the immutable ledger (unit_ledger) are appended —
// the same machinery Admin unit approvals already use.
func (h *AdminHandler) AllocateUnits(w http.ResponseWriter, r *http.Request) {
	adminID, _ := auth.PrincipalFrom(r.Context())

	var req allocateUnitsRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.AgentUserID <= 0 {
		writeError(w, http.StatusBadRequest, "agent_user_id must be a positive integer")
		return
	}
	if req.Amount <= 0 {
		writeError(w, http.StatusBadRequest, "amount must be greater than zero")
		return
	}
	actionType := strings.ToUpper(strings.TrimSpace(req.ActionType))
	if actionType != "DEPOSIT" && actionType != "WITHDRAW" {
		writeError(w, http.StatusBadRequest, "action_type must be DEPOSIT or WITHDRAW")
		return
	}

	tx, err := h.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	defer tx.Rollback() // no-op after Commit.

	// Pessimistic lock on the agent wallet; re-verify role inside the lock.
	var (
		agentID  int64
		username string
		name     string
		role     string
		current  float64
	)
	err = tx.QueryRowContext(r.Context(),
		`SELECT id, username, name, role, current_balance
		   FROM users WHERE id = $1 FOR UPDATE`,
		req.AgentUserID,
	).Scan(&agentID, &username, &name, &role, &current)
	if isNoRows(err) {
		writeError(w, http.StatusNotFound, "agent not found")
		return
	}
	if err != nil {
		log.Printf("admin: lock agent %d: %v", req.AgentUserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if role != "AGENT" {
		writeError(w, http.StatusBadRequest,
			fmt.Sprintf("user %d is role %s; unit allocation targets AGENT accounts only", req.AgentUserID, role))
		return
	}

	change := req.Amount
	if actionType == "WITHDRAW" {
		if current < req.Amount {
			writeError(w, http.StatusUnprocessableEntity, "agent current balance is insufficient")
			return
		}
		change = -req.Amount
	}
	newBalance := round2(decimal.NewFromFloat(current).
		Add(decimal.NewFromFloat(change)).Round(2).InexactFloat64())

	if _, err := tx.ExecContext(r.Context(),
		`UPDATE users
		    SET current_balance = $1, updated_at = CURRENT_TIMESTAMP
		  WHERE id = $2`,
		newBalance, agentID,
	); err != nil {
		log.Printf("admin: allocate update agent %d: %v", agentID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	// Approval trail row (auto-approved) so the movement shows up in the
	// same queue the Agent request flow uses.
	var requestID int64
	if err := tx.QueryRowContext(r.Context(), `
		INSERT INTO unit_requests (requester_id, approver_id, amount, type, status, updated_at)
		VALUES ($1, $2, $3, $4, 'APPROVED', CURRENT_TIMESTAMP)
		RETURNING id`,
		agentID, adminID.UserID, req.Amount, actionType,
	).Scan(&requestID); err != nil {
		log.Printf("admin: allocate request row agent %d: %v", agentID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	note := strings.TrimSpace(req.Note)
	if note == "" {
		note = fmt.Sprintf("Admin #%d managed allocation", adminID.UserID)
	}
	if _, err := tx.ExecContext(r.Context(), `
		INSERT INTO unit_ledger
		    (user_id, request_id, bet_id, type, amount_change,
		     balance_before, balance_after, description)
		 VALUES ($1, $2, NULL, $3, $4, $5, $6, $7)`,
		agentID, requestID, actionType, change, current, newBalance, note,
	); err != nil {
		log.Printf("admin: allocate ledger agent %d: %v", agentID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	if err := tx.Commit(); err != nil {
		log.Printf("admin: commit allocation agent %d: %v", agentID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	var message string
	if actionType == "DEPOSIT" {
		message = fmt.Sprintf("အေးဂျင့် '%s' ထံ ယူနစ် %.2f ထည့်သွင်းပြီးပါပြီ (request #%d)", name, req.Amount, requestID)
	} else {
		message = fmt.Sprintf("အေးဂျင့် '%s' ထံမှ ယူနစ် %.2f ပြန်နုတ်ယူပြီးပါပြီ (request #%d)", name, req.Amount, requestID)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": message,
		"data": map[string]interface{}{
			"agent_user_id":         agentID,
			"agent_current_balance": newBalance,
			"request_id":            requestID,
			"status":                "APPROVED",
		},
	})
}

type toggleFixtureRequest struct {
	FixtureID int64 `json:"fixture_id"`
	IsEnabled bool  `json:"is_enabled"`
}

// ToggleFixture switches a match's visibility between OPEN and CLOSED.
// This is the referee-equivalent "stop accepting bets" control.
func (h *AdminHandler) ToggleFixture(w http.ResponseWriter, r *http.Request) {
	var req toggleFixtureRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.FixtureID <= 0 {
		writeError(w, http.StatusBadRequest, "fixture_id must be a positive integer")
		return
	}

	status := "CLOSED"
	if req.IsEnabled {
		status = "OPEN"
	}
	res, err := h.db.ExecContext(r.Context(),
		`UPDATE matches SET status = $1 WHERE id = $2`, status, req.FixtureID)
	if err != nil {
		log.Printf("admin: toggle fixture %d: %v", req.FixtureID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeError(w, http.StatusNotFound, "fixture not found")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"fixture_id": req.FixtureID,
		"status":     status,
	})
}

// Fixture is the control-plane view of a match (matches table) consumed the
// Super Admin fixtures dashboard.
type Fixture struct {
	ID                  int64     `json:"id"`
	HomeTeam            string    `json:"home_team"`
	AwayTeam            string    `json:"away_team"`
	LeagueName          string    `json:"league_name"`
	MatchTime           time.Time `json:"match_time"`
	HandicapSide        string    `json:"handicap_side"`
	Handicap            string    `json:"handicap"` // Myanmar odds, e.g. "1+25"
	HomeBodyPayout      float64   `json:"home_body_payout"`
	AwayBodyPayout      float64   `json:"away_body_payout"`
	MaungHomeMultiplier float64   `json:"maung_home_multiplier"`
	MaungAwayMultiplier float64   `json:"maung_away_multiplier"`
	MaungDrawMultiplier float64   `json:"maung_draw_multiplier"`
	Status              string    `json:"status"` // OPEN | CLOSED | FINISHED
}

// ListFixtures returns every match for the control plane, newest first.
func (h *AdminHandler) ListFixtures(w http.ResponseWriter, r *http.Request) {
	rows, err := h.db.QueryContext(r.Context(), `
		SELECT id, home_team, away_team, league_name, match_time,
		       handicap_team, body_odds_type,
		       home_body_payout, away_body_payout,
		       maung_home_multiplier, maung_away_multiplier, maung_draw_multiplier,
		       status
		  FROM matches
		 ORDER BY match_time ASC`)
	if err != nil {
		log.Printf("admin: list fixtures: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	defer rows.Close()

	fixtures := make([]Fixture, 0, 32)
	for rows.Next() {
		var f Fixture
		var matchTime time.Time
		if err := rows.Scan(&f.ID, &f.HomeTeam, &f.AwayTeam, &f.LeagueName,
			&matchTime, &f.HandicapSide, &f.Handicap,
			&f.HomeBodyPayout, &f.AwayBodyPayout,
			&f.MaungHomeMultiplier, &f.MaungAwayMultiplier, &f.MaungDrawMultiplier,
			&f.Status,
		); err != nil {
			log.Printf("admin: scan fixture: %v", err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
		f.MatchTime = matchTime
		fixtures = append(fixtures, f)
	}
	if err := rows.Err(); err != nil {
		log.Printf("admin: iterate fixtures: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"fixtures": fixtures})
}

type updateOddsRequest struct {
	FixtureID           int64   `json:"fixture_id"`
	HandicapSide        string  `json:"handicap_side"`
	Handicap            string  `json:"handicap"` // Myanmar odds string, e.g. "1+25"
	HomeBodyPayout      float64 `json:"home_body_payout"`
	AwayBodyPayout      float64 `json:"away_body_payout"`
	MaungHomeMultiplier float64 `json:"maung_home_multiplier"`
	MaungAwayMultiplier float64 `json:"maung_away_multiplier"`
	MaungDrawMultiplier float64 `json:"maung_draw_multiplier"`
}

// UpdateFixtureOdds overwrites the Myanmar odds profile of a single match.
func (h *AdminHandler) UpdateFixtureOdds(w http.ResponseWriter, r *http.Request) {
	var req updateOddsRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.FixtureID <= 0 {
		writeError(w, http.StatusBadRequest, "fixture_id must be a positive integer")
		return
	}
	if req.Handicap == "" || req.HandicapSide == "" {
		writeError(w, http.StatusBadRequest, "handicap and handicap_side are required")
		return
	}
	if req.HandicapSide != "HOME" && req.HandicapSide != "AWAY" {
		writeError(w, http.StatusBadRequest, "handicap_side must be HOME or AWAY")
		return
	}
	if req.HomeBodyPayout < 0.5 || req.AwayBodyPayout < 0.5 ||
		req.MaungHomeMultiplier < 0.5 || req.MaungAwayMultiplier < 0.5 || req.MaungDrawMultiplier < 0.5 {
		writeError(w, http.StatusBadRequest, "all multipliers must be >= 0.50")
		return
	}

	res, err := h.db.ExecContext(r.Context(), `
		UPDATE matches
		   SET handicap_team = $1, body_odds_type = $2,
		       home_body_payout = $3, away_body_payout = $4,
		       maung_home_multiplier = $5, maung_away_multiplier = $6,
		       maung_draw_multiplier = $7, handicap = $2
		 WHERE id = $8`,
		req.HandicapSide, req.Handicap,
		req.HomeBodyPayout, req.AwayBodyPayout,
		req.MaungHomeMultiplier, req.MaungAwayMultiplier, req.MaungDrawMultiplier,
		req.FixtureID,
	)
	if err != nil {
		log.Printf("admin: update odds fixture %d: %v", req.FixtureID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeError(w, http.StatusNotFound, "fixture not found")
		return
	}

	// Push the updated odds row to the live-odds gateway (Redis fan-out),
	// so mobile/web clients re-render without an extra poll.
	if h.onOddsChange != nil {
		h.onOddsChange(r.Context(), req.FixtureID, req)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"fixture_id": req.FixtureID,
		"status":     "UPDATED",
	})
}

type approveRequest struct {
	RequestID int64 `json:"request_id"`
	Approve   bool  `json:"approve"`
}

// ApproveRequest settles a PENDING unit request (deposit/withdraw) atomically:
// wallet is updated under a row lock and an immutable ledger entry is appended.
func (h *AdminHandler) ApproveRequest(w http.ResponseWriter, r *http.Request) {
	var req approveRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.RequestID <= 0 {
		writeError(w, http.StatusBadRequest, "request_id must be a positive integer")
		return
	}

	adminID, _ := auth.PrincipalFrom(r.Context())

	tx, err := h.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	defer tx.Rollback() // no-op after Commit.

	// Lock the request row; re-check it is still PENDING.
	var (
		requesterID int64
		amount      float64
		trxType     string
		status      string
	)
	err = tx.QueryRowContext(r.Context(),
		`SELECT requester_id, amount, type, status
		   FROM unit_requests WHERE id = $1 FOR UPDATE`,
		req.RequestID,
	).Scan(&requesterID, &amount, &trxType, &status)
	if isNoRows(err) {
		writeError(w, http.StatusNotFound, "request not found")
		return
	}
	if err != nil {
		log.Printf("admin: lock request %d: %v", req.RequestID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if status != "PENDING" {
		writeError(w, http.StatusConflict, "request already processed")
		return
	}

	respStatus := "REJECTED"
	if req.Approve {
		respStatus, err = h.applyApproved(tx, r, requesterID, req.RequestID, amount, trxType, adminID.UserID)
		if err != nil {
			handleSettlementError(w, err)
			return
		}
	} else {
		if _, err := tx.ExecContext(r.Context(),
			`UPDATE unit_requests
			    SET status = 'REJECTED', approver_id = $1, updated_at = CURRENT_TIMESTAMP
			  WHERE id = $2`,
			adminID.UserID, req.RequestID,
		); err != nil {
			log.Printf("admin: reject request %d: %v", req.RequestID, err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
	}

	if err := tx.Commit(); err != nil {
		log.Printf("admin: commit approval %d: %v", req.RequestID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"request_id": req.RequestID,
		"status":     respStatus,
	})
}

// applyApproved credits/debits the requester wallet and appends the ledger row,
// all under the user's row lock. It returns the final request status.
func (h *AdminHandler) applyApproved(tx *sql.Tx, r *http.Request,
	requesterID, requestID int64, amount float64, trxType string, adminID int64) (string, error) {

	if amount <= 0 {
		return "", errors.New("amount must be greater than zero")
	}

	// Lock the requester's wallet row.
	var current, hold float64
	err := tx.QueryRowContext(r.Context(),
		`SELECT current_balance, hold_balance FROM users WHERE id = $1 FOR UPDATE`,
		requesterID,
	).Scan(&current, &hold)
	if isNoRows(err) {
		return "", errRequestNotFound
	}
	if err != nil {
		return "", err
	}

	var (
		change      float64
		newBalance  float64
		description string
	)
	switch trxType {
	case "DEPOSIT":
		change = amount
		newBalance = current + amount
		description = "Admin approved deposit"
	case "WITHDRAW":
		if current < amount {
			return "", errInsufficientBalance
		}
		change = -amount
		newBalance = current - amount
		description = "Admin approved withdrawal"
	default:
		return "", errors.New("unsupported request type: " + trxType)
	}

	if _, err := tx.ExecContext(r.Context(),
		`UPDATE users
		    SET current_balance = $1, updated_at = CURRENT_TIMESTAMP
		  WHERE id = $2`,
		newBalance, requesterID,
	); err != nil {
		return "", err
	}

	if _, err := tx.ExecContext(r.Context(),
		`UPDATE unit_requests
		    SET status = 'APPROVED', approver_id = $1, updated_at = CURRENT_TIMESTAMP
		  WHERE id = $2`,
		adminID, requestID,
	); err != nil {
		return "", err
	}

	if _, err := tx.ExecContext(r.Context(), `
		INSERT INTO unit_ledger
		    (user_id, request_id, bet_id, type, amount_change,
		     balance_before, balance_after, description)
		 VALUES ($1, $2, NULL, $3, $4, $5, $6, $7)`,
		requesterID, requestID, trxType, change, current, newBalance, description,
	); err != nil {
		return "", err
	}

	return "APPROVED", nil
}

// ---------------------------------------------------------------------------
// PATCH /api/v1/admin/matches/{match_id}/status
// ---------------------------------------------------------------------------

type matchStatusRequest struct {
	Status     string      `json:"status"`
	Reason     string      `json:"reason"`
	OddsUpdate *oddsUpdate `json:"odds_update,omitempty"`
}

type oddsUpdate struct {
	BodyOdds  *bodyOddsUpdate  `json:"body_odds,omitempty"`
	MaungOdds *maungOddsUpdate `json:"maung_odds,omitempty"`
}

type bodyOddsUpdate struct {
	HandicapTeam string  `json:"handicap_team"`
	MarketType   string  `json:"market_type"`
	HomePayout   float64 `json:"home_payout"`
	AwayPayout   float64 `json:"away_payout"`
	KFactor      float64 `json:"k_factor"`
}

type maungOddsUpdate struct {
	HomeMultiplier float64 `json:"home_multiplier"`
	AwayMultiplier float64 `json:"away_multiplier"`
	DrawMultiplier float64 `json:"draw_multiplier"`
}

var allowedStatuses = map[string]bool{
	"OPEN": true, "SUSPENDED": true, "CLOSED": true, "FINISHED": true,
}

// UpdateMatchStatus is the Admin match-control endpoint (spec §4.1).
func (h *AdminHandler) UpdateMatchStatus(w http.ResponseWriter, r *http.Request) {
	matchIDStr := r.PathValue("match_id")
	matchID, err := strconv.ParseInt(matchIDStr, 10, 64)
	if err != nil || matchID <= 0 {
		writeError(w, http.StatusBadRequest, "invalid match_id path parameter")
		return
	}

	var req matchStatusRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if !allowedStatuses[req.Status] {
		writeError(w, http.StatusBadRequest,
			fmt.Sprintf("status must be one of: OPEN, SUSPENDED, CLOSED, FINISHED; got %q", req.Status))
		return
	}

	// Build a dynamic UPDATE query. Odds columns are updated only when the
	// client sends odds_update; status is always applied.
	var (
		setClauses []string
		args       []interface{}
		argIdx     = 1
	)

	setClauses = append(setClauses, fmt.Sprintf("status = $%d", argIdx))
	args = append(args, req.Status)
	argIdx++

	if req.OddsUpdate != nil {
		b := req.OddsUpdate.BodyOdds
		if b != nil {
			if b.HandicapTeam != "HOME" && b.HandicapTeam != "AWAY" {
				writeError(w, http.StatusBadRequest, "body_odds.handicap_team must be HOME or AWAY")
				return
			}
			if b.HomePayout < 0.5 || b.AwayPayout < 0.5 {
				writeError(w, http.StatusBadRequest, "body_odds payout values must be >= 0.5")
				return
			}
			if b.KFactor <= 0 || b.KFactor > 10 {
				writeError(w, http.StatusBadRequest, "body_odds.k_factor must be between 0 and 10")
				return
			}
			setClauses = append(setClauses,
				fmt.Sprintf("handicap_team = $%d", argIdx),
			)
			args = append(args, b.HandicapTeam)
			argIdx++
			setClauses = append(setClauses, fmt.Sprintf("body_odds_type = $%d", argIdx))
			args = append(args, b.MarketType)
			argIdx++
			// handicap mirrors body_odds_type (000013): snapshot contract reads
			// it as the display label; keep both in sync so live-odds fans out.
			setClauses = append(setClauses, fmt.Sprintf("handicap = $%d", argIdx))
			args = append(args, b.MarketType)
			argIdx++
			setClauses = append(setClauses, fmt.Sprintf("home_body_payout = $%d", argIdx))
			args = append(args, b.HomePayout)
			argIdx++
			setClauses = append(setClauses, fmt.Sprintf("away_body_payout = $%d", argIdx))
			args = append(args, b.AwayPayout)
			argIdx++
			setClauses = append(setClauses, fmt.Sprintf("k_factor = $%d", argIdx))
			args = append(args, b.KFactor)
			argIdx++
		}

		m := req.OddsUpdate.MaungOdds
		if m != nil {
			if m.HomeMultiplier < 0.5 || m.AwayMultiplier < 0.5 || m.DrawMultiplier < 0.5 {
				writeError(w, http.StatusBadRequest, "maung_odds multipliers must be >= 0.5")
				return
			}
			setClauses = append(setClauses, fmt.Sprintf("maung_home_multiplier = $%d", argIdx))
			args = append(args, m.HomeMultiplier)
			argIdx++
			setClauses = append(setClauses, fmt.Sprintf("maung_away_multiplier = $%d", argIdx))
			args = append(args, m.AwayMultiplier)
			argIdx++
			setClauses = append(setClauses, fmt.Sprintf("maung_draw_multiplier = $%d", argIdx))
			args = append(args, m.DrawMultiplier)
			argIdx++
		}

		// Bump odds_version on any odds change (optimistic version guard).
		setClauses = append(setClauses, "odds_version = odds_version + 1")
	}

	query := fmt.Sprintf("UPDATE matches SET %s, updated_at = CURRENT_TIMESTAMP WHERE id = $%d",
		strings.Join(setClauses, ", "), argIdx)
	args = append(args, matchID)

	res, err := h.db.ExecContext(r.Context(), query, args...)
	if err != nil {
		log.Printf("admin: update match %d status: %v", matchID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeError(w, http.StatusNotFound, "match not found")
		return
	}

	redisInvalidated := false
	wsBroadcast := false
	if h.onOddsChange != nil {
		h.onOddsChange(r.Context(), matchID, req)
		redisInvalidated = true
		wsBroadcast = true
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"code":    "MATCH_STATUS_UPDATED",
		"message": matchStatusMessage(req.Status),
		"data": map[string]interface{}{
			"match_id":          strconv.FormatInt(matchID, 10),
			"status":            req.Status,
			"redis_invalidated": redisInvalidated,
			"ws_broadcast_sent": wsBroadcast,
			"timestamp":         time.Now().UTC().Format(time.RFC3339),
		},
	})
}

// matchStatusMessage returns the Burmese user-facing confirmation for a status change.
func matchStatusMessage(status string) string {
	switch strings.ToUpper(strings.TrimSpace(status)) {
	case "OPEN":
		return "ပွဲစဉ် လောင်းကြေးလက်ခံခြင်းကို ပြန်လည်ဖွင့်လှစ် (OPEN) လိုက်ပါပြီ။"
	case "CLOSED":
		return "ပွဲစဉ် လောင်းကြေးလက်ခံခြင်းကို ပိတ်သိမ်း (CLOSED) လိုက်ပါပြီ။"
	case "FINISHED":
		return "ပွဲစဉ် ရလဒ် (FINISHED) အဖြစ် သတ်မှတ်ပြီး စာရင်းရှင်းလင်းမှု စတင်ပါပြီ။"
	default:
		return "ပွဲစဉ် အခြေအနေ ပြောင်းလဲမှု အောင်မြင်ပါပြီ။"
	}
}

// ---------------------------------------------------------------------------
// POST /api/v1/admin/matches/{match_id}/result
// ---------------------------------------------------------------------------

var allowedTeamResults = map[string]bool{
	"WIN": true, "LOSE": true, "DRAW": true, "HALF_WIN": true, "HALF_LOSE": true,
}

// matchResultRequest is the Admin result-input payload (spec §Result Input API).
// Only a FINISHED status is accepted here: a result implies the match ended.
type matchResultRequest struct {
	HomeScore         int                     `json:"home_score"`
	AwayScore         int                     `json:"away_score"`
	MatchResultStatus string                  `json:"match_result_status"`
	TeamResults       []matchResultTeamResult `json:"team_results"`
}

type matchResultTeamResult struct {
	Team   string `json:"team"`
	Status string `json:"status"`
}

// RecordMatchResult persists the exact final score plus the traditional
// Myanmar per-team outcome in one transaction, then dispatches a
// SettlementEvent to the worker queue for PENDING bet settlement.
func (h *AdminHandler) RecordMatchResult(w http.ResponseWriter, r *http.Request) {
	matchIDStr := r.PathValue("match_id")
	matchID, err := strconv.ParseInt(matchIDStr, 10, 64)
	if err != nil || matchID <= 0 {
		writeError(w, http.StatusBadRequest, "invalid match_id path parameter")
		return
	}

	var req matchResultRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	if req.HomeScore < 0 || req.AwayScore < 0 {
		writeError(w, http.StatusBadRequest, "home_score and away_score must be non-negative")
		return
	}
	if strings.ToUpper(strings.TrimSpace(req.MatchResultStatus)) != "FINISHED" {
		writeError(w, http.StatusBadRequest, "match_result_status must be FINISHED")
		return
	}

	// team_results must contain exactly one HOME and one AWAY entry with a
	// valid outcome each; duplicates are rejected.
	perTeam := map[string]string{}
	for _, tr := range req.TeamResults {
		team := strings.ToUpper(strings.TrimSpace(tr.Team))
		status := strings.ToUpper(strings.TrimSpace(tr.Status))
		if team != "HOME" && team != "AWAY" {
			writeError(w, http.StatusBadRequest, "team must be HOME or AWAY")
			return
		}
		if !allowedTeamResults[status] {
			writeError(w, http.StatusBadRequest,
				fmt.Sprintf("invalid status %q for %s; must be one of WIN, LOSE, DRAW, HALF_WIN, HALF_LOSE", tr.Status, team))
			return
		}
		if _, dup := perTeam[team]; dup {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("duplicate team result for %s", team))
			return
		}
		perTeam[team] = status
	}
	if perTeam["HOME"] == "" || perTeam["AWAY"] == "" {
		writeError(w, http.StatusBadRequest, "team_results must include both HOME and AWAY")
		return
	}

	tx, err := h.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	defer tx.Rollback() // no-op after Commit.

	// Re-check the match exists, then persist score + FINISHED status.
	res, err := tx.ExecContext(r.Context(),
		`UPDATE matches
		    SET home_score = $1, away_score = $2, status = 'FINISHED',
		        updated_at = CURRENT_TIMESTAMP
		  WHERE id = $3`,
		req.HomeScore, req.AwayScore, matchID,
	)
	if err != nil {
		log.Printf("admin: record result match %d: %v", matchID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeError(w, http.StatusNotFound, "match not found")
		return
	}

	// Idempotent per-team result upsert (re-input of a result overwrites).
	for team, status := range perTeam {
		if _, err := tx.ExecContext(r.Context(), `
			INSERT INTO match_results (match_id, team, status)
			VALUES ($1, $2, $3)
			ON CONFLICT (match_id, team) DO UPDATE
			   SET status = EXCLUDED.status, updated_at = CURRENT_TIMESTAMP`,
			matchID, team, status,
		); err != nil {
			log.Printf("admin: persist result %s for match %d: %v", team, matchID, err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
	}

	if err := tx.Commit(); err != nil {
		log.Printf("admin: commit result match %d: %v", matchID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	ev := worker.SettlementEvent{
		MatchID:   matchID,
		HomeScore: req.HomeScore,
		AwayScore: req.AwayScore,
		TeamResults: []worker.TeamResult{
			{Team: "HOME", Status: perTeam["HOME"]},
			{Team: "AWAY", Status: perTeam["AWAY"]},
		},
	}
	if h.onMatchResult != nil {
		h.onMatchResult(r.Context(), ev)
	} else {
		log.Printf("admin: result recorded for match %d but no settlement publisher wired; worker will not be notified", matchID)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "ပွဲစဉ်ရလဒ်ကို အောင်မြင်စွာ မှတ်တမ်းတင်ပြီးပါပြီ။ မောင်းပွဲများ တွက်ချက်ရန် Worker ထံ ပေးပို့နေပါသည်။",
		"data": map[string]interface{}{
			"match_id": strconv.FormatInt(matchID, 10),
			"status":   "FINISHED",
		},
	})
}
