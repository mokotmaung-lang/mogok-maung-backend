// Package settlement implements the traditional Myanmar "goal line" handicap
// settlement used by the Mogok Maung engine. The authoritative rule set:
//
//	"1+25" -> favourite must win by 2 goals for a full win; win by exactly 1
//	          goal pays 25% profit (1.25x) = HALF_WIN; otherwise lose.
//	"-36"  -> favourite wins outright (any margin) for a full win; a draw
//	          returns 64% of stake (loses 36%) = HALF_LOSE; otherwise lose.
//	"0-50" -> zero goal line; a draw returns 50% of stake = HALF_LOSE.
//
// The same rule set is mirrored in TypeScript for the web control plane
// (web/lib/myanmar-settlement.ts).
package settlement

import (
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/shopspring/decimal"
)

// Outcome matches the settlement statuses produced by the worker engine.
type Outcome string

const (
	OutcomeWin      Outcome = "WIN"
	OutcomeHalfWin  Outcome = "HALF_WIN"
	OutcomeHalfLose Outcome = "HALF_LOSE"
	OutcomeLose     Outcome = "LOSE"
	OutcomePending  Outcome = "PENDING"
)

// WinMultiplier is the full-win moneyline payout reference (2.0).
const WinMultiplier = 2.0

// Request describes one body/goal-line bet to settle.
type Request struct {
	Stake       float64 // wagered units
	Handicap    string  // e.g. "1+25", "-36", "0-50"
	IsFavourite bool    // bet is placed on the handicap side
	ScoreHome   int
	ScoreAway   int
}

// Result is the settled payout of a single request.
type Result struct {
	Payout     float64
	Multiplier float64
	Status     Outcome
}

type parsedHandicap struct {
	base      int
	fraction  int
	connector byte // '+' or '-'
}

// parseHandicap decodes the "X+Y", "-Z", "0-50" notation. The integer base
// is optional and defaults to 0 (as in "-36", "0-50").
func parseHandicap(raw string) (parsedHandicap, error) {
	s := strings.TrimSpace(raw)
	i := strings.IndexAny(s, "+-")
	if i < 0 {
		return parsedHandicap{}, fmt.Errorf("invalid handicap %q: missing +/- connector", raw)
	}
	connector := s[i]

	base := 0
	if i > 0 {
		b, err := strconv.Atoi(s[:i])
		if err != nil {
			return parsedHandicap{}, fmt.Errorf("invalid handicap %q: bad base", raw)
		}
		base = b
	}

	fraction, err := strconv.Atoi(s[i+1:])
	if err != nil {
		return parsedHandicap{}, fmt.Errorf("invalid handicap %q: bad fraction", raw)
	}

	return parsedHandicap{base: base, fraction: fraction, connector: connector}, nil
}

// CalculateBodyResult settles one body bet against the final score following
// the Myanmar goal-line conventions above.
func CalculateBodyResult(req Request) Result {
	if req.Stake < 0 {
		return Result{Status: OutcomePending}
	}

	parsed, err := parseHandicap(req.Handicap)
	if err != nil {
		return Result{Status: OutcomePending}
	}

	// Goal difference from the favourite's point of view.
	goalDiff := req.ScoreHome - req.ScoreAway
	if !req.IsFavourite {
		goalDiff = -goalDiff
	}

	result := func(payout, multiplier float64, status Outcome) Result {
		return Result{
			Payout:     payout,
			Multiplier: multiplier,
			Status:     status,
		}
	}
	win := func() Result {
		return result(payout2(req.Stake, WinMultiplier), WinMultiplier, OutcomeWin)
	}
	lose := func() Result {
		return result(0, 0, OutcomeLose)
	}

	fullWinMargin := parsed.base + 1

	if parsed.connector == '+' {
		// "+" family: a narrow (base-goal) win is rewarded fractionally.
		if goalDiff >= fullWinMargin {
			return win()
		}
		if goalDiff == parsed.base {
			mult := decimal.NewFromInt(1).Add(decimal.NewFromInt(int64(parsed.fraction)).Div(decimal.NewFromInt(100)))
			return result(payout2(req.Stake, mult.InexactFloat64()), mult.InexactFloat64(), OutcomeHalfWin)
		}
		return lose()
	}

	// "-" family: any goal win clears fully; the base level is a half loss.
	if goalDiff >= fullWinMargin {
		return win()
	}
	if goalDiff == parsed.base {
		mult := decimal.NewFromInt(1).Sub(decimal.NewFromInt(int64(parsed.fraction)).Div(decimal.NewFromInt(100)))
		if mult.IsNegative() {
			mult = decimal.Zero
		}
		return result(payout2(req.Stake, mult.InexactFloat64()), mult.InexactFloat64(), OutcomeHalfLose)
	}
	return lose()
}

// payout2 computes stake×multiplier with fixed-point decimal arithmetic and
// rounds the monetary result to two decimal places, avoiding float64 drift.
func payout2(stake, multiplier float64) float64 {
	return decimal.NewFromFloat(stake).
		Mul(decimal.NewFromFloat(multiplier)).
		Round(2).
		InexactFloat64()
}

// round2 rounds a monetary value to two decimal places (float64 convenience
// mirror used by myanmar_test.go to derive its expected payouts).
func round2(v float64) float64 {
	return math.Round(v*100) / 100
}
