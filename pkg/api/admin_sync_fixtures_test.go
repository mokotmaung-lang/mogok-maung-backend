package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"mogok-maung-backend/pkg/feed"
)

// noopProvider is a configured-but-inert provider: it reports that no real
// subscription is usable, which the sync flow must surface as a clean 503.
type noopProvider struct{}

func (noopProvider) Fetch(ctx context.Context) ([]feed.FeedMatch, error) {
	return nil, feed.ErrProviderNotConfigured
}

func TestSyncFixturesProviderNotConfigured(t *testing.T) {
	h := NewAdminHandler(nil, nil, nil) // no feed provider, no DB
	mux := http.NewServeMux()
	mux.HandleFunc("POST /sync", h.SyncFixtures)

	req := httptest.NewRequest(http.MethodPost, "http://example.com/sync", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusServiceUnavailable)
	}

	var payload struct {
		Error string `json:"error"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if payload.Error != "fixture sync provider not configured" {
		t.Fatalf("error = %q", payload.Error)
	}
}

// TestSyncFixturesProviderConfigured exercises the empty-provider + nil-DB
// seam: a configured-but-inert provider that returns ErrProviderNotConfigured
// must surface as 503 (never reach the database).
func TestSyncFixturesProviderConfigured(t *testing.T) {
	h := NewAdminHandler(nil, nil, nil, WithFeedProvider(noopProvider{}))
	mux := http.NewServeMux()
	mux.HandleFunc("POST /sync", h.SyncFixtures)

	req := httptest.NewRequest(http.MethodPost, "http://example.com/sync", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusServiceUnavailable)
	}
}
