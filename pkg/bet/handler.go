package bet

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"

	"mogok-maung-backend/pkg/auth"
)

// Handler exposes the betting HTTP API.
type Handler struct {
	repo *Repository
}

// NewHandler builds an HTTP handler for bets.
func NewHandler(repo *Repository) *Handler {
	return &Handler{repo: repo}
}

// Routes registers bet routes on the provided mux.
func (h *Handler) Routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/user/bets", h.PlaceBet)
}

// PlaceBet handles POST /api/v1/user/bets.
// The authenticated principal is injected onto the context by the auth
// middleware (see pkg/httpapi).
func (h *Handler) PlaceBet(w http.ResponseWriter, r *http.Request) {
	p, ok := auth.PrincipalFrom(r.Context())
	if !ok || p.UserID <= 0 {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	userID := p.UserID

	var req PlaceBetRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if err := req.Validate(); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	resp, err := h.repo.PlaceBet(r.Context(), userID, req)
	if err != nil {
		switch {
		case errors.Is(err, ErrInsufficientBalance):
			writeError(w, http.StatusUnprocessableEntity, err.Error())
		case errors.Is(err, ErrClosedMatch):
			writeError(w, http.StatusConflict, err.Error())
		case errors.Is(err, ErrInvalidRequest):
			writeError(w, http.StatusBadRequest, err.Error())
		default:
			log.Printf("place bet failed for user %d: %v", userID, err)
			writeError(w, http.StatusInternalServerError, "internal server error")
		}
		return
	}

	writeJSON(w, http.StatusCreated, resp)
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("encode response: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
