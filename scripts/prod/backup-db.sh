#!/usr/bin/env bash
# ==============================================================================
# backup-db.sh — automated PostgreSQL backups for the Mogok Maung production VPS.
#
# Runs inside the postgres container (local socket = trust auth, TLS not needed)
# and writes a time-stamped, custom-format (compressed) pg_dump to the host,
# then rotates old backups and keeps a sha256 manifest. Optionally encrypts a
# copy with BACKUP_KEY (loaded from .env.production, generated on first run).
#
# Usage:
#   bash scripts/prod/backup-db.sh [--keep N] [--no-enc] [--install-cron] [--list]
#
#   --keep N        retention: keep newest N dumps (default 14)
#   --no-enc        skip the AES-256 encrypted copy (plain .gz.dump only)
#   --install-cron  (re)install the systemd-less crontab entry (idempotent)
#   --list          just print current backups (no dump)
#
# Safe to re-run anytime; never touches the running containers other than an
# in-container pg_dump. Follows scripts/prod style — reads real secrets from
# .env.production, never hardcodes them.
# ==============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${REPO_DIR}/.env.production"
COMPOSE_FILE="docker-compose.prod.yml"
POSTGRES_SERVICE="postgres-db"
BACKUP_ROOT="${BACKUP_ROOT:-${REPO_DIR}/backups}"
KEEP=14
ENCRYPT=1
MODE="run"

for a in "$@"; do
    case "${a}" in
        --no-enc)         ENCRYPT=0 ;;
        --install-cron)   MODE="cron" ;;
        --list)           MODE="list" ;;
        --keep)           continue ;;                 # two-arg: value is next token
        --keep=*)         KEEP="${a#*=}" ;;
        --*)              echo "unknown arg: ${a}"; exit 1 ;;
        *)                if [[ "${KEEP_ARG:-0}" = "1" ]]; then
                              KEEP="${a}"; KEEP_ARG=0
                          else
                              echo "unknown arg: ${a}"; exit 1
                          fi ;;
    esac
    # mark that the NEXT positional is the value for a bare --keep
    [[ "${a}" = "--keep" ]] && KEEP_ARG=1
done
[ -z "${KEEP_ARG:-}" ] || KEEP_ARG=0
[ -n "${KEEP:-}" ] || KEEP=14

[ -f "${ENV_FILE}" ] || { echo "[backup-db] missing ${ENV_FILE} — run go-live.sh first"; exit 1; }

# load_valuables from the FERAS .env.production (never source it — it may
# contain arbitrary characters; we grab keys exactly).
env_get() { # $1=key
    grep -E "^${1}=" "${ENV_FILE}" | tail -1 | cut -d= -f2- || true
}

DB_USER="$(env_get DB_USER)"
DB_NAME="$(env_get DB_NAME)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${BACKUP_ROOT}/postgres"
DUMP_BASE="mm_bet_${DB_NAME}_${STAMP}"
DUMP_GZ="${BACKUP_DIR}/${DUMP_BASE}.dump.gz"
MANIFEST="${BACKUP_DIR}/MANIFEST.sha256"

mkdir -p "${BACKUP_DIR}"

# --------------------------------------------------------------------------- #
# mode=list
# --------------------------------------------------------------------------- #
if [ "${MODE}" = "list" ]; then
    echo "[backup-db] $([ -d "${BACKUP_DIR}" ] && find "${BACKUP_DIR}" -name '*.dump.gz' | wc -l || echo 0) local backups under ${BACKUP_DIR}:"
    [ -d "${BACKUP_DIR}" ] && ls -lh "${BACKUP_DIR}"/*.dump.gz 2>/dev/null || true
    exit 0
fi

# --------------------------------------------------------------------------- #
# mode=cron — install a daily entry (02:30 UTC) idempotently
# --------------------------------------------------------------------------- #
if [ "${MODE}" = "cron" ]; then
    CRON_LINE="30 2 * * * cd ${REPO_DIR} && bash scripts/prod/backup-db.sh --keep ${KEEP} >> ${BACKUP_ROOT}/backup-db.log 2>&1"
    crontab -l 2>/dev/null | grep -Fv "scripts/prod/backup-db.sh" | { cat; echo "${CRON_LINE}"; } | crontab -
    echo "[backup-db] cron installed: ${CRON_LINE}"
    echo "[backup-db] log at ${BACKUP_ROOT}/backup-db.log"
    exit 0
fi

# --------------------------------------------------------------------------- #
# mode=run — snapshot + encrypt + rotate + manifest
# --------------------------------------------------------------------------- #
echo "[backup-db] pg_dump (${POSTGRES_SERVICE}, db=${DB_NAME}, user=${DB_USER}) @ ${STAMP}"

docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" exec -T "${POSTGRES_SERVICE}" \
    pg_dump -U "${DB_USER}" -d "${DB_NAME}" \
        --format=custom --compress=9 --no-owner --no-privileges \
        > "${DUMP_GZ}"

# Integrity sanity: confirm the gzip header + pg_restore can list it.
gzip -t "${DUMP_GZ}"
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" exec -T "${POSTGRES_SERVICE}" \
    pg_restore --list < "${DUMP_GZ}" | head -5 >/dev/null && echo "[backup-db]      -> pg_restore --list OK"
SIZE="$(du -h "${DUMP_GZ}" | cut -f1)"

# Optional AES-256 copy (BACKUP_KEY from .env.production; generate if missing).
if [ "${ENCRYPT}" = "1" ]; then
    BACKUP_KEY="${BACKUP_KEY:-$(env_get BACKUP_KEY)}"
    if [ -z "${BACKUP_KEY}" ]; then
        BACKUP_KEY="$(openssl rand -base64 32)"
        if grep -qE '^BACKUP_KEY=' "${ENV_FILE}"; then
            sed -i "s|^BACKUP_KEY=.*|BACKUP_KEY=${BACKUP_KEY}|" "${ENV_FILE}"
        else
            printf 'BACKUP_KEY=%s\n' "${BACKUP_KEY}" >> "${ENV_FILE}"
        fi
        chmod 600 "${ENV_FILE}"
        echo "[backup-db]      -> generated BACKUP_KEY into ${ENV_FILE}"
    fi
    DUMP_ENC="${BACKUP_DIR}/${DUMP_BASE}.dump.enc"
    KEY_HEX="$(printf '%s' "${BACKUP_KEY}" | openssl dgst -sha256 | awk '{print $2}')"
    openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
        -in "${DUMP_GZ}" -out "${DUMP_ENC}" -pass "pass:${KEY_HEX}"
    chmod 600 "${DUMP_ENC}"
    echo "[backup-db]      -> encrypted copy ${DUMP_ENC} (${SIZE})"
fi

chmod 600 "${DUMP_GZ}"

# Manifest (append).
(
    printf '%s  %s\n' "$(sha256sum "${DUMP_GZ}" | awk '{print $1}')" "$(basename "${DUMP_GZ}")"
    [ "${ENCRYPT}" = "1" ] && printf '%s  %s\n' "$(sha256sum "${DUMP_ENC}" | awk '{print $1}')" "$(basename "${DUMP_ENC}")"
) >> "${MANIFEST}"

# Rotation: drop backups older than the newest N.
mapfile -t OLD < <(find "${BACKUP_DIR}" -name '*.dump.*' -type f 2>/dev/null | sort -r | tail -n +$((KEEP + 1)) || true)
for f in "${OLD[@]}"; do
    rm -f -- "${f}"
    echo "[backup-db]      -> rotated out $(basename "${f}")"
done

echo "[backup-db] done: ${DUMP_GZ} (${SIZE}) — retention=${KEEP}"
echo "[backup-db] restore: bash scripts/prod/restore-db.sh ${DUMP_GZ}"
