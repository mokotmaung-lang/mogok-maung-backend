#!/usr/bin/env bash
# --------------------------------------------------------------------------- #
# restore-db.sh — restore a backup-db.sh dump into the prod postgres cluster.
#
#   bash scripts/prod/restore-db.sh <dump-file> [--to-latest]
#
#   <dump-file>  path to a backup produced by backup-db.sh:
#                - *.dump.gz  plain pg_dump custom format (no-enc runs)
#                - *.dump.enc AES-256-CBC (BACKUP_KEY from .env.production)
#   --to-latest  on corrupt/missing dump, fall back to the newest valid backup
#   --list       print the newest backup's object list (sanity) and exit
#
# Requires the prod compose file/env exactly as backup-db.sh uses them.
#
#                        ───  MONEY-SAFETY / LOCK  ───
#   Postgres policy-driven restore (RESTORE_POLICY=), default is SAFE:
#     SAFE   - refused on a live cluster unless the PostgreSQL container is
#              first stopped, or --force is given. Prod API must be down
#              (compose stop user-api bot-webhook-worker settlement-worker).
#  Restore NEVER auto-opens migrations; it brings the DB to the exact state
#  captured at dump time.
# --------------------------------------------------------------------------- #
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE_FILE="docker-compose.prod.yml"
ENV_FILE="${REPO_DIR}/.env.production"
POSTGRES_SERVICE="postgres-db"
POSTGRES_CONTAINER="mm_prod_postgres"
BACKUP_ROOT="${BACKUP_ROOT:-${REPO_DIR}/backups}"
DUMP_DIR="${BACKUP_ROOT}/postgres"
MANIFEST="${DUMP_DIR}/MANIFEST.sha256"

RESTORE_POLICY="${RESTORE_POLICY:-safe}"
DUMP_FILE=""
TO_LATEST=0
MODE="run"
declare -a EXTRA_ARGS=()

usage() {
    sed -n '1,12p' "$0" | sed -E 's/^# ?//'
}

for a in "$@"; do
    case "${a}" in
        --to-latest)   TO_LATEST=1 ;;
        --force)       EXTRA_ARGS+=("--force") ;;
        --list)        MODE="list" ;;
        --*)           echo "unknown arg: ${a}"; exit 1 ;;
        *)             if [[ -n "${DUMP_FILE}" ]]; then
                           echo "unknown arg: ${a} (only one dump allowed)"; exit 1
                       fi
                       DUMP_FILE="${a}" ;;
    esac
done

# ENV values that backup-db.sh also needs; load & forward the same vars.
env_get() { grep -E "^${1}=" "${ENV_FILE}" | tail -1 | cut -d= -f2- || true; }
DB_NAME="$(env_get POSTGRES_DB)"
DB_USER="$(env_get POSTGRES_USER)"
DB_NAME="${DB_NAME:-myanmar_bet_prod}"
DB_USER="${DB_USER:-bet_admin}"

resolve_dump() {
    if [[ -n "${DUMP_FILE}" && -f "${DUMP_FILE}" ]]; then
        echo "${DUMP_FILE}"
        return 0
    fi
    [ "${TO_LATEST}" = "1" ] || return 1
    local newest_plain newest_enc
    newest_plain="$(ls -1t "${DUMP_DIR}"/*.dump.gz 2>/dev/null | head -1 || true)"
    newest_enc="$(ls -1t "${DUMP_DIR}"/*.dump.enc 2>/dev/null | head -1 || true)"
    # Prefer the newest plain (fast path); fall back to decrypt of newest .enc.
    if [[ -n "${newest_plain}" ]]; then echo "${newest_plain}"; return 0; fi
    if [[ -n "${newest_enc}" ]]; then echo "${newest_enc}"; return 0; fi
    echo "[restore-db] no backups found under ${DUMP_DIR}" >&2
    return 1
}

verify_manifest() {
    local dump="${1}"
    [ -f "${MANIFEST}" ] || return 0
    local base
    base="$(basename "${dump}")"
    local expected actual
    expected="$(grep -F "  ${base}" "${MANIFEST}" | awk '{print $1}' || true)"
    [ -n "${expected}" ] || return 0
    actual="$(sha256sum "${dump}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "[restore-db] SHA256 MISMATCH on ${base} (backups may be tampered)" >&2
        echo "  expected ${expected}" >&2
        echo "  actual   ${actual}" >&2
        return 1
    fi
    echo "[restore-db]    -> manifest OK: ${base}"
}

decrypt_if_needed() {
    local dump="${1}"
    case "${dump}" in
        *.dump.enc)
            local key hex out
            key="$(env_get BACKUP_KEY)"
            [ -n "${key}" ] || { echo "[restore-db] BACKUP_KEY missing from ${ENV_FILE}" >&2; exit 1; }
            hex="$(printf '%s' "${key}" | openssl dgst -sha256 | awk '{print $2}')"
            out="${dump%.enc}.restored.gz"
            openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
                -in "${dump}" -out "${out}" -pass "pass:${hex}"
            rm -f -- "${out}" # placeholder; we stream, keep this simple+atomic below
            printf '%s' "${out}" # signal: caller should use the stream fd instead
            ;;
        *) echo "${dump}" ;;
    esac
}

container_managed() {
    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
        exec -T "${POSTGRES_SERVICE}" \
        pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null 2>&1
}

stop_prod_writers() {
    # API/workers must be DOWN so no partial-state transactions race the restore.
    for svc in user-api bot-webhook-worker settlement-worker; do
        docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" stop "${svc}" >/dev/null 2>&1 || true
    done
}

if [ "${MODE}" = "list" ]; then
    newest="$(resolve_dump || exit 1)"
    verify_manifest "${newest}" || true
    if [[ "${newest}" == *.enc ]]; then
        echo "[restore-db] --list on ${newest}: decrypt + pg_restore --list"
        key="$(env_get BACKUP_KEY)"
        hex="$(printf '%s' "${key}" | openssl dgst -sha256 | awk '{print $2}')"
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
            -in "${newest}" -out /tmp/_restore_list.dump.gz -pass "pass:${hex}"
        docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
            exec -T "${POSTGRES_SERVICE}" \
            pg_restore --list /tmp/_restore_list.dump.gz 2>/dev/null | head -20
        rm -f /tmp/_restore_list.dump.gz
    else
        docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
            exec -T "${POSTGRES_SERVICE}" \
            pg_restore --list < <(cat "${newest}") 2>/dev/null | head -20
    fi
    exit 0
fi

dump="$(resolve_dump || { usage; exit 1; })"
verify_manifest "${dump}" || exit 1

[ "${RESTORE_POLICY}" = "safe" ] || EXTRA_ARGS+=("--force")
# Potential live-cluster check: refuse unless forced or API is already stopped.
if ! [[ " ${EXTRA_ARGS[*]} " == *" --force "* ]]; then
    if container_managed && docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" ps --status running \
        | grep -qE 'mm_prod_(user-api|bot-webhook-worker|settlement-worker)'; then
        echo "[restore-db] refuse: prod writers still running (set RESTORE_POLICY=safe doesn't bypass;)"
        echo "            stop them first or pass --force. This is money-data safety."
        exit 1
    fi
fi

echo "[restore-db] stopping prod writers (API/workers)..."
stop_prod_writers

RESTORE_FILE=/tmp/_restore.dump.gz
CREATE="DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
if [[ "${dump}" == *.enc ]]; then
    key="$(env_get BACKUP_KEY)"
    hex="$(printf '%s' "${key}" | openssl dgst -sha256 | awk '{print $2}')"
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
        -in "${dump}" -out "${RESTORE_FILE}" -pass "pass:${hex}"
else
    cp -- "${dump}" "${RESTORE_FILE}"
fi

echo "[restore-db] restore ${dump} → ${DB_NAME} (user=${DB_USER}) @ $(${date_cmd} -u +%Y%m%dT%H%M%SZ)"
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
    exec -T "${POSTGRES_SERVICE}" \
    sh -c "psql -v ON_ERROR_STOP=1 -U '${DB_USER}' -d '${DB_NAME}' -c \"${CREATE}\"; pg_restore --no-owner --no-privileges --clean -U '${DB_USER}' -d '${DB_NAME}' /tmp/_restore.dump.gz" \
    < /dev/null 2>&1 | tail -8

rm -f /tmp/_restore.dump.gz
echo "[restore-db] done. Restart stack: docker compose -f ${COMPOSE_FILE} --env-file ${ENV_FILE} up -d"
