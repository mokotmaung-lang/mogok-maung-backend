#!/usr/bin/env bash
# ==============================================================================
# under-attack.sh — toggle Cloudflare "Under Attack Mode" (JavaScript
# challenge) during big-match days / botnet DDoS events.
#
# When enabled, Cloudflare serves a browser JS challenge before any request
# reaches origin (or WAF) — floods from non-browser bots are dropped before
# they can touch the Go API, DB, or WebSocket gateway.
#
# NOTE: under-attack challenges every visitor including mobile WebSocket
# backlog, so only enable during an actual attack window.
#
# Usage:
#   export CF_API_TOKEN=... CF_ZONE_ID=...
#   ./deploy/cloudflare/under-attack.sh on|off
# ==============================================================================
set -euo pipefail

CF_API_TOKEN="${CF_API_TOKEN:?put CF_API_TOKEN env}"
CF_ZONE_ID="${CF_ZONE_ID:?put CF_ZONE_ID env}"
API="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/settings/security_level"

case "${1:-}" in
  on)
    echo ">> ENABLING Under Attack Mode (JS challenge for all visitors) ..."
    curl -fsS -X PATCH "$API" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data '{"value":"under_attack"}'
    ;;
  off)
    echo ">> Disabling Under Attack Mode ..."
    curl -fsS -X PATCH "$API" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data '{"value":"high"}'
    ;;
  *) echo "usage: $0 on|off" >&2; exit 1 ;;
esac