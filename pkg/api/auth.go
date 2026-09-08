package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"time"

	"golang.org/x/crypto/bcrypt"
	"mogok-maung-backend/pkg/auth"
	"mogok-maung-backend/pkg/models"
)

// AuthHandler issues JWTs to end users, agents and admins.
type AuthHandler struct {
	db        *sql.DB
	jwtSecret []byte
	ttl       time.Duration
}

// NewAuthHandler builds an AuthHandler.
func NewAuthHandler(db *sql.DB, jwtSecret string, ttl time.Duration) *AuthHandler {
	return &AuthHandler{db: db, jwtSecret: []byte(jwtSecret), ttl: ttl}
}

// Routes registers public auth routes on the provided mux.
func (h *AuthHandler) Routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/auth/login", h.Login)
}

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// Login authenticates a user by username/password and issues a signed token.
// Verification is timing-safe via bcrypt; failures collapse to a single
// "invalid credentials" response.
func (h *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.Username == "" || req.Password == "" {
		writeError(w, http.StatusBadRequest, "username and password are required")
		return
	}

	var user models.User
	err := h.db.QueryRowContext(r.Context(), `
		SELECT id, username, password_hash, name, role, is_active, must_change_password
		  FROM users WHERE username = $1`,
		req.Username,
	).Scan(&user.ID, &user.Username, &user.PasswordHash, &user.Name,
		&user.Role, &user.IsActive, &user.MustChangePassword)
	if isNoRows(err) {
		// Burn comparable time so username enumeration is not observable.
		_ = bcrypt.CompareHashAndPassword(dummyHash, []byte(req.Password))
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	if err != nil {
		log.Printf("auth: load user: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)); err != nil {
		if errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
			writeError(w, http.StatusUnauthorized, "invalid credentials")
			return
		}
		log.Printf("auth: compare password: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}
	if !user.IsActive {
		writeError(w, http.StatusForbidden, "account is deactivated")
		return
	}

	token, err := auth.IssueToken(user, h.jwtSecret, h.ttl)
	if err != nil {
		log.Printf("auth: issue token: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"access_token":         token,
		"token_type":           "Bearer",
		"expires_in":           int(h.ttl.Seconds()),
		"role":                 user.Role,
		"must_change_password": user.MustChangePassword,
	})
}

// dummyHash is a syntactically-valid bcrypt hash used to equalise the login
// code path when a username does not exist.
var dummyHash, _ = bcrypt.GenerateFromPassword([]byte("nomatterwhat"), bcrypt.DefaultCost)
