# ==============================================================================
# Multi-stage Dockerfile — minimal, non-root, statically-linked Go API image.
#
# The repository root IS the Go module; the API entrypoint lives at ./cmd/api
# (NOT a module-local ./user-service). go.sum may not be committed yet, so the
# builder pins nothing and relies on `go mod download` to materialise it.
#
# Build:   docker build -t mogok-maung-api .
# ==============================================================================

# ---- Stage 1: compile -------------------------------------------------------
FROM golang:1.23-alpine AS builder

WORKDIR /app

# Layer-cache the module graph first (source rarely changes, deps change less).
ENV GOFLAGS=-mod=mod
COPY go.mod ./
RUN go mod download

# Now the source.
COPY . .

# Static binary: CGO_ENABLED=0 keeps the image free of libc/glibc surprises on
# Alpine, -trimpath strips build machine paths from panic traces, and -s -w
# strips symbol/debug tables (smaller + harder to reverse).
RUN CGO_ENABLED=0 GOOS=linux \
    go build -trimpath -ldflags="-s -w" \
    -o /out/mogok-maung-api ./cmd/api \
 && CGO_ENABLED=0 GOOS=linux \
    go build -trimpath -ldflags="-s -w" \
    -o /out/mogok-maung-worker ./cmd/worker \
 && CGO_ENABLED=0 GOOS=linux \
    go build -trimpath -ldflags="-s -w" \
    -o /out/mogok-maung-webhook ./cmd/webhook

# ---- Stage 2: runtime -------------------------------------------------------
FROM alpine:3.20

# Migrations + MIGRATIONS_DIR are relative to /app (see the ENV below and the
# `COPY --from=builder /app/migrations ./migrations` line).
WORKDIR /app

# ca-certificates: copied from the builder instead of `apk add`, because
# Alpine's dl-cdn mirror is unreachable on some build networks (observed from
# MY). tzdata is deliberately NOT bundled: containers run UTC and the app
# emits UTC timestamps with MMT offset handled in application code.
RUN addgroup -S app \
    && adduser -S -G app app

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

COPY --from=builder /out/mogok-maung-api /usr/local/bin/mogok-maung-api
COPY --from=builder /out/mogok-maung-worker /usr/local/bin/mogok-maung-worker
COPY --from=builder /out/mogok-maung-webhook /usr/local/bin/mogok-maung-webhook
# Versioned SQL migrations are auto-applied at container start (AUTO_MIGRATE).
COPY --from=builder /app/migrations ./migrations

USER app

EXPOSE 8080

ENV AUTO_MIGRATE=true \
    MIGRATIONS_DIR=./migrations

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health >/dev/null 2>&1 || exit 1

CMD ["mogok-maung-api"]