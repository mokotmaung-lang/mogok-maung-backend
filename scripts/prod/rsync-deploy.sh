#!/usr/bin/env bash
# ==============================================================================
# rsync-deploy.sh — push the project to the production VPS as /opt/mogok-maung.
#
# Runs from WSL, Git-Bash or any Linux/macOS host with rsync + OpenSSH.
# Everything under the repo root is copied EXCEPT the heavy/build artifacts and
# secrets that the server regenerates itself (node_modules, .next, build/,
# mobile/build, .dart_tool, *.log, .git). .env.production IS shipped so you can
# fill real secrets ON the server (never edit the committed value).
#
# NOTE: no --delete. deploy.sh/systemd later create server-side state
# (server-edited .env.production, ./secrets/pg-tls, /opt/mogok-maung/build),
# and --delete would silently wipe those on a re-sync.
#
# Usage:
#   VPS_SSH=root@1.2.3.4 VPS_PORT=22 scripts/prod/rsync-deploy.sh --dry-run
#   VPS_SSH=deploy@api.yourdomain.com scripts/prod/rsync-deploy.sh
#   # custom key / non-loopback host:
#   VPS_SSH=root@1.2.3.4 SSH_KEY="$HOME/.ssh/vps_ed25519" .../rsync-deploy.sh
#
# First run note: the script auto-creates ${DEST} on the server (idempotent).
# ==============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VPS_SSH=${VPS_SSH:?set VPS_SSH e.g. root@1.2.3.4}
VPS_PORT=${VPS_PORT:-22}
DEST=${DEST:-/opt/mogok-maung}

RSYNC_ARGS=(-a -z --info=stats1 --chmod=Du=rwx,Dgo=rx,Fu=rwx,Fgo=rx)

# Single -e ssh command (custom key optional).
SSH_CMD="ssh -p ${VPS_PORT}"
[ -n "${SSH_KEY:-}" ] && SSH_CMD="ssh -p ${VPS_PORT} -i ${SSH_KEY}"

# Pass through and validate the optional --dry-run flag.
DRY=""
for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY="--dry-run" ;;
        *) echo "[rsync] unknown arg: ${arg}" >&2; exit 2 ;;
    esac
done

# Ensure the remote destination exists (idempotent; skipped on --dry-run).
if [ -z "${DRY}" ]; then
    echo "== ensuring ${VPS_SSH}:${DEST} exists =="
    ${SSH_CMD} "${VPS_SSH}" "mkdir -p ${DEST}"
fi

# Everything the server should NOT receive: build caches, tooling state,
# local-only secrets. .env.production is intentionally shipped (see header).
# EXCEPTION: mobile/build/web/ (the Flutter Web SPA, a few MB) IS shipped —
# nginx on the server serves it from /opt/mogok-maung/mobile/build/web.
EXCLUDES=(
    --filter='+ mobile/build/web/'          # keep the SPA (dir + recursion)
    --filter='+ mobile/build/web/**'
    --filter='- mobile/build/*'
    --exclude='/.git/'
    --exclude='/.gitlab-ci.yml'
    --exclude='/.github/'
    --exclude='node_modules/'
    --exclude='.next/'
    --exclude='out/'
    --exclude='/build/'          # Go cross-compile outputs -> built on CI/lab
    --exclude='/bin/'
    --exclude='mobile/.dart_tool/'
    --exclude='mobile/android/.gradle/'
    --exclude='mobile/.flutter-plugins-dependencies'
    --exclude='*.log'
    --exclude='coverage.out'
    --exclude='.idea/'
    --exclude='.vscode/'
    --exclude='Thumbs.db'
    --exclude='.DS_Store'
)

echo "== rsync ${VPS_SSH}:${DEST} ${DRY} =="
rsync "${RSYNC_ARGS[@]}" "${EXCLUDES[@]}" \
    -e "${SSH_CMD}" \
    ${DRY} \
    "${REPO}/" "${VPS_SSH}:${DEST}/"

echo
echo "== transferred. server-side next steps =="
echo " 1) ssh ${VPS_SSH}"
echo " 2) cd /opt/mogok-maung && nano .env.production   # JWT_SECRET=openssl rand -hex 32, DB_PASSWORD, DOMAIN_NAME"
echo " 3) bash scripts/prod/setup-db-tls.sh              # then: bash scripts/prod/setup-ssl.sh"
echo " 4) bash scripts/prod/deploy.sh"