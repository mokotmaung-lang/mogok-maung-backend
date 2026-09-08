package models

import (
	"database/sql"
	"database/sql/driver"
	"fmt"
	"time"
)

// ======================= ENUM TYPES =======================

// UserRole represents the hierarchical role of a user.
type UserRole string

const (
	RoleSuperAdmin UserRole = "SUPER_ADMIN"
	RoleAdmin      UserRole = "ADMIN"
	RoleAgent      UserRole = "AGENT"
	RoleUser       UserRole = "USER"
)

// Valid checks if a UserRole is one of the defined values.
func (r UserRole) Valid() bool {
	switch r {
	case RoleSuperAdmin, RoleAdmin, RoleAgent, RoleUser:
		return true
	default:
		return false
	}
}

// TrxType represents the type of a unit transaction.
type TrxType string

const (
	TrxDeposit   TrxType = "DEPOSIT"
	TrxWithdraw  TrxType = "WITHDRAW"
	TrxBetHold   TrxType = "BET_HOLD"
	TrxBetWin    TrxType = "BET_WIN"
	TrxBetLose   TrxType = "BET_LOSE"
	TrxBetRefund TrxType = "BET_REFUND"
)

// RequestStatus represents the lifecycle of a unit request.
type RequestStatus string

const (
	ReqPending  RequestStatus = "PENDING"
	ReqApproved RequestStatus = "APPROVED"
	ReqRejected RequestStatus = "REJECTED"
)

// MatchStatus represents the lifecycle of a match.
type MatchStatus string

const (
	MatchOpen     MatchStatus = "OPEN"
	MatchClosed   MatchStatus = "CLOSED"
	MatchFinished MatchStatus = "FINISHED"
)

// BetType represents the betting market type.
type BetType string

const (
	BetBody  BetType = "BODY"
	BetMaung BetType = "MAUNG"
)

// ======================= MODELS =======================

// User represents a hierarchical user in the system.
// parent_id creates the Admin -> Agent -> User tree.
type User struct {
	ID                 int64          `json:"id" db:"id"`
	Username           string         `json:"username" db:"username"`
	PasswordHash       string         `json:"-" db:"password_hash"`
	Name               string         `json:"name" db:"name"`
	Phone              sql.NullString `json:"phone,omitempty" db:"phone"` // migration 000004 (UNIQUE)
	Role               UserRole       `json:"role" db:"role"`
	ParentID           int64          `json:"parent_id,omitempty" db:"parent_id"`
	CurrentBalance     float64        `json:"current_balance" db:"current_balance"`
	HoldBalance        float64        `json:"hold_balance" db:"hold_balance"`
	IsActive           bool           `json:"is_active" db:"is_active"`
	MustChangePassword bool           `json:"must_change_password" db:"must_change_password"`
	CreatedAt          time.Time      `json:"created_at" db:"created_at"`
	UpdatedAt          time.Time      `json:"updated_at" db:"updated_at"`
}

// Match represents a football fixture with Myanmar handicap odds.
type Match struct {
	ID             int64       `json:"id" db:"id"`
	HomeTeam       string      `json:"home_team" db:"home_team"`
	AwayTeam       string      `json:"away_team" db:"away_team"`
	MatchTime      time.Time   `json:"match_time" db:"match_time"`
	HandicapTeam   string      `json:"handicap_team" db:"handicap_team"`
	BodyOddsType   string      `json:"body_odds_type" db:"body_odds_type"`
	HomeBodyPayout float64     `json:"home_body_payout" db:"home_body_payout"`
	AwayBodyPayout float64     `json:"away_body_payout" db:"away_body_payout"`
	MaungHomeMulti float64     `json:"maung_home_multiplier" db:"maung_home_multiplier"`
	MaungAwayMulti float64     `json:"maung_away_multiplier" db:"maung_away_multiplier"`
	MaungDrawMulti float64     `json:"maung_draw_multiplier" db:"maung_draw_multiplier"`
	Status         MatchStatus `json:"status" db:"status"`
	LeagueName     string      `json:"league_name,omitempty" db:"league_name"`   // migration 000006
	OddsVersion    int64       `json:"odds_version,omitempty" db:"odds_version"` // migration 000007
	KFactor        float64     `json:"k_factor,omitempty" db:"k_factor"`         // migration 000007
	HomeScore      *int64      `json:"home_score,omitempty" db:"home_score"`     // migration 000009 (NULL until FINISHED)
	AwayScore      *int64      `json:"away_score,omitempty" db:"away_score"`     // migration 000009
	CreatedAt      time.Time   `json:"created_at" db:"created_at"`
}

// UnitRequest represents a point/unit flow request along the
// user -> approver (agent/admin) chain.
type UnitRequest struct {
	ID          int64          `json:"id" db:"id"`
	RequesterID int64          `json:"requester_id" db:"requester_id"`
	ApproverID  int64          `json:"approver_id,omitempty" db:"approver_id"`
	Amount      float64        `json:"amount" db:"amount"`
	Type        TrxType        `json:"type" db:"type"`
	Status      RequestStatus  `json:"status" db:"status"`
	PaymentInfo sql.NullString `json:"payment_info,omitempty" db:"payment_info"`
	CreatedAt   time.Time      `json:"created_at" db:"created_at"`
	UpdatedAt   time.Time      `json:"updated_at" db:"updated_at"`
}

// UnitLedger represents an immutable double-entry audit trail entry.
type UnitLedger struct {
	ID            int64     `json:"id" db:"id"`
	UserID        int64     `json:"user_id" db:"user_id"`
	RequestID     int64     `json:"request_id,omitempty" db:"request_id"`
	BetID         int64     `json:"bet_id,omitempty" db:"bet_id"`
	RefUserID     *int64    `json:"ref_user_id,omitempty" db:"ref_user_id"` // counterparty (migration 000007)
	Type          TrxType   `json:"type" db:"type"`
	AmountChange  float64   `json:"amount_change" db:"amount_change"`
	BalanceBefore float64   `json:"balance_before" db:"balance_before"`
	BalanceAfter  float64   `json:"balance_after" db:"balance_after"`
	Description   string    `json:"description,omitempty" db:"description"`
	CreatedAt     time.Time `json:"created_at" db:"created_at"`
}

// ======================= NULLABLE ENUM SUPPORT =======================

// Scan implements sql.Scanner for nullable enum columns.
func (r *UserRole) Scan(value interface{}) error {
	if value == nil {
		*r = ""
		return nil
	}
	switch v := value.(type) {
	case string:
		*r = UserRole(v)
	case []byte:
		*r = UserRole(string(v))
	default:
		return fmt.Errorf("cannot scan type %T into UserRole", value)
	}
	return nil
}

// Value implements driver.Valuer for UserRole.
func (r UserRole) Value() (driver.Value, error) {
	return string(r), nil
}
