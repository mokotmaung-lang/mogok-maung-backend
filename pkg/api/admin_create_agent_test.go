package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// newAdminHandlerForTest wires an AdminHandler with a nil DB — only the input
// validation paths (which reject before any query) are exercised here. SQL
// round-trips are covered by the live integration / smoke suite.
func newAdminHandlerForTest() http.Handler {
	h := NewAdminHandler(nil, nil, nil)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /create", h.CreateAgent)
	return mux
}

func doPost(t *testing.T, h http.Handler, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "http://example.com/create", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func readErr(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var payload struct {
		Error string `json:"error"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return payload.Error
}

func TestCreateAgentValidation(t *testing.T) {
	h := newAdminHandlerForTest()

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
			name:    "empty username",
			body:    `{"username":"  ","phone":"+959100000007"}`,
			wantErr: "username is required",
		},
		{
			name:    "missing username",
			body:    `{"name":"Agent Three"}`,
			wantErr: "username is required",
		},
		{
			name:    "username too long",
			body:    `{"username":"` + strings.Repeat("a", 51) + `"}`,
			wantErr: "username must be 50 characters or fewer",
		},
		{
			name:    "short explicit password",
			body:    `{"username":"agentx","password":"1234567"}`,
			wantErr: "password must be at least 8 characters",
		},
		{
			name:    "name too long",
			body:    `{"username":"agentx","name":"` + strings.Repeat("n", 101) + `"}`,
			wantErr: "name must be 100 characters or fewer",
		},
		{
			name:    "phone too long",
			body:    `{"username":"agentx","phone":"` + strings.Repeat("9", 31) + `"}`,
			wantErr: "phone must be 30 characters or fewer",
		},
		{
			name:    "negative initial balance",
			body:    `{"username":"agentx","initial_balance":-100}`,
			wantErr: "initial_balance must be zero or a positive amount",
		},
		{
			name:    "huge initial balance overflows numeric(15,2)",
			body:    `{"username":"agentx","initial_balance":10000000000000}`,
			wantErr: "initial_balance exceeds NUMERIC(15,2) capacity",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := doPost(t, h, tt.body)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
			}
			if errMsg := readErr(t, rec); errMsg != tt.wantErr {
				t.Fatalf("error = %q, want %q", errMsg, tt.wantErr)
			}
		})
	}
}
