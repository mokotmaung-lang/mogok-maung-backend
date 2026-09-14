#!/usr/bin/env bash
# ==============================================================================
# setup-db-tls.sh — generate the self-signed PostgreSQL TLS certificate used by
# docker-compose.prod.yml (DB_SSLMODE=require enforces full-link encryption for
# the API/worker/webhook -> postgres connections on the internal bridge).
#
# The bundled stack verifies NOTHING server-side (sslmode=require, not
# verify-full): key rotation + secrets rotate with the volume. For an
# externally-attestable chain, replace ./secrets/pg-tls/server.{crt,key} with a
# real CA pair at the same paths and restart the postgres container.
#
# RUN ONCE before the first `docker compose -f docker-compose.prod.yml up -d`.
# Requires openssl. Re-running just regenerates the pair (idempotent).
# ==============================================================================
set -euo pipefail

TLS_DIR=${TLS_DIR:-secrets/pg-tls}
mkdir -p "${TLS_DIR}"

now() { date +%Y%m%d%H%M%SZ; }

echo "[tls] creating self-signed postgres cert in ${TLS_DIR} ..."
openssl req -new -x509 \
    -days 3650 \
    -nodes \
    -newkey rsa:4096 \
    -keyout "${TLS_DIR}/server.key" \
    -out "${TLS_DIR}/server.crt" \
    -subj "/CN=postgres-db/O=MogokMaung/OU=Production" \
    -addext "subjectAltName=DNS:postgres-db,IP:127.0.0.1" \
    >/dev/null 2>&1

chmod 600 "${TLS_DIR}/server.key"

echo "[tls] done — ${TLS_DIR}/server.crt + server.key written ($(now))"
echo "[tls] start postgres, then the API uses DB_SSLMODE=require automatically."