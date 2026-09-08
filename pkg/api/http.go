package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"math"
	"net/http"
)

// sentinel errors surfaced by approval settlement.
var (
	errRequestNotFound     = errors.New("request user not found")
	errInsufficientBalance = errors.New("insufficient balance for withdrawal")
)

// sqlErrNotFound reports whether err is a no-rows result.
func isNoRows(err error) bool {
	return err == sql.ErrNoRows
}

// handleSettlementError maps domain errors to HTTP statuses.
func handleSettlementError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errRequestNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, errInsufficientBalance):
		writeError(w, http.StatusUnprocessableEntity, err.Error())
	default:
		log.Printf("api: approval failed: %v", err)
		writeError(w, http.StatusInternalServerError, "internal server error")
	}
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("api: encode response: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// round2 rounds a money value to two decimal places, matching the NUMERIC(15,2)
// storage used across wallets and the ledger.
func round2(v float64) float64 {
	return math.Round(v*100) / 100
}
