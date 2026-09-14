package httpapi

import (
	"net/http"
	"os"
	"strings"
)

// CORS wrapping for the API. Local-first by default so the Flutter web app
// (a randomly-port-spawned dev server) can talk to the API during development:
//   - origins on http://localhost:* / http://127.0.0.1:* are always allowed
//   - an exact-match allowlist can be configured explicitly via
//     CORS_ALLOWED_ORIGINS ("https://app.example.com,https://admin.example.com").
//
// Production is fronted by nginx (same-origin) and should pin CORS_ALLOWED_ORIGINS
// so untrusted cross-origin pages can never read responses.
func NewCORS(next http.Handler) http.Handler {
	allowed := map[string]struct{}{}
	if v := os.Getenv("CORS_ALLOWED_ORIGINS"); v != "" {
		for _, o := range strings.Split(v, ",") {
			if o = strings.TrimSpace(o); o != "" {
				allowed[o] = struct{}{}
			}
		}
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin == "" {
			// Not a browser/CORS request (curl, Docker healthcheck, WS upgrade).
			next.ServeHTTP(w, r)
			return
		}

		if originAllowed(origin, allowed) {
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", origin)
			h.Add("Vary", "Origin")

			// Preflight: answer OPTIONS with the CORS grant, no body.
			if r.Method == http.MethodOptions && r.Header.Get("Access-Control-Request-Method") != "" {
				h.Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
				h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
				h.Set("Access-Control-Max-Age", "86400")
				w.WriteHeader(http.StatusNoContent)
				return
			}
		} else if r.Method == http.MethodOptions && r.Header.Get("Access-Control-Request-Method") != "" {
			// Reject preflight from disallowed origins explicitly.
			http.Error(w, "cors origin not allowed", http.StatusForbidden)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func originAllowed(origin string, allowed map[string]struct{}) bool {
	if _, ok := allowed[origin]; ok {
		return true
	}
	// Dev: any origin running on the loopback interface.
	for _, prefix := range []string{"http://localhost:", "http://127.0.0.1:"} {
		if strings.HasPrefix(origin, prefix) {
			return true
		}
	}
	return false
}
