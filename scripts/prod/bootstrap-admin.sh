#!/usr/bin/env bash
# ==============================================================================
# bootstrap-admin.sh — create the first SUPER_ADMIN on a production database.
#
# Ordering matters: the schema is applied by the API's auto-migrator at first
# boot (AUTO_MIGRATE=true, migrations/ applied in version order), so this runs
# AFTER the API reports /health OK. On an already-migrated database it is a
# no-op when a SUPER_ADMIN exists (the seeder is idempotent).
#
# Usage:
#   export BOOT_ADMIN_USER=superadmin BOOT_ADMIN_PASS='<at-least-8-chars>'
#   scripts/prod/bootstrap-admin.sh
#
# The docker-compose.prod.yml binds ./database/seeders to /seeders:ro inside
# the postgres container; db credentials come from .env.production.
# ==============================================================================
set -euo pipefail

ENV_FILE=${ENV_FILE:-.env.production}
COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.prod.yml}
SERVICE=${POSTGRES_SERVICE:-postgres-db}

# Bring DB_USER/DB_NAME (and everything else) in from the prod env file when not
# already exported on the command line.
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1091
    source "${ENV_FILE}"
    set +a
fi

: "${BOOT_ADMIN_USER:?set BOOT_ADMIN_USER}"
: "${BOOT_ADMIN_PASS:?set BOOT_ADMIN_PASS (min 8 chars)}"
: "${DB_USER:?set DB_USER in ${ENV_FILE}}"
: "${DB_NAME:?set DB_NAME in ${ENV_FILE}}"

echo "[bootstrap] seeding SUPER_ADMIN '${BOOT_ADMIN_USER}' (idempotent)..."
docker compose \
    --file "${COMPOSE_FILE}" \
    --env-file "${ENV_FILE}" \
    exec -T "${SERVICE}" \
    psql -v ON_ERROR_STOP=1 -U "${DB_USER}" -d "${DB_NAME}" \
    -v "boot_user=${BOOT_ADMIN_USER}" -v "boot_pass=${BOOT_ADMIN_PASS}" \
    -f /seeders/001_bootstrap_admin.sql

echo "[bootstrap] done — SUPER_ADMIN is ready (must_change_password=true forces password rotation on first login)."