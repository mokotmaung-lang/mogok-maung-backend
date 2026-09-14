#!/usr/bin/env bash
# ==============================================================================
# build-backend.sh — cross-compile all three Linux binaries for direct
# deployment to the production VPS (used by the systemd path in Step 4).
#
# Outputs (static, non-root-safe, stripped):
#   build/api       (cmd/api)      — REST API + admin/agent control plane
#   build/worker    (cmd/worker)   — settlement worker
#   build/webhook   (cmd/webhook)  — Viber/Telegram deposit intake
#
# These binaries are deployed as /opt/mogok-maung/build/* by deploy.sh and run
# under systemd (deploy/systemd/mogok-api.service etc.). CGO_ENABLED=0 keeps
# them glibc-free so any modern Linux glibc/musl host runs them unchanged.
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${OUT:-${ROOT}/build}"
mkdir -p "${OUT}"

echo "[build] fetching modules..."
(cd "${ROOT}" && go mod tidy)
(cd "${ROOT}" && go mod download)

build_bin() {
    local name=$1; shift
    echo "[build] ${name} (linux/amd64, CGO disabled)..."
    (cd "${ROOT}" && \
     CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
     go build -trimpath -ldflags="-s -w" -o "${OUT}/${name}" "$@")
}

build_bin api     ./cmd/api
build_bin worker  ./cmd/worker
build_bin webhook ./cmd/webhook

echo "[build] verification..."
(cd "${ROOT}" && go vet ./...)

echo "[build] done — binaries in ${OUT}:"
ls -lh "${OUT}"