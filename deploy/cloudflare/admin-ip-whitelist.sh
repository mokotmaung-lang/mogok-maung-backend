#!/usr/bin/env bash
# ==============================================================================
# admin-ip-whitelist.sh — deploy a Cloudflare WAF Custom Rule that blocks the
# administrative control plane from the public internet.
#
# Expression (WAF custom-rule syntax):
#   (any(http.request.uri.path starts_with {"/api/v1/admin/" "/api/v1/agent/"}))
#   and not any(ip.src in {<whitelisted CIDRs>})
#
# Rule intent (from the security spec):
#   Any public request targeting /api/v1/admin/* or /api/v1/agent/* whose
#   origin IP is NOT one of the designated corporate static blocks is BLOCKED
#   at the Cloudflare edge — before it ever reaches nginx or the Go API.
#
# Whitelist is supplied through the environment (never committed):
#   export ADMIN_WHITELIST="203.81.10.0/24 111.84.3.200/32"
#
# Usage:
#   export CF_API_TOKEN=... CF_ZONE_ID=... ADMIN_WHITELIST="203.81.10.0/24"
#   ./deploy/cloudflare/admin-ip-whitelist.sh [deploy|--undo]
# ==============================================================================
set -euo pipefail

CF_API_TOKEN="${CF_API_TOKEN:?put CF_API_TOKEN env}"
CF_ZONE_ID="${CF_ZONE_ID:?put CF_ZONE_ID env}"
ADMIN_WHITELIST="${ADMIN_WHITELIST:?set ADMIN_WHITELIST to the corporate IP CIDRs}"

RULESET="/client/v4/zones/${CF_ZONE_ID}/rulesets/phases/http_request_firewall_custom/entrypoint"
API="https://api.cloudflare.com/client/v4"

# "203.0.113.0/24 198.51.100.0/32" -> {203.0.113.0/24 198.51.100.0/32}
CF_CIDR_LIST=$(echo "${ADMIN_WHITELIST}" | xargs)

RULE_JSON=$(cat <<JSON
[{
  "expression": "(any(http.request.uri.path starts_with {\"/api/v1/admin/\" \"/api/v1/agent/\"})) and not any(ip.src in {${CF_CIDR_LIST}})",
  "description": "MGM control plane: block /api/v1/admin/* and /api/v1/agent/* unless origin IP is whitelisted",
  "action": "block"
}]
JSON
)

case "${1:-deploy}" in
  deploy)
    echo ">> Deploying WAF custom rule (whitelist: ${CF_CIDR_LIST}) ..."
    curl -fsS -X PUT "$API$RULESET" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "{\"description\":\"MGM control-plane IP whitelist\",\"kind\":\"zone\",\"phase\":\"http_request_firewall_custom\",\"rules\":$RULE_JSON}"
    ;;
  --undo)
    echo ">> Removing all MGM control-plane WAF rules ..."
    curl -fsS -X DELETE "$API$RULESET" \
      -H "Authorization: Bearer $CF_API_TOKEN"
    ;;
  *)
    echo "usage: $0 [deploy|--undo]" >&2
    exit 1
    ;;
esac