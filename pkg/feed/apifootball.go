package feed

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// APIFootballProvider fetches fixtures from the API-Football v3 REST feed
// (https://www.api-football.com). Credentials and the target league come from
// the environment; the mock provider is preferred when SPORTS_API_MOCK is set.
type APIFootballProvider struct {
	baseURL string
	apiKey  string
	league  string
	season  string
	status  string
	client  *http.Client
}

// NewAPIFootballProvider builds an API-Football provider. An empty apiKey or
// league leaves the provider inert: Fetch returns ErrProviderNotConfigured so
// callers degrade cleanly instead of hammering an unauthenticated endpoint.
func NewAPIFootballProvider(baseURL, apiKey, league, season, status string) *APIFootballProvider {
	if baseURL == "" {
		baseURL = "https://v3.football.api-sports.io"
	}
	if status == "" {
		status = "NS-TBD"
	}
	return &APIFootballProvider{
		baseURL: strings.TrimRight(baseURL, "/"),
		apiKey:  apiKey,
		league:  league,
		season:  season,
		status:  status,
		client: &http.Client{
			Timeout: 30 * time.Second,
			Transport: &http.Transport{
				DialContext: (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
			},
		},
	}
}

// apiFixture mirrors the slice of the API-Football response we consume. Only
// the fields the matches merge needs are decoded.
type apiFixture struct {
	Fixture struct {
		ID     int64  `json:"id"`
		Date   string `json:"date"`
		Status struct {
			Short string `json:"short"`
		} `json:"status"`
	} `json:"fixture"`
	League struct {
		Name string `json:"name"`
	} `json:"league"`
	Teams struct {
		Home struct {
			Name string `json:"name"`
		} `json:"home"`
		Away struct {
			Name string `json:"name"`
		} `json:"away"`
	} `json:"teams"`
}

type apiFixturesEnvelope struct {
	Results  int           `json:"results"`
	Response []apiFixture  `json:"response"`
	Errors   []interface{} `json:"errors"`
}

// Fetch queries the last N upcoming fixtures for the configured league/season
// and normalises them into FeedMatch rows.
func (p *APIFootballProvider) Fetch(ctx context.Context) ([]FeedMatch, error) {
	if p.apiKey == "" {
		return nil, ErrProviderNotConfigured
	}
	if p.league == "" {
		return nil, fmt.Errorf("%w: SPORTS_API_LEAGUE required", ErrProviderNotConfigured)
	}

	endpoint := p.baseURL + "/fixtures?league=" + p.league + "&season=" + p.season +
		"&status=" + urlQueryEscape(p.status)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("x-apisports-key", p.apiKey)
	req.Header.Set("Accept", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request fixtures: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		if resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode == http.StatusUnauthorized {
			return nil, fmt.Errorf("fixture provider rejected request (HTTP %d): %w", resp.StatusCode, ErrProviderNotConfigured)
		}
		return nil, fmt.Errorf("fixture provider returned HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, fmt.Errorf("read fixtures body: %w", err)
	}

	var envelope apiFixturesEnvelope
	if err := json.Unmarshal(body, &envelope); err != nil {
		return nil, fmt.Errorf("decode fixtures body: %w", err)
	}

	out := make([]FeedMatch, 0, envelope.Results)
	for _, f := range envelope.Response {
		if f.Fixture.ID <= 0 {
			continue
		}
		kickoff, err := time.Parse(time.RFC3339, f.Fixture.Date)
		if err != nil {
			// Provider may return a non-RFC3339 wrapper; try the nearest fit.
			kickoff, err = time.Parse("2006-01-02T15:04:05Z07:00", f.Fixture.Date)
			if err != nil {
				continue
			}
		}
		status, _ := mapFeedStatus(f.Fixture.Status.Short)
		out = append(out, FeedMatch{
			ExternalID: strconv.FormatInt(f.Fixture.ID, 10),
			League:     f.League.Name,
			HomeTeam:   f.Teams.Home.Name,
			AwayTeam:   f.Teams.Away.Name,
			Kickoff:    kickoff,
			Status:     status,
		})
	}
	return out, nil
}

// mapFeedStatus normalises API-Football status shorts to the feed enum.
func mapFeedStatus(short string) (FeedStatus, bool) {
	switch strings.ToUpper(strings.TrimSpace(short)) {
	case "NS", "TBD", "TO BE DEFINED", "PRE", "TIMED":
		return StatusScheduled, true
	case "1H", "2H", "HT", "ET", "P", "INT", "LIVE", "BT":
		return StatusLive, true
	case "FT", "AET", "PEN", "WO", "ABD":
		return StatusFinished, true
	case "CANC", "PST", "SUSP", "POST":
		return StatusCanceled, true
	default:
		return StatusScheduled, true
	}
}

// urlQueryEscape escapes a single path/query value for the provider GET.
func urlQueryEscape(v string) string { return url.QueryEscape(v) }
