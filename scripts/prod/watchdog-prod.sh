#!/usr/bin/env bash
# =========================================================================== #
# watchdog-prod.sh ??? every-5-min PROD self-heal sweep.
#
#   bash scripts/prod/watchdog-prod.sh [--run|--check|--install-cron]
#                                        [--no-restart] [--silent]
#
# Probe policy (mapped 1:1 to docker-compose.prod.yml services):
#   user-service          HTTP  127.0.0.1:8081/health  must return "ok"
#   postgres-db           compose ps "(healthy)"       (pg_isready healthcheck)
#   redis-cache           compose ps "(healthy)"       (redis-cli ping)
#   rabbitmq              compose ps "(healthy)"       (rabbitmq-diagnostics)
#   bot-webhook-worker    compose ps "Up"              (AMQP consumer; no HTTP)
#   settlement-worker     compose ps "Up"              (batch; no HTTP)
#
# Self-heal = `docker compose restart <svc>` with exponential backoff
# (60/120/240s, max 3 attempts). Never stops/downs the stack, never drops the
# DB, never replays events. On incident (down after backoff sweep) it writes
# an incident file + optionally POSTs NOTIFY_WEBHOOK (set in
# .env.production). Money-safe by construction: no pg_dump, no restore ???
# backup-db.sh / restore-db.sh own those and require the stack down.
#
# Cron (idempotent): `*/5 * * * * cd ${REPO_DIR} && bash scripts/prod/
# watchdog-prod.sh --run >> backups/watchdog/watchdog.log 2>&1`
# =========================================================================== #
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE_FILE="docker-compose.prod.yml"
ENV_FILE="${REPO_DIR}/.env.production"
REPO_FS="$(cd "${REPO_DIR}" && pwd)"
LOG_DIR="${REPO_FS}/backups/watchdog"
LOG_FILE="${LOG_DIR}/watchdog.log"
STATE_DIR="${LOG_DIR}/state"

MODE="run"; NO_RESTART=0; SILENT=0
for a in "$@"; do
    case "${a}" in
        --check)         MODE="check" ;;
        --install-cron)  MODE="cron" ;;
        --run)           MODE="run" ;;
        --no-restart)    NO_RESTART=1 ;;
        --silent)        SILENT=1 ;;
        --*)             echo "unknown arg: ${a}"; exit 1 ;;
    esac
done
mkdir -p "${LOG_DIR}" "${STATE_DIR}"

env_file_get() { grep -E "^${1}=" "${ENV_FILE}" | tail -1 | cut -d= -f2- || true; }
NOTIFY_WEBHOOK="${NOTIFY_WEBHOOK:-$(env_file_get NOTIFY_WEBHOOK)}"

compose_cmd() {
    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" "$@"
}
log() { printf '%s %s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "${*}" >> "${LOG_FILE}"; }

svc_status() {
    local svc="${1}"
    compose_cmd ps --no-trunc --format '{{.Service}}|{{.Status}}' 2>/dev/null \
        | awk -F'|' -v s="${svc}" '$1==s{print; f=1} END{exit f?0:1}' || true
}
svc_ok() {
    local svc="${1}"
    svc_status "${svc}" | grep -qE '\|\(healthy\)\|' \
        || svc_status "${svc}" | grep -qE '\|Up\b'
}

probe_user()        { curl -fsS --max-time 6 "http://127.0.0.1:8081/health" | grep -q 'ok' || return 1; }
probe_worker()      { svc_ok "${1}" || return 1; }

restart_backoff() {
    local svc="${1}" attempt="${2}"
    local delay=$(( 60 * 2 ** (attempt - 1) ))
    [[ "${delay}" -gt 240 ]] && delay=240
    echo "[watchdog] restart ${svc} (attempt ${attempt}, backoff ${delay}s)"
    compose_cmd restart "${svc}" >/dev/null 2>&1 || true
    sleep "${delay}"
}

notify() {
    local svc="${1}" reason="${2}" ts="${3}"
    [[ -z "${NOTIFY_WEBHOOK}" ]] && return 0
    local body
    body="$(printf '{"source":"watchdog-prod","service":"%s","status":"down","reason":"%s","ts":"%s"}' \
        "${svc}" "${reason}" "${ts}")"
    curl -fsS --max-time 8 -X POST -H 'Content-Type: application/json' \
        -d "${body}" "${NOTIFY_WEBHOOK}" >/dev/null 2>&1 \
        && echo "[watchdog]  -> notified ${NOTIFY_WEBHOOK}" \
        || echo "[watchdog]  -> notify FAILED (webhook unreachable)" >&2
}

stamp_file() { printf '%s\n' "${STAMP}" > "${STATE_DIR}/last-${svc}.down"; }
stamp="$(date -u +%Y%m%dT%H%M%SZ)"

# --------------------------------------------------------------------------- #
if [[ "${MODE}" = "cron" ]]; then
    CRON_LINE="*/5 * * * * cd ${REPO_DIR} && bash scripts/prod/watchdog-prod.sh --run >> ${LOG_FILE} 2>&1"
    if crontab -l 2>/dev/null | grep -qF "scripts/prod/watchdog-prod.sh"; then
        echo "[watchdog] cron already installed:"
        crontab -l | grep -F "scripts/prod/watchdog-prod.sh"
        exit 0
    fi
    ( crontab -l 2>/dev/null | grep -vF "scripts/prod/watchdog-prod.sh"; \
        printf '%s\n' "${CRON_LINE}" ) | crontab -
    echo "[watchdog] cron installed: ${CRON_LINE}"
    exit 0
fi

rc=0
# sweep in dependency order: infra first, then the writers we must not drop.
for svc in postgres-db redis-cache rabbitmq user-service bot-webhook-worker settlement-worker; do
    reason=""
    if [[ "${svc}" = "user-service" ]]; then
        if probe_user >/dev/null 2>&1; then
            echo "[watchdog] ${svc}: UP"
            continue
        fi
        reason="HTTP /health != ok"
    else
        if svc_ok "${svc}" >/dev/null 2>&1; then
            echo "[watchdog] ${svc}: UP"
            continue
        fi
        reason="compose state not (healthy)/Up"
    fi

    healed=0
    if [[ "${NO_RESTART}" != "1" ]]; then
        for attempt in 1 2 3; do
            restart_backoff "${svc}" "${attempt}"
            if [[ "${svc}" = "user-service" ]]; then
                probe_user >/dev/null 2>&1 || continue
            else
                svc_ok "${svc}" >/dev/null 2>&1 || continue
            fi
            healed=1
            echo "[watchdog] ${svc}: HEALED (attempt ${attempt}, backoff)"
            break
        done
    fi
    if [[ "${healed}" = "1" ]]; then
        continue
    fi

    rc=1
    echo "[watchdog] ${svc}: DOWN ??? ${reason} (restart backoff exhausted, incident @ ${stamp})"
    mkdir -p "${LOG_DIR}/incidents"
    printf '%s|%s|%s\n' "${stamp}" "${svc}" "${reason}" \
        > "${LOG_DIR}/incidents/${stamp}.${svc}.incident"
    notify "${svc}" "${reason}" "${stamp}"
done
exit "${rc}"
