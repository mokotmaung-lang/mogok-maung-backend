package bet

import (
	"fmt"
	"strings"
)

// OddsType represents the Myanmar traditional odds format for BODY bets.
type OddsType string

const (
	// OddsNoLoss "အရှုံးမရှိ" = 1.0x max loss on stake.
	OddsNoLoss OddsType = "NO_LOSS"
	// OddsM1_50 "၁-၅၀" = 1.5x potential loss on stake.
	OddsM1_50 OddsType = "1-50"
	// OddsP1_50 "၁+၅၀" = 1.0x max loss on stake (but affects payout).
	OddsP1_50 OddsType = "1+50"
	// OddsM2_00 "၂-၀၀" = 2.0x potential loss on stake.
	OddsM2_00 OddsType = "2-00"
)

// OddsProfile describes the risk multiplier and payout weighting for a
// Myanmar body-odds type.
type OddsProfile struct {
	// MaxLossMultiplier is applied to the stake to compute the maximum
	// potential loss that must be held from the wallet.
	MaxLossMultiplier float64
	// PayoutMultiplier adjusts the winning payout for this odds type.
	PayoutMultiplier float64
}

// BodyOddsProfile resolves a Myanmar body-odds type string into an OddsProfile.
// Returns an error for unrecognised formats so that upstream validation can
// reject malformed odds rather than silently defaulting to 1.0x.
func BodyOddsProfile(oddsType string) (OddsProfile, error) {
	key := OddsType(strings.TrimSpace(strings.ToUpper(oddsType)))
	switch key {
	case OddsNoLoss, "အရှုံးမရှိ", "0":
		return OddsProfile{MaxLossMultiplier: 1.0, PayoutMultiplier: 1.0}, nil
	case OddsM1_50, "၁-၅၀":
		return OddsProfile{MaxLossMultiplier: 1.5, PayoutMultiplier: 1.0}, nil
	case OddsP1_50, "၁+၅၀":
		return OddsProfile{MaxLossMultiplier: 1.0, PayoutMultiplier: 1.5}, nil
	case OddsM2_00, "၂-၀၀":
		return OddsProfile{MaxLossMultiplier: 2.0, PayoutMultiplier: 1.0}, nil
	default:
		return OddsProfile{}, fmt.Errorf("unsupported body odds type: %q", oddsType)
	}
}

// maungMaxLossMultiplier is always 1.0x: a MAUNG bet can lose at most the stake.
const maungMaxLossMultiplier = 1.0

// PotentialWinLeg is the per-selection odds snapshot captured at placement
// time (from the locked matches row) used to compute potential_payout.
type PotentialWinLeg struct {
	Pick         SelectionPick
	BodyOddsType string
	// Odds columns on the matches row (0 when the DB holds NULL and the admin
	// has not set a payout yet).
	HomeBodyPayout      float64
	AwayBodyPayout      float64
	MaungHomeMultiplier float64
	MaungAwayMultiplier float64
	MaungDrawMultiplier float64
}

// MaxPotentialWin computes the best-case payout for a bet:
//
//	potential_payout = total_stake x product(leg multiplier)
//
// For BODY legs the multiplier is the picked side's home/away_body_payout
// scaled by the Myanmar odds profile (e.g. "1+50" pays 1.5x), rounded up to
// at least the odds profile so a legacy row without a payout still overstates
// nothing. For MAUNG legs it is the picked market's stored multiplier
// (home/away/draw); the draw multiplier carries the -36 (0.64) convention set
// by the admin.
//
// This is the schema contract for bets.potential_payout (migration 000007):
// the column is ALWAYS populated at placement for PENDING bets, never left
// NULL, and reflects the maximum the bet can pay out if every leg wins.
func MaxPotentialWin(betType string, totalStake float64, legs []PotentialWinLeg) (float64, error) {
	if totalStake <= 0 {
		return 0, fmt.Errorf("total stake must be greater than zero")
	}
	if len(legs) == 0 {
		return 0, fmt.Errorf("at least one selection required to compute potential payout")
	}

	product := 1.0
	switch strings.ToUpper(strings.TrimSpace(betType)) {
	case "MAUNG":
		for _, leg := range legs {
			var m float64
			switch leg.Pick {
			case PickHome:
				m = leg.MaungHomeMultiplier
			case PickAway:
				m = leg.MaungAwayMultiplier
			case PickDraw:
				m = leg.MaungDrawMultiplier
			default:
				// OVER/UNDER parlay legs are not yet priced in the MAUNG
				// engine; treat them as even-money to stay conservative.
				m = 1.0
			}
			if m <= 0 {
				m = 1.0
			}
			product *= m
		}

	case "BODY":
		for _, leg := range legs {
			profile, err := BodyOddsProfile(leg.BodyOddsType)
			if err != nil {
				return 0, err
			}
			m := 1.0
			switch leg.Pick {
			case PickHome:
				m = leg.HomeBodyPayout
			case PickAway:
				m = leg.AwayBodyPayout
			default:
				// Non Home/Away picks are not priced in the BODY market.
				m = profile.PayoutMultiplier
			}
			// A stored payout of 0 means the column was never provisioned;
			// fall back to the odds profile payout, and never price a leg
			// below its settled minimum (1.0x).
			effective := m
			if effective <= 0 {
				effective = profile.PayoutMultiplier
			}
			if effective < 1.0 {
				effective = 1.0
			}
			product *= effective
		}

	default:
		return 0, fmt.Errorf("unsupported bet type: %q", betType)
	}

	return totalStake * product, nil
}

// MaxPotentialLoss computes the worst-case loss a user can incur for a bet.
// It multiplies the total stake by the per-selection loss profile. For MAUNG
// bets the loss is capped at the total stake (1.0x). For BODY bets it resolves
// each selection's Myanmar odds type and takes the maximum across selections.
func MaxPotentialLoss(betType string, totalStake float64, bodyOddsTypes []string) (float64, error) {
	if totalStake <= 0 {
		return 0, fmt.Errorf("total stake must be greater than zero")
	}

	switch strings.ToUpper(strings.TrimSpace(betType)) {
	case "MAUNG":
		return totalStake * maungMaxLossMultiplier, nil
	case "BODY":
		if len(bodyOddsTypes) == 0 {
			return 0, fmt.Errorf("body bet requires at least one selection")
		}
		worst := 0.0
		for _, ot := range bodyOddsTypes {
			profile, err := BodyOddsProfile(ot)
			if err != nil {
				return 0, err
			}
			if profile.MaxLossMultiplier > worst {
				worst = profile.MaxLossMultiplier
			}
		}
		return totalStake * worst, nil
	default:
		return 0, fmt.Errorf("unsupported bet type: %q", betType)
	}
}
