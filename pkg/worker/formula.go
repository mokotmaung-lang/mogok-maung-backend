package worker

import (
	"fmt"
	"strings"

	"github.com/shopspring/decimal"
)

// Outcome is the traditional Myanmar settlement status of a single selection.
type Outcome string

const (
	OutcomeWin      Outcome = "WIN"
	OutcomeLose     Outcome = "LOSE"
	OutcomeDraw     Outcome = "DRAW"
	OutcomeHalfWin  Outcome = "HALF_WIN"
	OutcomeHalfLose Outcome = "HALF_LOSE"
)

// ParseOutcome normalises a raw status string into an Outcome.
func ParseOutcome(raw string) (Outcome, error) {
	o := Outcome(strings.ToUpper(strings.TrimSpace(raw)))
	switch o {
	case OutcomeWin, OutcomeLose, OutcomeDraw, OutcomeHalfWin, OutcomeHalfLose:
		return o, nil
	default:
		return "", fmt.Errorf("unsupported settlement outcome %q", raw)
	}
}

// SelectionMultiplier implements the traditional Myanmar multiplier rules.
// All odds arithmetic runs through fixed-point decimal so a HALF_WIN derived
// from a 3-way odds fraction (e.g. 1.33 → 1 + 0.165) never picks up float64
// bias:
//
//	WIN        (အပြည့်နိုင်)         -> odds
//	HALF_WIN   (တစ်ဝက်နိုင်/စား)    -> 1 + ((odds - 1) / 2)
//	DRAW       (သရေ/ပယ်)           -> 1.0 (omitted from parlay impact)
//	HALF_LOSE  (တစ်ဝက်ရှုံး/သေ)     -> 0.5 (accrued ticket cut in half)
//	LOSE       (အပြည့်ရှုံး/မောင်းပြတ်) -> 0.0 (ticket broken)
func SelectionMultiplier(status Outcome, oddsMultiplier float64) (float64, error) {
	if status == OutcomeDraw {
		return 1.0, nil
	}
	if oddsMultiplier < 0 {
		return 0, fmt.Errorf("odds multiplier must be non-negative, got %v", oddsMultiplier)
	}
	switch status {
	case OutcomeWin:
		return oddsMultiplier, nil
	case OutcomeHalfWin:
		mult := decimal.NewFromInt(1).
			Add(decimal.NewFromFloat(oddsMultiplier).
				Sub(decimal.NewFromInt(1)).
				Div(decimal.NewFromInt(2)))
		return mult.InexactFloat64(), nil
	case OutcomeHalfLose:
		return 0.5, nil
	case OutcomeLose:
		return 0.0, nil
	default:
		return 0, fmt.Errorf("unsupported outcome %q", status)
	}
}

// TicketMultiplier combines per-selection multipliers parlay-style
// (final = m1 * m2 * ... * mn). Any full loss collapses the ticket to 0.
// Multiplied in decimal to keep the accumulator exact across many legs.
func TicketMultiplier(multipliers []float64) float64 {
	total := decimal.NewFromInt(1)
	for _, m := range multipliers {
		total = total.Mul(decimal.NewFromFloat(m))
	}
	return total.InexactFloat64()
}

// round2 rounds a monetary value to two decimal places (decimal rounding:
// half away from zero, identical semantics to the previous math.Round path).
func round2(v float64) float64 {
	return decimal.NewFromFloat(v).Round(2).InexactFloat64()
}
