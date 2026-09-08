package bet

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// BetType mirrors the database bet_type enum.
type BetType string

const (
	BetBody  BetType = "BODY"
	BetMaung BetType = "MAUNG"
)

// SelectionPick is the markets a user may pick on a selection.
type SelectionPick string

const (
	PickHome  SelectionPick = "HOME"
	PickAway  SelectionPick = "AWAY"
	PickDraw  SelectionPick = "DRAW"
	PickOver  SelectionPick = "OVER"
	PickUnder SelectionPick = "UNDER"
)

// PlaceBetRequest is the payload accepted by POST /api/v1/user/bets.
type PlaceBetRequest struct {
	BetType    BetType     `json:"bet_type"`
	TotalStake float64     `json:"total_stake"`
	Selections []Selection `json:"selections"`
}

// Validate performs cheap structural validation of the request payload.
func (req *PlaceBetRequest) Validate() error {
	if req.TotalStake <= 0 {
		return errors.New("total_stake must be greater than zero")
	}
	if len(req.Selections) == 0 {
		return errors.New("selections must not be empty")
	}
	switch req.BetType {
	case BetBody, BetMaung:
	default:
		return fmt.Errorf("unsupported bet_type %q", req.BetType)
	}
	for _, sel := range req.Selections {
		if sel.MatchID <= 0 {
			return errors.New("selection match_id must be positive")
		}
		switch sel.Pick {
		case PickHome, PickAway, PickDraw, PickOver, PickUnder:
		default:
			return fmt.Errorf("unsupported pick %q", sel.Pick)
		}
		if req.BetType == BetBody && strings.TrimSpace(sel.BodyOddsType) == "" {
			return errors.New("BODY selections require body_odds_type")
		}
	}
	return nil
}

// Selection is a single fixture pick within a bet.
type Selection struct {
	MatchID      int64         `json:"match_id"`
	Pick         SelectionPick `json:"pick"`
	BodyOddsType string        `json:"body_odds_type,omitempty"` // Myanmar body odds for BODY bets
}

// PlaceBetResponse is returned after a successful atomic hold.
type PlaceBetResponse struct {
	BetID           int64   `json:"bet_id"`
	HoldAmount      float64 `json:"hold_amount"`
	PotentialPayout float64 `json:"potential_payout"`
	CurrentBalance  float64 `json:"current_balance"`
}

// Bet is the persisted bet record.
type Bet struct {
	ID              int64      `json:"id" db:"id"`
	UserID          int64      `json:"user_id" db:"user_id"`
	BetType         BetType    `json:"bet_type" db:"bet_type"`
	TotalStake      float64    `json:"total_stake" db:"total_stake"`
	HoldAmount      float64    `json:"hold_amount" db:"hold_amount"`
	PotentialPayout float64    `json:"potential_payout,omitempty" db:"potential_payout"` // migration 000007
	Status          BetStatus  `json:"status" db:"status"`
	CreatedAt       time.Time  `json:"created_at" db:"created_at"`
	SettledAt       *time.Time `json:"settled_at,omitempty" db:"settled_at"` // migration 000010
}

// BetSelection is a single persisted selection row.
type BetSelection struct {
	ID           int64         `json:"id" db:"id"`
	BetID        int64         `json:"bet_id" db:"bet_id"`
	MatchID      int64         `json:"match_id" db:"match_id"`
	Pick         SelectionPick `json:"pick" db:"pick"`
	BodyOddsType string        `json:"body_odds_type" db:"body_odds_type"`
	Status       BetStatus     `json:"status" db:"status"` // migration 000003 (PENDING/APPROVED/REJECTED)
	CreatedAt    time.Time     `json:"created_at" db:"created_at"`
}

// BetStatus mirrors the bet lifecycle statuses in bets + bet_selections.
type BetStatus string

const (
	BetPending  BetStatus = "PENDING"
	BetApproved BetStatus = "APPROVED"
	BetRejected BetStatus = "REJECTED"
)
