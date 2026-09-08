#!/usr/bin/env bash
# ==============================================================================
# rate-limit.sh — deploy the Cloudflare WAF rate-limit rule for the USER API.
#
# Rule (from the spec):
#   Expression: (http.request.uri.path startswith "/api/v1/user/")
#   Rate:       100 requests / 1 minute per IP
#   Action:     Block
# Sympathetic to the mobile app's live-odds polling, but brutal to scrapers
# and cheap botnets hammering /api/v1/user/*.
#
# Pure admin dashboards are NOT covered here — they are IP-whitelisted at nginx
# (deploy/nginx/conf.d/admin-dashboard.conf) so WAF can't be tricked by it.
#
# Usage:
#   export CF_API_TOKEN=... CF_ZONE_ID=...
#   ./deploy/cloudflare/rate-limit.sh [--undo]
# ==============================================================================
set -euo pipefail

CF_API_TOKEN="${CF_API_TOKEN:?put CF_API_TOKEN env}"
CF_ZONE_ID="${CF_ZONE_ID:?put CF_ZONE_ID env}"
RATE_PER_MIN=100
WINDOW_SECONDS=60
MITIGATION_SECONDS=300   # 5-minute temporary block per spec
RULESET="/client/v4/zones/${CF_ZONE_ID}/rulesets/phases/http_ratelimit/entrypoint"
API="https://api.cloudflare.com/client/v4"

RULE_JSON=$(cat <<JSON
[{
  "expression": "(http.request.uri.path starts with \"/api/v1/user/\")",
  "description": "MGM user API: ${RATE_PER_MIN} req/min per IP -> block ${MITIGATION_SECONDS}s",
  "action": "block",
  "ratelimit": {
    "characteristics": ["ip.src"],
    "period": ${WINDOW_SECONDS},
    "requests_per_period": ${RATE_PER_MIN},
    "mitigation_timeout": ${MITIGATION_SECONDS}
  }
}]
JSON
)

case "${1:-deploy}" in
  deploy)
    echo ">> Deploying rate-limit rule (${RATE_PER_MIN}/${WINDOW_SECONDS}s -> block ${MITIGATION_SECONDS}s) ..."
    curl -fsS -X PUT "$API$RULESET" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "{\"description\":\"MGM user API rate limits\",\"kind\":\"zone\",\"phase\":\"http_ratelimit\",\"rules\":$RULE_JSON}"
    ;;
  --undo)
    echo ">> Removing all MGM user-API rate-limit rules ..."
    curl -fsS -X DELETE "$API$RULESET" \
      -H "Authorization: Bearer $CF_API_TOKEN"
    ;;
  *)
    echo "usage: $0 [deploy|--undo]" >&2
    exit 1
    ;;
esac