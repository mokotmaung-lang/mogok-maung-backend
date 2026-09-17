package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// newAgentHandlerForTest wires an AgentHandler with a nil DB — only the input
// validation paths (which reject before any query) are exercised here, exactly
// like the admin validation suites.
func newAgentHandlerForTest() http.Handler {
	h := NewAgentHandler(nil)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /sandbox", h.SandboxTestBet)
	return mux
}

func newAgentCreateHandlerForTest() http.Handler {
	h := NewAgentHandler(nil)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /create", h.CreateDownlineUser)
	return mux
}

func newAgentAllocateHandlerForTest() http.Handler {
	h := NewAgentHandler(nil)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /users/{id}/allocate-units", h.AllocateDownlineUnits)
	return mux
}

func doPostPath(t *testing.T, h http.Handler, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "http://example.com"+path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestCreateDownlineUserValidation(t *testing.T) {
	h := newAgentCreateHandlerForTest()

	tests := []struct {
		name    string
		body    string
		wantErr string
	}{
		{
			name:    "invalid json",
			body:    `{not json`,
			wantErr: "invalid JSON body",
		},
		{
			name:    "empty username and phone",
			body:    `{"username":"","phone":""}`,
			wantErr: "username and phone are required",
		},
		{
			name:    "username too long",
			body:    `{"username":"` + strings.Repeat("a", 51) + `","phone":"09"}`,
			wantErr: "username must be 50 characters or fewer",
		},
		{
			name:    "negative initial balance",
			body:    `{"username":"mg_min","phone":"09","initial_balance":-1}`,
			wantErr: "initial_balance must be a finite, non-negative amount",
		},
		{
			name:    "huge initial balance",
			body:    `{"username":"mg_min","phone":"09","initial_balance":10000000000000}`,
			wantErr: "initial_balance must be a finite, non-negative amount",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := doPostPath(t, h, "/create", tt.body)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
			}
			if errMsg := readErr(t, rec); errMsg != tt.wantErr {
				t.Fatalf("error = %q, want %q", errMsg, tt.wantErr)
			}
		})
	}
}

func TestAllocateDownlineUnitsValidation(t *testing.T) {
	h := newAgentAllocateHandlerForTest()

	tests := []struct {
		name    string
		path    string
		body    string
		wantErr string
	}{
		{
			name:    "non-numeric id",
			path:    "/users/abc/allocate-units",
			body:    `{"amount":100,"type":"DEPOSIT"}`,
			wantErr: "invalid user id path parameter",
		},
		{
			name:    "zero id",
			path:    "/users/0/allocate-units",
			body:    `{"amount":100,"type":"DEPOSIT"}`,
			wantErr: "invalid user id path parameter",
		},
		{
			name:    "invalid json",
			path:    "/users/3/allocate-units",
			body:    `{not json`,
			wantErr: "invalid JSON body",
		},
		{
			name:    "zero amount",
			path:    "/users/3/allocate-units",
			body:    `{"amount":0,"type":"DEPOSIT"}`,
			wantErr: "amount must be greater than zero",
		},
		{
			name:    "invalid type",
			path:    "/users/3/allocate-units",
			body:    `{"amount":100,"type":"CREDIT"}`,
			wantErr: "type must be DEPOSIT or WITHDRAW",
		},
		{
			name:    "note too long",
			path:    "/users/3/allocate-units",
			body:    `{"amount":100,"type":"DEPOSIT","note":"` + strings.Repeat("a", 501) + `"}`,
			wantErr: "note must be 500 characters or fewer",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := doPostPath(t, h, tt.path, tt.body)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
			}
			if errMsg := readErr(t, rec); errMsg != tt.wantErr {
				t.Fatalf("error = %q, want %q", errMsg, tt.wantErr)
			}
		})
	}
}

func TestSandboxTestBetValidation(t *testing.T) {
	h := newAgentHandlerForTest()

	tests := []struct {
		name    string
		body    string
		wantErr string
	}{
		{
			name:    "invalid json",
			body:    `{not json`,
			wantErr: "invalid JSON body",
		},
		{
			name:    "zero user id",
			body:    `{"user_id":0,"bet_type":"BODY","total_stake":100,"match_id":1,"pick":"HOME"}`,
			wantErr: "user_id and match_id must be positive integers",
		},
		{
			name:    "unsupported bet_type",
			body:    `{"user_id":5,"bet_type":"DOUBLE","total_stake":100,"match_id":1,"pick":"HOME"}`,
			wantErr: "unsupported bet_type \"DOUBLE\"",
		},
		{
			name:    "BODY bet missing body_odds_type",
			body:    `{"user_id":5,"bet_type":"BODY","total_stake":100,"match_id":1,"pick":"HOME"}`,
			wantErr: "BODY selections require body_odds_type",
		},
		{
			name:    "unsupported pick",
			body:    `{"user_id":5,"bet_type":"MAUNG","total_stake":100,"match_id":1,"pick":"WIN"}`,
			wantErr: "unsupported pick \"WIN\"",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := doPostPath(t, h, "/sandbox", tt.body)
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
}
