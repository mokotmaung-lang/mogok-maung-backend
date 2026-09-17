package feed

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestToMatchSkip(t *testing.T) {
	now := time.Date(2026, 9, 16, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name string
		f    FeedMatch
	}{
		{"empty external id", FeedMatch{HomeTeam: "A", AwayTeam: "B", Kickoff: now}},
		{"empty home team", FeedMatch{ExternalID: "1", AwayTeam: "B", Kickoff: now}},
		{"empty away team", FeedMatch{ExternalID: "1", HomeTeam: "A", Kickoff: now}},
		{"same teams", FeedMatch{ExternalID: "1", HomeTeam: "A", AwayTeam: "a", Kickoff: now}},
		{"zero kickoff", FeedMatch{ExternalID: "1", HomeTeam: "A", AwayTeam: "B"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, ok := tc.f.ToMatch(now); ok {
				t.Fatalf("expected unmergeable match to be skipped")
			}
		})
	}
}

func TestToMatchStatus(t *testing.T) {
	now := time.Date(2026, 9, 16, 12, 0, 0, 0, time.UTC)
	base := FeedMatch{ExternalID: "1", League: "MM", HomeTeam: "A", AwayTeam: "B", Kickoff: now}

	t.Run("scheduled rows open on insert", func(t *testing.T) {
		m, ok := base.ToMatch(now)
		if !ok {
			t.Fatal("expected mergeable match")
		}
		if m.status != "OPEN" {
			t.Fatalf("expected OPEN, got %q", m.status)
		}
		if m.homeBodyPayout != 0.90 || m.maungHome != 1.80 || m.maungDraw != 2.00 {
			t.Fatalf("unexpected default prices: %+v", m)
		}
	})

	t.Run("finished and canceled rows start closed", func(t *testing.T) {
		for _, s := range []FeedStatus{StatusFinished, StatusCanceled} {
			f := base
			f.Status = s
			m, ok := f.ToMatch(now)
			if !ok {
				t.Fatal("expected mergeable match")
			}
			if m.status != "CLOSED" {
				t.Fatalf("status %s: expected CLOSED insert, got %q", s, m.status)
			}
		}
	})
}

func TestMapFeedStatus(t *testing.T) {
	tests := map[string]FeedStatus{
		"NS":      StatusScheduled,
		"TBD":     StatusScheduled,
		"LIVE":    StatusLive,
		"1H":      StatusLive,
		"HT":      StatusLive,
		"FT":      StatusFinished,
		"AET":     StatusFinished,
		"PEN":     StatusFinished,
		"CANC":    StatusCanceled,
		"PST":     StatusCanceled,
		"mystery": StatusScheduled,
	}
	for in, want := range tests {
		if got, _ := mapFeedStatus(in); got != want {
			t.Errorf("mapFeedStatus(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAPIFootballFetch(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("league") != "123" || r.URL.Query().Get("status") != "NS-TBD" {
			t.Errorf("unexpected query: %s", r.URL.RawQuery)
		}
		if r.Header.Get("x-apisports-key") != "secret" {
			t.Errorf("missing provider key header")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
		  "results": 2,
		  "response": [
		    {"fixture":{"id":101,"date":"2026-09-17T19:00:00+00:00","status":{"short":"NS"}},
		     "league":{"name":"Premier League"},
		     "teams":{"home":{"name":"Arsenal"},"away":{"name":"Chelsea"}}},
		    {"fixture":{"id":102,"date":"2026-09-17T21:30:00+00:00","status":{"short":"CANC"}},
		     "league":{"name":"La Liga"},
		     "teams":{"home":{"name":"Real"},"away":{"name":"Barca"}}}
		  ]
		}`))
	}))
	defer srv.Close()

	p := NewAPIFootballProvider(srv.URL, "secret", "123", "2026", "NS-TBD")
	rows, err := p.Fetch(context.Background())
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(rows))
	}
	if rows[0].ExternalID != "101" || rows[0].Status != StatusScheduled {
		t.Fatalf("row0 unexpected: %+v", rows[0])
	}
	if rows[1].Status != StatusCanceled {
		t.Fatalf("row1 unexpected: %+v", rows[1])
	}
}

func TestAPIFootballNotConfigured(t *testing.T) {
	tests := []struct {
		name   string
		key    string
		league string
	}{
		{"missing key", "", "123"},
		{"missing league", "secret", ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p := NewAPIFootballProvider("", tc.key, tc.league, "2026", "")
			if _, err := p.Fetch(context.Background()); !errors.Is(err, ErrProviderNotConfigured) {
				t.Fatalf("expected ErrProviderNotConfigured, got %v", err)
			}
		})
	}
}

func TestSyncNoProvider(t *testing.T) {
	d := NewDriver(nil, nil, nil)
	_, err := d.Sync(context.Background())
	if !errors.Is(err, ErrProviderNotConfigured) {
		t.Fatalf("expected ErrProviderNotConfigured, got %v", err)
	}
}

func TestProviderFromEnv(t *testing.T) {
	t.Run("mock wins when requested", func(t *testing.T) {
		t.Setenv("SPORTS_API_MOCK", "true")
		p := ProviderFromEnv()
		if _, ok := p.(*MockProvider); !ok {
			t.Fatalf("expected MockProvider, got %T", p)
		}
	})

	t.Run("apifootball is the default", func(t *testing.T) {
		t.Setenv("SPORTS_API_MOCK", "false")
		t.Setenv("SPORTS_API_LEAGUE", "123")
		p := ProviderFromEnv()
		if _, ok := p.(*APIFootballProvider); !ok {
			t.Fatalf("expected APIFootballProvider, got %T", p)
		}
	})
}

func TestMockFetch(t *testing.T) {
	p := &MockProvider{}
	rows, err := p.Fetch(context.Background())
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if len(rows) != 6 {
		t.Fatalf("expected 6 fixtures, got %d", len(rows))
	}
	for _, r := range rows {
		if strings.TrimSpace(r.ExternalID) == "" || r.HomeTeam == "" || r.AwayTeam == "" {
			t.Fatalf("invalid mock row: %+v", r)
		}
		if !strings.HasPrefix(r.ExternalID, "mock-") {
			t.Fatalf("unexpected external id %q", r.ExternalID)
		}
		if r.Status != StatusScheduled {
			t.Fatalf("expected scheduled mock row, got %q", r.Status)
		}
		if _, ok := r.ToMatch(time.Now()); !ok {
			t.Fatalf("mock row not mergeable: %+v", r)
		}
	}
}
