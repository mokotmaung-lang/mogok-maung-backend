package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// newCreditHandlerForTest wires an AdminHandler with a nil DB — only the input
// validation paths (which reject before any query) are exercised here. SQL
// round-trips (lock, balance update, ledger append) are covered by the live
// integration / smoke suite.
func newCreditHandlerForTest() http.Handler {
	h := NewAdminHandler(nil, nil, nil)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/admin/agents/{agent_id}/credit", h.CreditAgent)
	return mux
}

func creditPost(t *testing.T, h http.Handler, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "http://example.com"+path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestAgentCreditLedgerType(t *testing.T) {
	cases := []struct {
		in     string
		ledger string
		ok     bool
	}{
		{"STANDARD_PURCHASE", "DEPOSIT", true},
		{"standard_purchase", "DEPOSIT", true},
		{"COMMISSION_BONUS", "COMMISSION_ADD", true},
		{"commission_bonus", "COMMISSION_ADD", true},
		{"PROMO", "", false},
		{"", "", false},
	}
	for _, c := range cases {
		got, ok := agentCreditLedgerType(c.in)
		if ok != c.ok || (ok && got != c.ledger) {
			t.Fatalf("agentCreditLedgerType(%q) = (%q, %v), want (%q, %v)", c.in, got, ok, c.ledger, c.ok)
		}
	}
}

func TestCreditAgentValidation(t *testing.T) {
	h := newCreditHandlerForTest()

	tests := []struct {
		name    string
		path    string
		body    string
		wantErr string
	}{
		{
			name:    "invalid json",
			path:    "/api/v1/admin/agents/7" + creditPathSuffix(),
			body:    `{not json`,
			wantErr: "invalid JSON body",
		},
		{
			name:    "non-numeric agent_id",
			path:    "/api/v1/admin/agents/abc" + creditPathSuffix(),
			body:    `{"amount":100,"allocation_type":"STANDARD_PURCHASE"}`,
			wantErr: "invalid agent_id path parameter",
		},
		{
			name:    "zero agent_id",
			path:    "/api/v1/admin/agents/0" + creditPathSuffix(),
			body:    `{"amount":100,"allocation_type":"STANDARD_PURCHASE"}`,
			wantErr: "invalid agent_id path parameter",
		},
		{
			name:    "negative amount",
			path:    "/api/v1/admin/agents/7" + creditPathSuffix(),
			body:    `{"amount":-1,"allocation_type":"STANDARD_PURCHASE"}`,
			wantErr: "amount must be greater than zero",
		},
		{
			name:    "zero amount",
			path:    "/api/v1/admin/agents/7" + creditPathSuffix(),
			body:    `{"amount":0,"allocation_type":"STANDARD_PURCHASE"}`,
			wantErr: "amount must be greater than zero",
		},
		{
			name:    "missing amount",
			path:    "/api/v1/admin/agents/7" + creditPathSuffix(),
			body:    `{"allocation_type":"STANDARD_PURCHASE"}`,
			wantErr: "amount must be greater than zero",
		},
		{
			name:    "bad allocation type",
			path:    "/api/v1/admin/agents/7" + creditPathSuffix(),
			body:    `{"amount":100,"allocation_type":"PROMO"}`,
			wantErr: `allocation_type must be STANDARD_PURCHASE or COMMISSION_BONUS; got "PROMO"`,
		},
		{
			name:    "missing allocation type",
			path:    "/api/v1/admin/agents/7" + creditPathSuffix(),
			body:    `{"amount":100}`,
			wantErr: `allocation_type must be STANDARD_PURCHASE or COMMISSION_BONUS; got ""`,
		},
		{
			name: "note too long",
			path: "/api/v1/admin/agents/7" + creditPathSuffix(),
			body: `{"amount":100,"allocation_type":"STANDARD_PURCHASE","note":"` +
				strings.Repeat("n", 501) + `"}`,
			wantErr: "note must be 500 characters or fewer",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := creditPost(t, h, tt.path, tt.body)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
			}
			var payload struct {
				Error string `json:"error"`
			}
			if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if payload.Error != tt.wantErr {
				t.Fatalf("error = %q, want %q", payload.Error, tt.wantErr)
			}
		})
	}

	// The wildcard route binds exactly to /credit: a bogus sibling path with a
	// valid agent_id must fall through to ServeMux's 404 rather than the
	// handler (validation would otherwise answer 400).
	rec := creditPost(t, h, "/api/v1/admin/agents/7/credits",
		`{"amount":100,"allocation_type":"STANDARD_PURCHASE"}`)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("sibling path status = %d, want %d (route must not match /credits)", rec.Code, http.StatusNotFound)
	}
}

// creditPathSuffix keeps the literal '/credit' suffix in one place.
func creditPathSuffix() string { return "/credit" }
