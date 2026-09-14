package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/shopspring/decimal"

	"mogok-maung-backend/pkg/auth"
	"mogok-maung-backend/pkg/models"
)

// SettlementHandler exposes the weekly financial settlement rollup used by
// Super Admins (house) and Agents to reconcile a billing period.
type SettlementHandler struct {
	db *sql.DB
}

// NewSettlementHandler builds a SettlementHandler over the given pool.
func NewSettlementHandler(db *sql.DB) *SettlementHandler {
	return &SettlementHandler{db: db}
}

// settleScope narrows the weekly rollup to one agent (or the whole tree).
type settleScope struct {
	AgentID   sql.NullInt64 // NULL => aggregate across all agents
	AgentName string
}

// resolveWeeklyScope derives the agent scope from the caller. AGENTs always
// see their own downlines; ADMIN/SUPER_ADMIN may filter by agent_id or pull a
// house-wide aggregate.
func resolveWeeklyScope(db *sql.DB, r *http.Request) (settleScope, error) {
	p, _ := auth.PrincipalFrom(r.Context())

	if p.Role == models.RoleAgent {
		var name string
		err := db.QueryRowContext(r.Context(),
			`SELECT name FROM users WHERE id = $1`, p.UserID,
		).Scan(&name)
		if err != nil {
			return settleScope{}, err
		}
		return settleScope{
			AgentID:   sql.NullInt64{Int64: p.UserID, Valid: true},
			AgentName: name,
		}, nil
	}

	if v := strings.TrimSpace(r.URL.Query().Get("agent_id")); v != "" {
		id, err := strconv.ParseInt(v, 10, 64)
		if err != nil || id <= 0 {
			return settleScope{}, errors.New("invalid agent_id")
		}
		var name string
		err = db.QueryRowContext(r.Context(),
			`SELECT name FROM users WHERE id = $1 AND role = 'AGENT'`, id,
		).Scan(&name)
		if errors.Is(err, sql.ErrNoRows) {
			return settleScope{}, errors.New("agent not found")
		}
		if err != nil {
			return settleScope{}, err
		}
		return settleScope{
			AgentID:   sql.NullInt64{Int64: id, Valid: true},
			AgentName: name,
		}, nil
	}

	return settleScope{AgentName: "Agent အားလုံး (All Agents)"}, nil
}

// resolvePeriod parses start_date/end_date (2006-01-02) with a 7-day default
// window ending today. The upper bound is exclusive (end_date + 1 day) so the
// window is [start_date 00:00, end_date 23:59:59.999].
func resolvePeriod(r *http.Request) (start, end time.Time, err error) {
	layout := "2006-01-02"
	now := time.Now()
	end = now

	if v := strings.TrimSpace(r.URL.Query().Get("end_date")); v != "" {
		t, derr := time.Parse(layout, v)
		if derr != nil {
			return time.Time{}, time.Time{}, errors.New("end_date must be YYYY-MM-DD")
		}
		end = t
	}

	if v := strings.TrimSpace(r.URL.Query().Get("start_date")); v != "" {
		t, derr := time.Parse(layout, v)
		if derr != nil {
			return time.Time{}, time.Time{}, errors.New("start_date must be YYYY-MM-DD")
		}
		start = t
	} else {
		start = end.AddDate(0, 0, -6)
	}

	if start.After(end) {
		return time.Time{}, time.Time{}, errors.New("start_date must not be after end_date")
	}
	return start, end, nil
}

// WeeklySummary rolls up one billing period for an agent (or the whole house):
//
//	GET /api/v1/settlements/weekly?agent_id=2&start_date=2026-08-30&end_date=2026-09-05
//
// Figures are LIVE, derived from the settlement ledger (bets + unit_ledger), so
// they always reconcile with wallets. settlement_status is PENDING until the
// period is confirmed via POST /api/v1/admin/settlements/weekly/settle.
func (h *SettlementHandler) WeeklySummary(w http.ResponseWriter, r *http.Request) {
	scope, err := resolveWeeklyScope(h.db, r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	start, end, err := resolvePeriod(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	endInclusive := end.AddDate(0, 0, 1) // exclusive upper bound

	var count int
	var turnover, retained float64
	agentArgs := []interface{}{}
	if scope.AgentID.Valid {
		agentArgs = append(agentArgs, scope.AgentID.Int64)
	}

	rowsQuery := `
		SELECT COUNT(b.id),
		       COALESCE(SUM(b.total_stake), 0),
		       COALESCE(SUM(CASE WHEN b.status = 'REJECTED' THEN b.total_stake ELSE 0 END), 0)
		  FROM bets b
		  JOIN users u ON u.id = b.user_id
		 WHERE b.settled_at >= $1
		   AND b.settled_at < $2`
	rowsArgs := []interface{}{start, endInclusive}
	if len(agentArgs) == 1 {
		rowsQuery += " AND u.parent_id = $3"
		rowsArgs = append(rowsArgs, agentArgs[0])
	}

	if err := h.db.QueryRowContext(r.Context(), rowsQuery, rowsArgs...).
		Scan(&count, &turnover, &retained); err != nil {
		log.Printf("settlement: weekly bets rollup: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	// Winnings actually paid out: the BET_WIN ledger rows released in the
	// period (settlement could not have produced them twice).
	var payoutWin float64
	winQuery := `
		SELECT COALESCE(SUM(l.amount_change), 0)
		  FROM unit_ledger l
		  JOIN bets b ON b.id = l.bet_id
		  JOIN users u ON u.id = b.user_id
		 WHERE l.type = 'BET_WIN'
		   AND l.created_at >= $1
		   AND l.created_at <  $2`
	winArgs := []interface{}{start, endInclusive}
	if len(agentArgs) == 1 {
		winQuery += " AND u.parent_id = $3"
		winArgs = append(winArgs, agentArgs[0])
	}
	if err := h.db.QueryRowContext(r.Context(), winQuery, winArgs...).
		Scan(&payoutWin); err != nil {
		log.Printf("settlement: weekly payout rollup: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	netAmount := round2(decimal.NewFromFloat(retained).
		Sub(decimal.NewFromFloat(payoutWin)).Round(2).InexactFloat64())

	// Has this agent+period been confirmed?
	status := "NONE"
	if count > 0 {
		status = "PENDING"
	}
	if scope.AgentID.Valid {
		var wsStatus string
		statusQuery := `
			SELECT status FROM weekly_settlements
			 WHERE agent_id = $1 AND period_start = $2 AND period_end = $3
			 ORDER BY settled_at DESC LIMIT 1`
		err := h.db.QueryRowContext(r.Context(), statusQuery,
			scope.AgentID.Int64, start.Format("2006-01-02"), end.Format("2006-01-02"),
		).Scan(&wsStatus)
		if err == nil && wsStatus == "SETTLED" {
			status = "SETTLED"
		} else if err != nil && !errors.Is(err, sql.ErrNoRows) {
			log.Printf("settlement: read confirmation status: %v", err)
		}
	}

	agentID := int64(0)
	if scope.AgentID.Valid {
		agentID = scope.AgentID.Int64
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "တစ်ပတ်စာ အရှုံးအနိုင် စာရင်းချုပ်ကို အောင်မြင်စွာ ရယူပြီးပါပြီ။",
		"data": map[string]interface{}{
			"agent_id":   agentID,
			"agent_name": scope.AgentName,
			"billing_period": fmt.Sprintf("%s to %s",
				start.Format("2006-01-02"), end.Format("2006-01-02")),
			"summary": map[string]interface{}{
				"total_bets_count":      count,
				"total_turnover":        turnover,
				"total_payout_win":      payoutWin,
				"total_retained_lose":   retained,
				"net_settlement_amount": netAmount,
				"settlement_status":     status,
			},
		},
	})
}

type markSettledRequest struct {
	AgentID   int64  `json:"agent_id"`
	StartDate string `json:"start_date"`
	EndDate   string `json:"end_date"`
	Note      string `json:"note,omitempty"`
}

// MarkWeeklySettled confirms a weekly settlement for one agent+period, freezing
// the live figures into the weekly_settlements ledger (idempotent upsert):
//
//	POST /api/v1/admin/settlements/weekly/settle
func (h *SettlementHandler) MarkWeeklySettled(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())

	var req markSettledRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.AgentID <= 0 {
		writeError(w, http.StatusBadRequest, "agent_id must be a positive integer")
		return
	}
	layout := "2006-01-02"
	start, err := time.Parse(layout, req.StartDate)
	if err != nil {
		writeError(w, http.StatusBadRequest, "start_date must be YYYY-MM-DD")
		return
	}
	end, err := time.Parse(layout, req.EndDate)
	if err != nil || start.After(end) {
		writeError(w, http.StatusBadRequest, "invalid date range")
		return
	}

	// The agent must exist; otherwise the FK on weekly_settlements would raise.
	var name string
	err = h.db.QueryRowContext(r.Context(),
		`SELECT name FROM users WHERE id = $1 AND role = 'AGENT'`, req.AgentID,
	).Scan(&name)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "agent not found")
		return
	}
	if err != nil {
		log.Printf("settlement: load agent %d: %v", req.AgentID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	// Recompute the frozen figures from the live ledger.
	endInclusive := end.AddDate(0, 0, 1)

	var count int
	var turnover, retained, payoutWin float64
	err = h.db.QueryRowContext(r.Context(), `
		SELECT COUNT(b.id),
		       COALESCE(SUM(b.total_stake), 0),
		       COALESCE(SUM(CASE WHEN b.status = 'REJECTED' THEN b.total_stake ELSE 0 END), 0)
		  FROM bets b
		  JOIN users u ON u.id = b.user_id
		 WHERE u.parent_id = $1
		   AND b.settled_at >= $2
		   AND b.settled_at <  $3`,
		req.AgentID, start, endInclusive,
	).Scan(&count, &turnover, &retained)
	if err != nil {
		log.Printf("settlement: settle rollup: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	err = h.db.QueryRowContext(r.Context(), `
		SELECT COALESCE(SUM(l.amount_change), 0)
		  FROM unit_ledger l
		  JOIN bets b ON b.id = l.bet_id
		  JOIN users u ON u.id = b.user_id
		 WHERE l.type = 'BET_WIN'
		   AND u.parent_id = $1
		   AND l.created_at >= $2
		   AND l.created_at <  $3`,
		req.AgentID, start, endInclusive,
	).Scan(&payoutWin)
	if err != nil {
		log.Printf("settlement: settle payout rollup: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	netAmount := round2(decimal.NewFromFloat(retained).
		Sub(decimal.NewFromFloat(payoutWin)).Round(2).InexactFloat64())

	_, err = h.db.ExecContext(r.Context(), `
		INSERT INTO weekly_settlements
		    (agent_id, period_start, period_end, total_bets_count, total_turnover,
		     total_payout_win, total_retained_lose, net_settlement_amount,
		     status, note, settled_by)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'SETTLED', $9, $10)
		 ON CONFLICT (agent_id, period_start, period_end) DO UPDATE
		 SET total_bets_count      = EXCLUDED.total_bets_count,
		     total_turnover        = EXCLUDED.total_turnover,
		     total_payout_win      = EXCLUDED.total_payout_win,
		     total_retained_lose   = EXCLUDED.total_retained_lose,
		     net_settlement_amount = EXCLUDED.net_settlement_amount,
		     status                = 'SETTLED',
		     note                  = EXCLUDED.note,
		     settled_by            = EXCLUDED.settled_by,
		     settled_at            = CURRENT_TIMESTAMP,
		     updated_at            = CURRENT_TIMESTAMP`,
		req.AgentID, start.Format(layout), end.Format(layout),
		count, turnover, payoutWin, retained, netAmount,
		strings.TrimSpace(req.Note), p.UserID,
	)
	if err != nil {
		log.Printf("settlement: confirm agent %d period: %v", req.AgentID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": name + " အတွက် တစ်ပတ်စာ စာရင်းချုပ် (SETTLED) အောင်မြင်စွာ အတည်ပြုပြီးပါပြီ။",
		"data": map[string]interface{}{
			"agent_id":              req.AgentID,
			"agent_name":            name,
			"billing_period":        fmt.Sprintf("%s to %s", req.StartDate, req.EndDate),
			"net_settlement_amount": netAmount,
			"settlement_status":     "SETTLED",
		},
	})
}
