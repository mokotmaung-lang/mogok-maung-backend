package auth

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"

	"mogok-maung-backend/pkg/models"
)

type principalKey struct{}

// Principal is the identity of an authenticated request, populated by the
// Authenticate middleware and consumed by role guards and handlers.
type Principal struct {
	UserID int64
	Role   models.UserRole
}

// PrincipalFrom extracts the principal from a request context.
func PrincipalFrom(ctx context.Context) (Principal, bool) {
	p, ok := ctx.Value(principalKey{}).(Principal)
	return p, ok
}

// Authenticate is Chain-compatible middleware: it requires a valid
// "Authorization: Bearer <token>" header and stores the principal on the
// request context. Compose with auth.Chain:
//
//	auth.Chain(handler, auth.Authenticate(jwtSecret), auth.RequireRole(...))
func Authenticate(secret string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			header := r.Header.Get("Authorization")
			if !strings.HasPrefix(header, "Bearer ") {
				writeUnauthorized(w)
				return
			}
			claims, err := ParseToken(strings.TrimPrefix(header, "Bearer "), []byte(secret))
			if err != nil {
				writeUnauthorized(w)
				return
			}
			ctx := context.WithValue(r.Context(), principalKey{},
				Principal{UserID: claims.UserID, Role: claims.Role})
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// RequireRole is middleware: it rejects requests whose principal role is not in
// the allowed set. Chain authenticating middleware before it in production.
func RequireRole(allowed ...models.UserRole) func(http.Handler) http.Handler {
	permitted := make(map[models.UserRole]struct{}, len(allowed))
	for _, role := range allowed {
		permitted[role] = struct{}{}
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			p, ok := PrincipalFrom(r.Context())
			if !ok {
				writeUnauthorized(w)
				return
			}
			if _, ok := permitted[p.Role]; !ok {
				writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// RequirePasswordChanged is middleware: it blocks users whose account still
// carries the force-password-change flag (agent-provisioned bootstrap
// password) from reaching sensitive operations. Clients receive the code
// PASSWORD_CHANGE_REQUIRED to route to the mandatory change screen.
func RequirePasswordChanged(db *sql.DB) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			p, ok := PrincipalFrom(r.Context())
			if !ok {
				writeUnauthorized(w)
				return
			}
			var mustChange bool
			if err := db.QueryRowContext(r.Context(),
				`SELECT must_change_password FROM users WHERE id = $1`, p.UserID,
			).Scan(&mustChange); err != nil {
				writeJSON(w, http.StatusInternalServerError,
					map[string]string{"error": "internal server error"})
				return
			}
			if mustChange {
				writeJSON(w, http.StatusForbidden,
					map[string]string{"error": "PASSWORD_CHANGE_REQUIRED"})
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// Chain nests middlewares around h (innermost is applied last). The base
// handler may be a plain func(http.ResponseWriter, *http.Request) — it is
// lifted to http.HandlerFunc so route wiring stays concise.
func Chain(h http.HandlerFunc, mws ...func(http.Handler) http.Handler) http.Handler {
	var next http.Handler = h
	for i := len(mws) - 1; i >= 0; i-- {
		next = mws[i](next)
	}
	return next
}

func writeUnauthorized(w http.ResponseWriter) {
	writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
