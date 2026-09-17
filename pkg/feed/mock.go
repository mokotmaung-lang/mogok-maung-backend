package feed

import (
	"context"
	"fmt"
	"os"
	"time"
)

// ProviderFromEnv selects the production API-Football provider or the
// deterministic mock, driven entirely by environment variables:
//
//	SPORTS_API_MOCK=true            -> offline mock feed (staging/dev, no key needed)
//	SPORTS_API_URL                  -> provider base URL (default v3 API-Football)
//	SPORTS_API_KEY                  -> API-Football subscription key
//	SPORTS_API_LEAGUE               -> provider league id to pull (required for real feed)
//	SPORTS_API_SEASON               -> season suffix, e.g. 2026
//	SPORTS_API_STATUS               -> fixture status filter (default NS-TBD = upcoming)
func ProviderFromEnv() Provider {
	if os.Getenv("SPORTS_API_MOCK") == "true" {
		return &MockProvider{}
	}
	return NewAPIFootballProvider(
		os.Getenv("SPORTS_API_URL"),
		os.Getenv("SPORTS_API_KEY"),
		os.Getenv("SPORTS_API_LEAGUE"),
		os.Getenv("SPORTS_API_SEASON"),
		os.Getenv("SPORTS_API_STATUS"),
	)
}

// MockProvider is a deterministic, key-free feed used by offline staging and
// the admin fixture-sync smoke flow. The calendar is anchored to the current
// hour so tables always show plausible upcoming matches; team/league values
// are stable across runs so fixtures merged once stay merged on re-sync.
type MockProvider struct {
	now func() time.Time
}

// AtomicFrontier levels: the six fixtures use distinct leagues/teams so the
// control plane has variety, but every row is scheduled (maps to OPEN).
func (m *MockProvider) Fetch(ctx context.Context) ([]FeedMatch, error) {
	now := time.Now()
	if m.now != nil {
		now = m.now()
	}
	base := now.Truncate(time.Hour).Add(24 * time.Hour)

	home := []string{"Shan United", "Yangon United", "Ayeyawady United", "Kachin United", "Rakhine United", "Magwe FC"}
	away := []string{"Yadanarbon", "Thitsar Arman", "Hantharwady United", "Chinland FC", "GFA FC", "Myawady FC"}
	league := []string{"MM National League", "MM National League", "MM Cup", "MM National League", "MM Cup", "MM Second Division"}

	rows := make([]FeedMatch, 0, 6)
	for i := 0; i < 6; i++ {
		rows = append(rows, FeedMatch{
			ExternalID: fmt.Sprintf("mock-%04d", 1000+i),
			League:     league[i],
			HomeTeam:   home[i],
			AwayTeam:   away[i],
			Kickoff:    base.Add(time.Duration(i) * 3 * time.Hour),
			Status:     StatusScheduled,
		})
	}
	return rows, nil
}
