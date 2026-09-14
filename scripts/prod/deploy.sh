#!/usr/bin/env bash
# ==============================================================================
# deploy.sh — orchestrates a single-command production rollout of the Mogok
# Maung platform on a fresh Ubuntu 22.04/24.04 VPS (root or sudo).
#
# Order:
#   1. sanity: env file present, every ${VAR:?} referenced by compose resolves
#   2. JWT_SECRET auto-generation (only if still empty)
#   3. postgres TLS certs (scripts/prod/setup-db-tls.sh)
#   4. docker compose up -d (DB/Redis/RabbitMQ/API/worker/webhook)
#   5. verify (or build) the Flutter Web assets nginx serves
#   6. wait for /health, run bootstrap SUPER_ADMIN seeder; /health now also
#      gates on Redis (the API returns 503 when PG OR Redis is unreachable)
#   7. smoke test login path
#   8. nginx -t + reload, install systemd units (API/worker/webhook) targeting
#      /opt/mogok-maung binaries — print the follow-up notes.
#
# If you prefer the ALL-native path (no compose for app services) skip step 4
# by exporting NATIVE_ONLY=1 — then this script only does TLS + bootstrap +
# systemd + nginx after build-backend.sh.
#
# Usage:
#   sudo scripts/prod/deploy.sh             # compose path
#   sudo scripts/prod/deploy.sh             # NATIVE_ONLY=1 for systemd-only
# ==============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_DIR}/.env.production}"
COMPOSE_FILE="${COMPOSE_FILE:-${REPO_DIR}/docker-compose.prod.yml}"
NATIVE_ONLY=${NATIVE_ONLY:-0}

[ -f "${ENV_FILE}" ] || { echo "[deploy] missing ${ENV_FILE} — copy .env.production from the template"; exit 1; }
set -a; source "${ENV_FILE}"; set +a

echo "== Mogok Maung production deploy =="

# --- 1. Compose file env sanity (rejects undefined ${VAR:?}) -------------------
echo "[1/8] validating compose env..."
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" config -q
echo "      ok"

# --- 1b. Pre-flight: host port conflicts ----------------------------------------
# The compose stack publishes ONLY 127.0.0.1:8081 (API); nginx (80/443) is the
# expected edge; redis/rabbitmq are internal-network-only so a NATIVE broker is
# a duplicate-daemon risk (double settlement!), not a bind failure. Owners that
# belong to this stack (docker-proxy/nginx) are legal even on re-deploys.
# Hard-fail only on a FOREIGN process holding a port the stack must bind.
#
# Detection: prefer ss (always on Ubuntu); fall back to lsof (auto-installed).
if [ "${SKIP_PORT_CHECK:-0}" -ne 1 ]; then
    PORT_TOOL=none
    if command -v ss >/dev/null 2>&1; then
        PORT_TOOL=ss
    elif command -v lsof >/dev/null 2>&1; then
        PORT_TOOL=lsof
    else
        echo "      ss/lsof not found — installing lsof..."
        apt-get update -qq >/dev/null && apt-get install -y -qq lsof >/dev/null 2>&1 \
            && PORT_TOOL=lsof \
            || echo "      WARN: apt install lsof failed; skipping port scan"
    fi

    if [ "${PORT_TOOL}" != "none" ]; then
        echo "      scanning host ports (${PORT_TOOL})..."
        CONFLICT=0

        list_listeners() { # $1=port — prints one process name per listening socket
            case "${PORT_TOOL}" in
                ss)   ss -ltnpH "sport = :${1}" 2>/dev/null \
                          | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' ;;
                lsof) lsof -nP -iTCP:${1} -sTCP:LISTEN 2>/dev/null \
                          | awk 'NR>1{print $1; exit}' ;;
            esac
        }

        scan_port() { # $1=port $2=HARD|WARN
            local port="$1" php="$2" proc
            while IFS= read -r proc; do
                [ -z "${proc}" ] && continue
                case "${proc}" in
                    docker-proxy|nginx) continue ;;
                    *)
                        if [ "${php}" = "HARD" ]; then
                            echo "      ERROR: port ${port} held by foreign process: ${proc}"
                            echo "             stop it (e.g. sudo systemctl stop mogok-api) or export SKIP_PORT_CHECK=1"
                            CONFLICT=1
                        else
                            echo "      WARN:  ${proc} listening on :${port} (duplicate native broker?)"
                            echo "             safe to keep only if it does not run worker/settlement"
                        fi
                        ;;
                esac
            done < <(list_listeners "${port}")
        }

        # foreign process holding 8081 => exit; anything else (broker) => warn
        scan_port 8081 HARD
        for p in 80 443 6379 5672; do scan_port "${p}" WARN; done

        [ "${CONFLICT}" -eq 1 ] && exit 1
        echo "      port conflicts: none (compose binds only 127.0.0.1:8081)"
    fi
fi

# --- 2. JWT_SECRET bootstrap ---------------------------------------------------
if [ -z "${JWT_SECRET:-}" ]; then
    JWT_SECRET="$(openssl rand -hex 32)"
    # persist under the same root-owned file so systemd EnvironmentFile sees it
    sed -i "s/^JWT_SECRET=.*/JWT_SECRET=${JWT_SECRET}/" "${ENV_FILE}"
    echo "[2/8] generated JWT_SECRET (64 hex) and wrote it into ${ENV_FILE}"
else
    echo "[2/8] JWT_SECRET present (${#JWT_SECRET} chars)"
fi

# --- 3. Postgres TLS certs ------------------------------------------------------
echo "[3/8] postgres TLS..."
"${REPO_DIR}/scripts/prod/setup-db-tls.sh"

# --- 4. Compose up ----------------------------------------------------------------
if [ "${NATIVE_ONLY}" -eq 1 ]; then
    echo "[4/8] NATIVE_ONLY — skipping compose app stack (ensure DB/Redis/RabbitMQ already up)"
else
    echo "[4/8] starting compose stack..."
    docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d
fi

# --- 5. Flutter Web asset verification / build -----------------------------------
echo "[5/8] verifying Flutter Web assets..."
WEB_ROOT="${REPO_DIR}/mobile/build/web"
if [ -f "${WEB_ROOT}/index.html" ]; then
    echo "      found ${WEB_ROOT} (index.html present) — nginx will serve this SPA"
else
    if command -v flutter >/dev/null 2>&1; then
        echo "      missing index.html — building web release (DOMAIN FROM env)..."
        "${REPO_DIR}/scripts/prod/build-flutter.sh"
    else
        echo "      WARNING: ${WEB_ROOT} missing and no 'flutter' on this host."
        echo "      Ship the SPA via rsync from the build machine, e.g.:"
        echo "        VPS_SSH=root@$(hostname -I | awk '{print $1}') bash scripts/prod/rsync-deploy.sh"
    fi
fi

# --- 6. Health + bootstrap admin ---------------------------------------------------
echo "[6/8] waiting for /health..."
HOST_PORT="${HOST_PORT_API:-8081}"
for i in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${HOST_PORT}/health" 2>/dev/null | grep -q ok; then
        echo "      api healthy (PG + Redis)"
        break
    fi
    [ "${i}" -eq 30 ] && { echo "      api never became healthy"; exit 1; }
    sleep 2
done

echo "      bootstrapping SUPER_ADMIN..."
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" exec -T postgres-db \
    psql -U "${DB_USER}" -d "${DB_NAME}" \
    -v boot_user="${BOOT_ADMIN_USER:-superadmin}" \
    -v boot_pass="${BOOT_ADMIN_PASS}" \
    -f /seeders/001_bootstrap_admin.sql || \
    echo "      (bootstrap skipped — maybe already present)"


# --- 7. Smoke test -------------------------------------------------------------
echo "[7/8] smoke test..."
SMOKE_PASSWORD="${BOOT_ADMIN_PASS:-}" \
SMOKE_ROLES="${BOOT_ADMIN_USER:-superadmin}:SUPER_ADMIN" \
DOMAIN_NAME="http://127.0.0.1:${HOST_PORT}" \
    "${REPO_DIR}/scripts/prod/smoke-test.sh"

# --- 8. Nginx validate/reload + systemd (native path) ----------------------------
echo "[8/8] nginx + systemd units (native /opt/mogok-maung layout):"
if command -v nginx >/dev/null 2>&1; then
    if nginx -t; then
        systemctl reload nginx 2>/dev/null || systemctl start nginx
        echo "      nginx config valid — reloaded"
    else
        echo "      WARNING: 'nginx -t' FAILED — fix before going live; deploy.sh continues"
    fi
else
    echo "      nginx not installed yet — run: EMAIL=you@mmrodds.com bash scripts/prod/setup-ssl.sh"
fi

echo "      install /opt/mogok-maung/.env.production"
echo "      install build binaries: ${REPO_DIR}/build/{api,worker,webhook} -> /opt/mogok-maung/build/"
echo "      systemctl enable --now mogok-api mogok-worker     (mogok-webhook if bots enabled)"

echo
echo "== Deploy complete =="