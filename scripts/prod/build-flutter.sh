#!/usr/bin/env bash
# ==============================================================================
# build-flutter.sh — production Flutter builds (Web release + Android AAB).
#
# Domain is injected via --dart-define (compile-time) so the binaries point at
# the production API. For the systemd/nginx path, API_BASE_URL is the public
# HTTPS origin and WS_BASE_URL its wss:// twin — both reverse-proxied by
# deploy/nginx/prod/nginx.conf.
#
# NOTE: an Android AAB needs the Android SDK + signing config:
#   - android/key.properties with storeFile/storePassword/keyAlias/keyPassword
#   - run from the mobile/ directory on a machine with the SDK installed
#   (GitLab/GitHub release pipelines usually own this step.)
# ==============================================================================
set -euo pipefail

DOMAIN=${DOMAIN:-api.oddsmyanmar.online}
API_BASE_URL=${API_BASE_URL:-"https://${DOMAIN}"}
WS_BASE_URL=${WS_BASE_URL:-"wss://${DOMAIN}"}
MOBILE_DIR="${MOBILE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../mobile" && pwd)}"

cd "${MOBILE_DIR}"

echo "[flutter] preflight..."
flutter pub get

echo "[flutter] Web release build..."
flutter build web --release \
    --dart-define=API_BASE_URL="${API_BASE_URL}" \
    --dart-define=WS_BASE_URL="${WS_BASE_URL}"

echo "[flutter] Web output: build/web (deploy to your static host / nginx)"

echo "[flutter] Android App Bundle (AAB) release build..."
flutter build appbundle --release \
    --dart-define=API_BASE_URL="${API_BASE_URL}" \
    --dart-define=WS_BASE_URL="${WS_BASE_URL}"

echo "[flutter] AAB output: build/app/outputs/bundle/release/app-release.aab"