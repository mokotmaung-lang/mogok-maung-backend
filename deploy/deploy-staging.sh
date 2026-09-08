#!/usr/bin/env bash
# ==============================================================================
# deploy-staging.sh — automated Staging deployment for the Mogok Maung platform.
#
# Spins up the full stack on an AWS EC2 host using Docker Compose backed by
# ECR images, then seeds sample data so the environment is testable at once.
#
# Image / service mapping (see docker-compose.staging.yml):
#   user-service          -> mogok-maung-api     (serves /api/v1/user|admin|agent)
#   admin-service (spec)  -> mogok-maung-api     (admin routes live in the API)
#   bet-settlement-worker -> mogok-maung-worker  (RabbitMQ settlement consumer)
#   bot-webhook-worker    -> mogok-maung-webhook (Viber/Telegram deposits :8090)
#
# Preconditions:
#   * docker + docker compose (>= 2.20) and the aws CLI installed
#   * AWS credentials with ECR:GetAuthorizationToken + GetDownloadUrlForLayer
#   * .env present at repo root, or export POSTGRES_PASSWORD/JWT_SECRET
#
# Usage:
#   export ECR_REGISTRY=123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/mm-bet
#   ./deploy/deploy-staging.sh
# Overridable env: AWS_REGION, IMAGE_TAG, STAGE_ENV, HEALTH_URL, DB_USER, DB_NAME
# ==============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (decent defaults, all overridable; never bake in secrets)
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_REGISTRY="${ECR_REGISTRY:?set ECR_REGISTRY (e.g. 123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/mm-bet)}"
IMAGE_TAG="${IMAGE_TAG:-latest-staging}"
STAGE_ENV="${STAGE_ENV:-staging}"

DB_USER="${DB_USER:-bet_admin}"
DB_NAME="${DB_NAME:-myanmar_bet_prod}"

HEALTH_URL="${HEALTH_URL:-http://localhost:8080/api/v1/health}"
HEALTH_RETRIES="${HEALTH_RETRIES:-5}"
HEALTH_SLEEP="${HEALTH_SLEEP:-5}"

SEED_FILE="database/seeders/mock_data.sql"
COMPOSE_FILE_BASE="docker-compose.yml"
COMPOSE_FILE_OVERRIDE="docker-compose.staging.yml"
COMPOSE_ARGS=(-f "$COMPOSE_FILE_BASE" -f "$COMPOSE_FILE_OVERRIDE")

# Images force-pulled from ECR for this deployment.
PULL_IMAGES=(mogok-maung-api mogok-maung-worker mogok-maung-webhook)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Helpers — descriptive, timestamped logging on stdout/stderr.
# ---------------------------------------------------------------------------
log()  { echo "[$(date -u +%FT%TZ)] [INFO ] $*"; }
warn() { echo "[$(date -u +%FT%TZ)] [WARN ] $*" >&2; }
die()  { echo "[$(date -u +%FT%TZ)] [ERROR] $*" >&2; exit 1; }

version_ge() { # version_ge "2.27.1" "2.20" -> 0 when v1 >= v2
  local IFS=.
  local -a v1=($1) v2=($2)
  for i in 0 1 2; do
    local a="${v1[$i]:-0}" b="${v2[$i]:-0}"
    (( a > b )) && return 0
    (( a < b )) && return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# 1. Prerequisites & environment
# ---------------------------------------------------------------------------
section() { log "=== $* ==="; }

section "Prerequisites & environment ($STAGE_ENV / $AWS_REGION)"

for tool in docker aws curl; do
  command -v "$tool" >/dev/null 2>&1 \
    || die "required tool '$tool' not found on PATH — install it before deploying"
done
log "Tools present: docker, aws, curl"

# Compose (<=> v2 plugin) is required; check for the standalone v1 binary too.
if docker compose version >/dev/null 2>&1; then
  COMPOSE_VERSION="$(docker compose version --short | sed 's/^v//')"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_VERSION="$(docker-compose version --short 2>/dev/null | sed -n 's/^v\{0,1\}\([0-9.]*\).*/\1/p' || true)"
  die "docker-compose (v1) detected — deploy script needs the 'docker compose' plugin (v2)"
else
  die "docker compose plugin not found — install Docker Compose v2"
fi

if ! version_ge "$COMPOSE_VERSION" "2.20"; then
  die "Docker Compose $COMPOSE_VERSION is too old — 'build: !reset' needs >= 2.20"
fi
log "Docker Compose v$COMPOSE_VERSION (>= 2.20 required OK)"

# Load .env (compose reads it too); required secret validation happens here.
if [[ -f ".env" ]]; then
  log "Loading .env"
  set -a; # shellcheck disable=SC1091
  source ".env"; set +a
else
  warn "No .env found — expecting POSTGRES_PASSWORD / JWT_SECRET in the environment"
fi
[[ -n "${POSTGRES_PASSWORD:-}" ]] || die "POSTGRES_PASSWORD is not set (put it in .env or export it)"
[[ -n "${JWT_SECRET:-}" ]]          || die "JWT_SECRET is not set (put it in .env or export it)"
log "Secrets validated: POSTGRES_PASSWORD, JWT_SECRET"

[[ -n "$ECR_REGISTRY" ]] || die "ECR_REGISTRY must be a non-empty registry URL"

# The staging override must exist and parse before we touch anything.
[[ -f "$COMPOSE_FILE_OVERRIDE" ]] || die "missing $COMPOSE_FILE_OVERRIDE"
[[ -f "$SEED_FILE" ]]             || die "missing seed file $SEED_FILE (cannot seed staging)"
docker compose "${COMPOSE_ARGS[@]}" config --quiet \
  || die "docker compose config validation failed (check overrides/env)"

# ---------------------------------------------------------------------------
# 2. ECR authentication & image retrieval
# ---------------------------------------------------------------------------
section "ECR authentication & image pull ($ECR_REGISTRY, tag $IMAGE_TAG)"

log "Logging the Docker daemon into ECR ($AWS_REGION)"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null \
  || die "ECR login failed — verify AWS credentials/region and ECR access"

for image in "${PULL_IMAGES[@]}"; do
  remote="$ECR_REGISTRY/$image:$IMAGE_TAG"
  for attempt in 1 2; do
    log "Pulling $remote (attempt $attempt/2)"
    if docker pull "$remote"; then break; fi
    (( attempt == 2 )) && die "failed to pull $remote after 2 attempts"
    warn "Pull failed — retrying in 5s"
    sleep 5
  done
done
log "All staging images present locally"

# ---------------------------------------------------------------------------
# 3. Orchestrated application launch
# ---------------------------------------------------------------------------
section "Launching stack (down -v -> up -d --build)"

log "Stopping and removing any previous containers + volumes (down -v)"
docker compose "${COMPOSE_ARGS[@]}" down -v --remove-orphans \
  || warn "compose down reported a problem (continuing)"

log "Starting the stack: docker compose up -d --build"
docker compose "${COMPOSE_ARGS[@]}" up -d --build \
  || die "stack failed to start — run: docker compose ${COMPOSE_ARGS[*]} logs"

# ---------------------------------------------------------------------------
# 4. Health-check retry loop (max 5 x 5s against /api/v1/health)
# ---------------------------------------------------------------------------
section "Waiting for backend health ($HEALTH_URL)"

healthy=false
for i in $(seq 1 "$HEALTH_RETRIES"); do
  if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    log "Backend is healthy (attempt $i/$HEALTH_RETRIES)"
    healthy=true
    break
  fi
  warn "Backend not healthy yet (attempt $i/$HEALTH_RETRIES) — retrying in ${HEALTH_SLEEP}s"
  sleep "$HEALTH_SLEEP"
done

if [[ "$healthy" != true ]]; then
  warn "Backend still unhealthy after ${HEALTH_RETRIES} attempts"
  echo "----- recent user-service logs -----" >&2
  docker compose "${COMPOSE_ARGS[@]}" logs --no-color --tail=50 user-service || true
  die "health check failed — see logs above"
fi

# ---------------------------------------------------------------------------
# 5. Automated database seeding (staging sync)
# ---------------------------------------------------------------------------
section "Seeding sample data ($SEED_FILE)"

postgres_cid="$(docker compose "${COMPOSE_ARGS[@]}" ps -q postgres-db)"
[[ -n "$postgres_cid" ]] || die "postgres-db container not running"
[[ -n "${POSTGRES_PASSWORD}" ]] || die "POSTGRES_PASSWORD missing for seeding"

log "Streaming $SEED_FILE into $DB_NAME (user: $DB_USER)"
docker exec -i -e "PGPASSWORD=$POSTGRES_PASSWORD" "$postgres_cid" \
  psql -v ON_ERROR_STOP=1 -q \
  -U "$DB_USER" -d "$DB_NAME" -f - < "$SEED_FILE" \
  || die "database seeding failed (schema migrated? psql in image?)"
log "Seeding completed successfully"

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
section "Deployment complete"
docker compose "${COMPOSE_ARGS[@]}" ps
echo
log "Stack is live:"
log "  User/Admin/Agent API        -> http://localhost:8080/api/v1/health"
log "  Bot webhook worker          -> http://localhost:8090"
log "  Seed logins (password Staging123!): root, admin01, agent01, user01"
log "Done ($STAGE_ENV)."