package api

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
	"mogok-maung-backend/pkg/auth"
)

// UserHandler exposes authenticated self-service endpoints for the end user.
type UserHandler struct {
	db *sql.DB
}

// NewUserHandler builds a UserHandler.
func NewUserHandler(db *sql.DB) *UserHandler {
	return &UserHandler{db: db}
}

// GetWallet returns the caller's live balances (used by the mobile dashboard
// for real-time balance binding).
func (h *UserHandler) GetWallet(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())

	var current, hold float64
	err := h.db.QueryRowContext(r.Context(),
		`SELECT current_balance, hold_balance FROM users WHERE id = $1`, p.UserID,
	).Scan(&current, &hold)
	if isNoRows(err) {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}
	if err != nil {
		log.Printf("user: load wallet %d: %v", p.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"current_balance": current,
		"hold_balance":    hold,
	})
}

type changePasswordRequest struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}

// ChangePassword rotates the caller's password and clears the
// must_change_password flag, completing the forced first-login flow.
func (h *UserHandler) ChangePassword(w http.ResponseWriter, r *http.Request) {
	var req changePasswordRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.CurrentPassword == "" || len(req.NewPassword) < 8 {
		writeError(w, http.StatusBadRequest, "current_password required and new_password must be at least 8 characters")
		return
	}

	p, _ := auth.PrincipalFrom(r.Context())

	var hash string
	err := h.db.QueryRowContext(r.Context(),
		`SELECT password_hash FROM users WHERE id = $1`, p.UserID,
	).Scan(&hash)
	if isNoRows(err) {
		writeError(w, http.StatusNotFound, "user not found")
		return
	}
	if err != nil {
		log.Printf("user: load hash %d: %v", p.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.CurrentPassword)); err != nil {
		writeError(w, http.StatusUnauthorized, "current password is incorrect")
		return
	}

	newHash, err := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		log.Printf("user: hash new password: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	if _, err := h.db.ExecContext(r.Context(), `
		UPDATE users
		   SET password_hash = $1, must_change_password = FALSE, updated_at = CURRENT_TIMESTAMP
		 WHERE id = $2`,
		string(newHash), p.UserID,
	); err != nil {
		log.Printf("user: update password %d: %v", p.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"status": "ok"})
}

// ListActiveFixtures returns every match currently accepting wagers
// (OPEN / SUSPENDED) for the mobile live feed. Clients either poll this feed or
// subscribe to the WebSocket gateway for real-time odds deltas.
func (h *UserHandler) ListActiveFixtures(w http.ResponseWriter, r *http.Request) {
	rows, err := h.db.QueryContext(r.Context(), `
		SELECT id, home_team, away_team, league_name, match_time,
		       handicap_team, body_odds_type,
		       home_body_payout, away_body_payout,
		       maung_home_multiplier, maung_away_multiplier, maung_draw_multiplier,
		       status
		  FROM matches
		 WHERE status IN ('OPEN', 'SUSPENDED')
		 ORDER BY match_time ASC`)
	if err != nil {
		log.Printf("user: list active fixtures: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	defer rows.Close()

	fixtures := make([]Fixture, 0, 16)
	for rows.Next() {
		var f Fixture
		var matchTime time.Time
		if err := rows.Scan(&f.ID, &f.HomeTeam, &f.AwayTeam, &f.LeagueName,
			&matchTime, &f.HandicapSide, &f.Handicap,
			&f.HomeBodyPayout, &f.AwayBodyPayout,
			&f.MaungHomeMultiplier, &f.MaungAwayMultiplier, &f.MaungDrawMultiplier,
			&f.Status,
		); err != nil {
			log.Printf("user: scan active fixture: %v", err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
		f.MatchTime = matchTime
		fixtures = append(fixtures, f)
	}
	if err := rows.Err(); err != nil {
		log.Printf("user: iterate active fixtures: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"fixtures": fixtures})
}

type createUnitRequestRequest struct {
	Amount      float64                `json:"amount"`
	Type        string                 `json:"type"`
	PaymentInfo map[string]interface{} `json:"payment_info"`
}

// CreateUnitsRequest opens a DEPOSIT / WITHDRAW ticket for the caller (user or
// agent). Only pending-trackable metadata is persisted; the actual movement is
// performed by the approver's settlement path.
func (h *UserHandler) CreateUnitsRequest(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())

	var req createUnitRequestRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	req.Type = strings.ToUpper(strings.TrimSpace(req.Type))
	if req.Type != "DEPOSIT" && req.Type != "WITHDRAW" {
		writeError(w, http.StatusBadRequest, "type must be DEPOSIT or WITHDRAW")
		return
	}
	if req.Amount <= 0 {
		writeError(w, http.StatusBadRequest, "amount must be greater than zero")
		return
	}

	var paymentInfo interface{}
	if len(req.PaymentInfo) > 0 {
		b, err := json.Marshal(req.PaymentInfo)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid payment_info")
			return
		}
		paymentInfo = string(b)
	}

	var id int64
	err := h.db.QueryRowContext(r.Context(), `
		INSERT INTO unit_requests (requester_id, amount, type, status, payment_info, updated_at)
		VALUES ($1, $2, $3, 'PENDING', $4, CURRENT_TIMESTAMP)
		RETURNING id`,
		p.UserID, req.Amount, req.Type, paymentInfo,
	).Scan(&id)
	if err != nil {
		log.Printf("user: create unit request by %d: %v", p.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("ယူနစ်တောင်းဆိုမှု (request #%d) PENDING အဆင့်သို့ ရောက်ရှိသွားပါပြီ။", id),
		"data": map[string]interface{}{
			"request_id": id,
			"status":     "PENDING",
		},
	})
}

// betSelectionDetail is one leg of a bet: the match, the pick and the odds
// actually used at settlement (Myanmar multiplier or Body payout profile).
type betSelectionDetail struct {
	MatchID      int64   `json:"match_id"`
	HomeTeam     string  `json:"home_team"`
	AwayTeam     string  `json:"away_team"`
	Pick         string  `json:"pick"`
	BodyOddsType string  `json:"body_odds_type"` // handicap string, e.g. "1+50"
	OddsUsed     float64 `json:"odds_used"`      // multiplier the settlement applied
	Result       string  `json:"result"`         // WIN/LOSE/DRAW/HALF_WIN/HALF_LOSE/PENDING
}

// betHistoryItem is one bet row in the user's wagering history feed,
// carrying the fields the mobile Bet History widget renders, including the
// per-selection leg details for the expansion card.
type betHistoryItem struct {
	BetID           int64                `json:"bet_id"`
	BetType         string               `json:"bet_type"`
	TotalStake      float64              `json:"total_stake"`
	HoldAmount      float64              `json:"hold_amount"`
	PotentialPayout float64              `json:"potential_payout"`
	Status          string               `json:"status"`
	SelectionsCount int                  `json:"selections_count"`
	CreatedAt       time.Time            `json:"created_at"`
	Selections      []betSelectionDetail `json:"selections"`
}

// ListUserBets returns the caller's bet history, newest first, with the
// pagination contract the mobile history screen needs:
//
//	GET /api/v1/user/bets?limit=20&offset=0
//
// Response: { "success": true, "data": { "bets": [...], "limit": N, "offset": N } }
func (h *UserHandler) ListUserBets(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())

	limit := 20
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 && n <= 100 {
			limit = n
		}
	}
	offset := 0
	if v := r.URL.Query().Get("offset"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			offset = n
		}
	}

	rows, err := h.db.QueryContext(r.Context(), `
		SELECT b.id, b.bet_type, b.total_stake, b.hold_amount,
		       COALESCE(b.potential_payout, 0),
		       b.status, b.created_at,
		       (SELECT COUNT(*) FROM bet_selections bs WHERE bs.bet_id = b.id) AS selections_count
		  FROM bets b
		 WHERE b.user_id = $1
		 ORDER BY b.created_at DESC, b.id DESC
		 LIMIT $2 OFFSET $3`,
		p.UserID, limit, offset,
	)
	if err != nil {
		log.Printf("user: list bets %d: %v", p.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	defer rows.Close()

	bets := make([]betHistoryItem, 0, limit)
	betIDs := make([]int64, 0, limit)
	for rows.Next() {
		var b betHistoryItem
		if err := rows.Scan(&b.BetID, &b.BetType, &b.TotalStake, &b.HoldAmount,
			&b.PotentialPayout, &b.Status, &b.CreatedAt, &b.SelectionsCount,
		); err != nil {
			log.Printf("user: scan bet row: %v", err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}
		bets = append(bets, b)
		betIDs = append(betIDs, b.BetID)
	}
	if err := rows.Err(); err != nil {
		log.Printf("user: iterate bets %d: %v", p.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	// Batch-load legs for this page's bets (single query, <= 100 bets).
	if err := h.loadBetSelections(r, betIDs, bets); err != nil {
		log.Printf("user: load selections %d: %v", p.UserID, err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "လောင်းကြေးမှတ်တမ်း အောင်မြင်စွာ ရရှိပါပြီ။",
		"data": map[string]interface{}{
			"bets":   bets,
			"limit":  limit,
			"offset": offset,
		},
	})
}

// loadBetSelections populates Selections on each summary row in one batched
// query, keyed by bet_id.
func (h *UserHandler) loadBetSelections(r *http.Request, betIDs []int64, bets []betHistoryItem) error {
	if len(betIDs) == 0 {
		return nil
	}

	placeholders := make([]string, len(betIDs))
	args := make([]interface{}, len(betIDs))
	for i, id := range betIDs {
		placeholders[i] = fmt.Sprintf("$%d", i+1)
		args[i] = id
	}

	rows, err := h.db.QueryContext(r.Context(), `
		SELECT bs.bet_id, bs.match_id, m.home_team, m.away_team, bs.pick,
		       bs.body_odds_type,
		       CASE b.bet_type
		           WHEN 'MAUNG' THEN
		               CASE UPPER(TRIM(bs.pick))
		                   WHEN 'HOME' THEN m.maung_home_multiplier
		                   WHEN 'AWAY' THEN m.maung_away_multiplier
		                   ELSE            m.maung_draw_multiplier
		               END
		           WHEN 'BODY' THEN
		               CASE
		                   WHEN UPPER(TRIM(bs.pick)) = 'HOME'
		                        AND m.home_body_payout > 0 THEN m.home_body_payout
		                   WHEN UPPER(TRIM(bs.pick)) = 'AWAY'
		                        AND m.away_body_payout > 0 THEN m.away_body_payout
		                   ELSE
		                       CASE UPPER(TRIM(bs.body_odds_type)) WHEN '1+50' THEN 1.5 ELSE 1.0 END
		               END
		           ELSE 1.0
		       END AS odds_used,
		       bs.status
		  FROM bet_selections bs
		  JOIN matches m ON m.id = bs.match_id
		  JOIN bets     b ON b.id = bs.bet_id
		 WHERE bs.bet_id IN (`+strings.Join(placeholders, ", ")+`)
		 ORDER BY bs.id ASC`,
		args...,
	)
	if err != nil {
		return err
	}
	defer rows.Close()

	index := make(map[int64]int, len(bets))
	for i, b := range bets {
		index[b.BetID] = i
	}

	for rows.Next() {
		var s betSelectionDetail
		var betID int64
		if err := rows.Scan(&betID, &s.MatchID, &s.HomeTeam, &s.AwayTeam,
			&s.Pick, &s.BodyOddsType, &s.OddsUsed, &s.Result,
		); err != nil {
			return err
		}
		if i, ok := index[betID]; ok {
			bets[i].Selections = append(bets[i].Selections, s)
		}
	}
	return rows.Err()
}
