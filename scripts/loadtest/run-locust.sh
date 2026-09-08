#!/usr/bin/env bash
# ==============================================================================
# run-locust.sh — distributed Locust executor targeting the production-grade
# benchmarks from the load-test spec:
#     20,000 concurrent users  |  API p95 < 200ms  |  error rate < 0.1%
#
# Distributed mode: one master + N workers spread across machines/cores so the
# load generators themselves never become the bottleneck. Run the master on a
# cheap box, workers on separate instances (or local cores).
#
# Usage (distributed):
#   AWS/UAT env prepped, then:
#   MGM_BASE_URL=https://staging.example.com \
#   MGM_TEST_USERNAMES="u1,u2,..." MGM_TEST_PASSWORD=... \
#   ./scripts/loadtest/run-locust.sh --distributed
#
# Usage (local smoke):
#   ./scripts/loadtest/run-locust.sh --local
# ==============================================================================
set -euo pipefail

MODE="${1:---local}"
TARGET_URL="${MGM_BASE_URL:?set MGM_BASE_URL (e.g. https://staging.example.com)}"
USERS="${LOCUST_USERS:-20000}"
RAMP="${LOCUST_SPAWN_RATE:-800}"          # users/sec — keep below capacity
RUNTIME="${LOCUST_RUNTIME:-30m}"
WORKERS="${LOCUST_WORKERS:-3}"
HOST_IP="${LOCUST_MASTER_IP:-127.0.0.1}"
PY="python3"

echo ">> Target: ${USERS} concurrent users @ ${TARGET_URL}"
echo ">> Spike ramp: ${RAMP} users/sec, run for ${RUNTIME}"

case "$MODE" in
  --local)
    $PY -m locust -f loadtest/locustfile.py --host "$TARGET_URL" \
      -u "$USERS" -r "$RAMP" -t "$RUNTIME" \
      --csv loadtest/run --html loadtest/report.html
    ;;
  --distributed)
    echo ">> Starting master on :8089 ..."
    $PY -m locust -f loadtest/locustfile.py --host "$TARGET_URL" --master \
      --master-bind-host=0.0.0.0 --master-bind-port=5557 \
      -u "$USERS" -r "$RAMP" -t "$RUNTIME" \
      --csv loadtest/run --html loadtest/report.html &
    MASTER_PID=$!

    echo ">> Starting ${WORKERS} workers -> ${HOST_IP}:5557 ..."
    WORKER_PIDS=()
    for i in $(seq 1 "$WORKERS"); do
      $PY -m locust -f loadtest/locustfile.py --worker \
        --master-host "$HOST_IP" --master-port=5557 &
      WORKER_PIDS+=("$!")
    done

    trap 'kill ${MASTER_PID} ${WORKER_PIDS[*]} 2>/dev/null || true' EXIT
    wait $MASTER_PID
    echo ">> Done. Reports: loadtest/run_{stats,history}.csv , report.html"
    ;;
  *)
    echo "usage: $0 [--local|--distributed]" >&2
    exit 1
    ;;
esac