#!/usr/bin/env bash
# ==============================================================================
# go-live.sh — END-TO-END one-shot production rollout for the Mogok Maung VPS.
#
# Run ON the VPS (root). Normally handed off by deploy-vps.sh (clone+env), or
# directly after rsync brought the repo to /opt/mogok-maung:
#   ssh root@VPS_IP
#   cd /opt/mogok-maung && bash scripts/prod/go-live.sh
#
# Steps (all idempotent):
#   1. bootstrap docker + compose + ufw (SSH ${SSH_PORT}, 22, 80/443) [VPS only]
#   2. autofill real secrets in .env.production (never clobber real values)
#   3. public DNS pre-check against 8.8.8.8 (DOMAINS from env/default)
#   4. postgres TLS certs  (scripts/prod/setup-db-tls.sh)
#   5. Let's Encrypt SSL   (output-level EMAIL?, DOMAINS env override)
#   6. full deploy         (scripts/prod/deploy.sh - compose up, migrate,
#                           SUPER_ADMIN bootstrap, smoke, nginx -t + reload)
#   7. public verification: /health, home SPA, admin gate 403, SSL expiry
# ==============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[go-live] run as root: sudo bash scripts/prod/go-live.sh"; exit 1; }

REPO_DIR=/opt/mogok-maung
ENV_FILE="${REPO_DIR}/.env.production"
EMAIL=${EMAIL:-admin@oddsmyanmar.online}
DOMAINS=${DOMAINS:-"oddsmyanmar.online api.oddsmyanmar.online"}
VPS_IP=${VPS_IP:-104.207.77.242}
SSH_PORT=${SSH_PORT:-22022}
APEX="${DOMAINS%% *}"
API="${DOMAINS##* }"
export EMAIL DOMAINS VPS_IP SSH_PORT APEX API

cd "${REPO_DIR}"
[ -f "${ENV_FILE}" ] || { echo "[go-live] missing ${ENV_FILE} — run rsync-deploy.sh first"; exit 1; }

echo "== go-live: ${DOMAINS} (IP ${VPS_IP}) =="

# --- 1. Docker + ufw bootstrap ----------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "[1/7] installing docker + compose plugin..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg ufw
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
else
    echo "[1/7] docker present: $(docker --version); compose: $(docker compose version --short)"
fi

if command -v ufw >/dev/null 2>&1 && ! ufw status | grep -q "Status: active"; then
    echo "[1/7] enabling ufw (SSH ${SSH_PORT} + 22 + 80,443)..."
    ufw allow "${SSH_PORT}/tcp"
    ufw allow OpenSSH
    ufw allow 80,443/tcp
    echo y | ufw enable
fi

# --- 2. Secret bootstrap -----------------------------------------------------------
echo "[2/7] secrets..."
set_secret() { # $1=key $2=val
    local key="$1" val="$2" cur
    cur="$(grep -E "^${key}=" "${ENV_FILE}" | tail -1 | cut -d= -f2- || true)"
    if [[ -z "${cur}" || "${cur}" == *CHANGE_ME* ]]; then
        if grep -qE "^${key}=" "${ENV_FILE}"; then
            sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
        else
            printf '%s=%s\n' "${key}" "${val}" >> "${ENV_FILE}"
        fi
        echo "      ${key} = <generated>"
    else
        echo "      ${key} = <kept existing>"
    fi
}

set_secret DB_PASSWORD        "$(openssl rand -base64 32)"
set_secret REDIS_PASSWORD     "$(openssl rand -base64 32)"
RABBITMQ_USER="broker_$(openssl rand -hex 4)"
RABBITMQ_PASS="$(openssl rand -base64 32)"
set_secret RABBITMQ_USER      "${RABBITMQ_USER}"
set_secret RABBITMQ_PASS      "${RABBITMQ_PASS}"
set_secret BOOT_ADMIN_PASS    "$(openssl rand -base64 24)"
set_secret JWT_SECRET         "$(openssl rand -hex 32)"

# Keep the native/systemd AMQP_URL in sync with the generated broker creds.
set_secret AMQP_URL           "amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@127.0.0.1:5672/"

chmod 600 "${ENV_FILE}"

# --- 3. Public DNS pre-check --------------------------------------------------------
echo "[3/7] DNS (via 8.8.8.8, up to 60s)..."
command -v dig >/dev/null 2>&1 || apt-get install -y -qq dnsutils >/dev/null
check_dns() { # $1=host $2=want
    local host="$1" want="$2" ip= i
    for i in $(seq 1 10); do
        ip="$(dig +short "${host}" @8.8.8.8 2>/dev/null | tail -1 || true)"
        [ -n "${ip}" ] && break
        sleep 6
    done
    if [ -z "${ip}" ]; then
        echo "      ERROR ${host} not resolving publicly yet — create the A record and wait for propagation"
        exit 1
    fi
    if [ "${ip}" = "${want}" ]; then
        echo "      ${host} -> ${ip} OK"
    else
        echo "      WARN ${host} -> ${ip} (expected ${want}) — continue if this is correct"
    fi
}
check_dns "${APEX}" "${VPS_IP}"
check_dns "${API}" "${VPS_IP}"

# --- 4. Postgres TLS -----------------------------------------------------------------
echo "[4/7] postgres TLS..."
bash scripts/prod/setup-db-tls.sh

# --- 5. Let's Encrypt SSL -------------------------------------------------------------
echo "[5/7] Let's Encrypt... (EMAIL=${EMAIL} DOMAINS=${DOMAINS})"
bash scripts/prod/setup-ssl.sh

# --- 6. Full deploy --------------------------------------------------------------------
echo "[6/7] deploy.sh..."
bash scripts/prod/deploy.sh

# --- 7. Public verification ----------------------------------------------------------------
echo "[7/7] verifying public endpoints..."
printf "      %-45s" "https://${API}/health:";  curl -fsS "https://${API}/health" && echo " (200 ok)"
printf "      %-45s" "https://${APEX}/ (SPA):";        curl -s -o /dev/null -w "%{http_code}\n" "https://${APEX}/"
printf "      %-45s" "admin gate (expect 403):";           curl -s -o /dev/null -w "%{http_code}\n" "https://${API}/api/v1/admin/fixtures"
printf "      %-45s" "SSL expiry (days):";                 openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${APEX}/fullchain.pem" | cut -d= -f2-

echo "== go-live complete =="