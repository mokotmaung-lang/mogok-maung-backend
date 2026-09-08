#!/usr/bin/env bash
# ==============================================================================
# ecr-push.sh — single-build, multi-tag push of the Mogok Maung API image.
#
# The root Dockerfile builds ALL THREE runtime binaries into one image
# (mogok-maung-api, mogok-maung-worker, mogok-maung-webhook); the compose
# override selects the binary with `command:`. So we build ONCE and re-tag the
# same artifact for worker + webhook, then push all three tags to ECR.
#
# Callers must authenticate the docker daemon to ECR FIRST:
#   GitHub Actions  -> aws-actions/amazon-ecr-login@v2
#   GitLab CI       -> aws ecr get-login-password ... | docker login --username AWS --password-stdin ...
#
# Usage:
#   ECR_REGISTRY=123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/mm-bet \
#     ./deploy/ecr-push.sh
# Overridable env: IMAGE_TAG (default latest-staging), IMAGE_NAME (default mogok-maung-api)
# ==============================================================================
set -euo pipefail

ECR_REGISTRY="${ECR_REGISTRY:?set ECR_REGISTRY (e.g. 123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/mm-bet)}"
IMAGE_TAG="${IMAGE_TAG:-latest-staging}"
IMAGE_NAME="${IMAGE_NAME:-mogok-maung-api}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

log() { echo "[INFO ] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

[[ -f "Dockerfile" ]] || die "no Dockerfile at repo root — run from the Go module root"

remote() { echo "$ECR_REGISTRY/$1:$IMAGE_TAG"; }

API_IMAGE="$(remote "$IMAGE_NAME")"
WORKER_IMAGE="$(remote mogok-maung-worker)"
WEBHOOK_IMAGE="$(remote mogok-maung-webhook)"

# 1. Build once (the runtime image already contains all three binaries).
log "Building $API_IMAGE (this may take a few minutes)"
docker build -t "$API_IMAGE" -f Dockerfile .

# 2. Re-tag the identical artifact for the worker and webhook services.
log "Tagging identical image -> worker + webhook"
docker tag "$API_IMAGE" "$WORKER_IMAGE"
docker tag "$API_IMAGE" "$WEBHOOK_IMAGE"

# 3. Push all three tags.
log "Pushing $API_IMAGE"
docker push "$API_IMAGE"
log "Pushing $WORKER_IMAGE"
docker push "$WORKER_IMAGE"
log "Pushing $WEBHOOK_IMAGE"
docker push "$WEBHOOK_IMAGE"

log "Done — $IMAGE_TAG image set is live in ECR"