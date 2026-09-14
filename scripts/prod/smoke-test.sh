#!/usr/bin/env bash
# ==============================================================================
# smoke-test.sh — post-deployment verification of the Mogok Maung API.
#
# 1. GET  /health                          -> 200 "ok"
# 2. POST /api/v1/auth/login for every role with its password
#      root     -> SUPER_ADMIN
#      agent01  -> AGENT
#      user01   -> USER
#    (roles come from mock_data.sql seeds; on a fresh production DB use the
#     accounts you created after scripts/prod/bootstrap-admin.sh.)
# 3. WS upgrade probe on /ws (expects 101; a 401/403 also proves the tunnel
#    wiring is in place).
#
# Usage:
#   DOMAIN_NAME=https://api.yourdomain.com \
#   SMOKE_PASSWORD='Staging123!' \
#   scripts/prod/smoke-test.sh
#
# Exits non-zero on the first failed check (usable in CI / post-deploy hooks).
# ==============================================================================
set -euo pipefail

BASE_URL=${DOMAIN_NAME:-https://api.yourdomain.com}
SMOKE_PASSWORD=${SMOKE_PASSWORD:-Staging123!}
# Space-separated "user:expected-role" pairs. Defaults mirror the dev seeds
# (mock_data.sql); override on a fresh production DB, e.g.
#   SMOKE_ROLES="superadmin:SUPER_ADMIN"
SMOKE_ROLES=${SMOKE_ROLES:-"root:SUPER_ADMIN agent01:AGENT user01:USER"}

JQ=${JQ:-jq}
HAVE_JQ=0
command -v "${JQ}" >/dev/null 2>&1 && HAVE_JQ=1

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1" >&2; exit 1; }

echo "== Mogok Maung smoke test — ${BASE_URL} =="

# --- 1. Health ----------------------------------------------------------------
echo "1) GET ${BASE_URL}/health"
HEALTH_BODY="$(curl -fsS --max-time 10 "${BASE_URL}/health" 2>/dev/null || true)"
if [ "${HEALTH_BODY}" = "ok" ]; then
    pass "health returned 'ok'"
else
    fail "health did not return 'ok' (got: '${HEALTH_BODY}')"
fi

# --- 2. Login per role ---------------------------------------------------------
# login prints the JSON body on stdout and returns non-zero when the HTTP
# status is anything other than 200 (works through command substitution: the
# exit status of the substitution is login's return status).
login() {
    local user=$1 password=$2
    local tmp code
    tmp="$(mktemp)"
    code="$(curl -s -o "${tmp}" -w '%{http_code}' --max-time 10 \
        -X POST "${BASE_URL}/api/v1/auth/login" \
        -H 'Content-Type: application/json' \
        --data "{\"username\":\"${user}\",\"password\":\"${password}\"}" || echo "000")"
    cat "${tmp}"
    rm -f "${tmp}"
    [ "${code}" = "200" ] || return 1
}

check_login() {
    local user=$1 expected_role=$2
    echo "2) login ${user} (expect role ${expected_role})"

    local body role code
    body="$(login "${user}" "${SMOKE_PASSWORD}")"
    code=$?
    if [ "${code}" -ne 0 ]; then
        fail "login ${user} returned non-200 (|${body})"
    fi

    if [ "${HAVE_JQ}" -eq 1 ]; then
        role="$(printf '%s' "${body}" | jq -r '.role // "MISSING"')"
    else
        role="$(printf '%s' "${body}" | sed -n 's/.*"role"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    fi

    if [ "${role}" = "${expected_role}" ]; then
        pass "${user} -> ${role}"
    else
        fail "${user} -> role '${role}' != expected '${expected_role}'"
    fi
}

for entry in ${SMOKE_ROLES}; do
    check_login "${entry%%:*}" "${entry##*:}"
done

# --- 3. WebSocket upgrade wiring -------------------------------------------------
echo "3) WS upgrade probe ${BASE_URL}/ws"
WS_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "${BASE_URL}/ws" || true)"
case "${WS_CODE}" in
    101)     pass "ws upgrade ok (http 101)" ;;
    401|403) pass "ws wired but handshake gated (http ${WS_CODE})" ;;
    2*)      pass "ws tunnel reachable (http ${WS_CODE})" ;;
    *)       fail "ws upgrade returned unexpected http ${WS_CODE}" ;;
esac

echo
echo "== All smoke checks passed =="