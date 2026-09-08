package settlement

import "testing"

func TestCalculateBodyResult_1Plus25(t *testing.T) {
	cases := []struct {
		name       string
		home, away int
		want       Outcome
		wantMult   float64
	}{
		{"favourite wins by 2 (full)", 2, 0, OutcomeWin, 2.0},
		{"favourite wins by 3 (full)", 3, 0, OutcomeWin, 2.0},
		{"favourite wins by 1 (half win)", 1, 0, OutcomeHalfWin, 1.25},
		{"draw", 0, 0, OutcomeLose, 0},
		{"favourite loses", 0, 2, OutcomeLose, 0},
	}

	stake := 1000.0
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := CalculateBodyResult(Request{
				Stake:       stake,
				Handicap:    "1+25",
				IsFavourite: true,
				ScoreHome:   tc.home,
				ScoreAway:   tc.away,
			})
			if got.Status != tc.want {
				t.Fatalf("status = %s, want %s", got.Status, tc.want)
			}
			if got.Multiplier != tc.wantMult {
				t.Fatalf("multiplier = %v, want %v", got.Multiplier, tc.wantMult)
			}
			if wantPayout := round2(stake * tc.wantMult); got.Payout != wantPayout {
				t.Fatalf("payout = %v, want %v", got.Payout, wantPayout)
			}
		})
	}
}

func TestCalculateBodyResult_Minus36(t *testing.T) {
	cases := []struct {
		name       string
		home, away int
		want       Outcome
		wantMult   float64
	}{
		{"favourite wins by 1 (full)", 1, 0, OutcomeWin, 2.0},
		{"favourite wins by 2 (full)", 2, 0, OutcomeWin, 2.0},
		{"draw (returns 64%)", 0, 0, OutcomeHalfLose, 0.64},
		{"favourite loses", 0, 1, OutcomeLose, 0},
	}

	stake := 100.0
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := CalculateBodyResult(Request{
				Stake:       stake,
				Handicap:    "-36",
				IsFavourite: true,
				ScoreHome:   tc.home,
				ScoreAway:   tc.away,
			})
			if got.Status != tc.want {
				t.Fatalf("status = %s, want %s", got.Status, tc.want)
			}
			if got.Multiplier != tc.wantMult {
				t.Fatalf("multiplier = %v, want %v", got.Multiplier, tc.wantMult)
			}
			if wantPayout := round2(stake * tc.wantMult); got.Payout != wantPayout {
				t.Fatalf("payout = %v, want %v", got.Payout, wantPayout)
			}
		})
	}
}

func TestCalculateBodyResult_0Minus50(t *testing.T) {
	cases := []struct {
		name       string
		home, away int
		want       Outcome
		wantMult   float64
	}{
		{"favourite wins (full)", 2, 1, OutcomeWin, 2.0},
		{"draw (returns 50%)", 1, 1, OutcomeHalfLose, 0.50},
		{"favourite loses", 0, 3, OutcomeLose, 0},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := CalculateBodyResult(Request{
				Stake:       200,
				Handicap:    "0-50",
				IsFavourite: true,
				ScoreHome:   tc.home,
				ScoreAway:   tc.away,
			})
			if got.Status != tc.want {
				t.Fatalf("status = %s, want %s", got.Status, tc.want)
			}
			if got.Multiplier != tc.wantMult {
				t.Fatalf("multiplier = %v, want %v", got.Multiplier, tc.wantMult)
			}
		})
	}
}

func TestCalculateBodyResult_AwaySide(t *testing.T) {
	// Betting against the favourite: goal difference is measured from the
	// away side's point of view.
	got := CalculateBodyResult(Request{
		Stake:       100,
		Handicap:    "-36",
		IsFavourite: false,
		ScoreHome:   0,
		ScoreAway:   1,
	})
	if got.Status != OutcomeWin || got.Multiplier != 2.0 {
		t.Fatalf("away favourite should win fully, got status=%s mult=%v", got.Status, got.Multiplier)
	}

	lost := CalculateBodyResult(Request{
		Stake:       100,
		Handicap:    "-36",
		IsFavourite: false,
		ScoreHome:   2,
		ScoreAway:   1,
	})
	if lost.Status != OutcomeLose {
		t.Fatalf("away side should lose when behind, got %s", lost.Status)
	}
}

func TestCalculateBodyResult_Invalid(t *testing.T) {
	got := CalculateBodyResult(Request{
		Stake:       100,
		Handicap:    "not-a-handicap",
		IsFavourite: true,
		ScoreHome:   1,
		ScoreAway:   0,
	})
	if got.Status != OutcomePending {
		t.Fatalf("invalid handicap should settle as PENDING, got %s", got.Status)
	}

	neg := CalculateBodyResult(Request{Stake: -5, Handicap: "-36", IsFavourite: true})
	if neg.Status != OutcomePending {
		t.Fatalf("negative stake should settle as PENDING, got %s", neg.Status)
	}
}

func TestParseHandicap(t *testing.T) {
	cases := []struct {
		raw  string
		base int
		frac int
		conn byte
		ok   bool
	}{
		{"1+25", 1, 25, '+', true},
		{"-36", 0, 36, '-', true},
		{"0-50", 0, 50, '-', true},
		{"+25", 0, 25, '+', true},
		{"2-00", 2, 0, '-', true},
		{"abc", 0, 0, 0, false},
		{"1", 0, 0, 0, false},
	}
	for _, tc := range cases {
		got, err := parseHandicap(tc.raw)
		if tc.ok != (err == nil) {
			t.Fatalf("parseHandicap(%q) err = %v, want ok=%v", tc.raw, err, tc.ok)
		}
		if err == nil {
			if got.base != tc.base || got.fraction != tc.frac || got.connector != tc.conn {
				t.Fatalf("parseHandicap(%q) = %+v", tc.raw, got)
			}
		}
	}
}
