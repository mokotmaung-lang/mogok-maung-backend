#!/usr/bin/env bash
# ==============================================================================
# restore-pitr.sh — Point-in-Time Recovery for ransomware / corruption events.
# Always restores into a NEW instance, never over the source, so forensics can
# snapshot the current (possibly compromised) state first without freezing it.
#
# Standard playbook:
#   1. aws rds create-db-snapshot (forensic copy of the "now" state)
#   2. run this script with the exact UTC second before the incident
#      (e.g. 2026-09-05T07:35:00Z)
#   3. validate ledger invariants on the recovered instance
#   4. cut over DNS / APP connection string to the recovered instance
#
# Usage:
#   AWS_PROFILE=prod ./scripts/dr/restore-pitr.sh \
#       myanmar-bet-prod-db 2026-09-05T07:35:00Z \
#       [target-db] [vpc-security-group] [db-subnet-group] [instance-class]
# ==============================================================================
set -euo pipefail

SRC="${1:?usage: restore-pitr.sh <source-db> <restore-time-utc> [target-db] [vpc-sg] [subnet-group] [instance-class]}"
RESTORE_TIME="$2"
TARGET="${3:-${SRC}-recovered}"
SG="${4:-}"
SUBNETS="${5:-}"
CLASS="${6:-}"

# Sanity gate: the requested timestamp MUST fall inside the retention window.
EARLIEST=$(aws rds describe-db-instances --db-instance-identifier "$SRC" \
  --query 'DBInstances[0].EarliestRestorableTime' --output text)
LATEST=$(aws rds describe-db-instances --db-instance-identifier "$SRC" \
  --query 'DBInstances[0].LatestRestorableTime' --output text)
echo ">> $SRC restorable window:  $EARLIEST -> $LATEST"
echo ">> Requested restore time:  $RESTORE_TIME"
if [[ -n "$EARLIEST" && -n "$LATEST" ]]; then
  if [[ "$RESTORE_TIME" < "$EARLIEST" || "$RESTORE_TIME" > "$LATEST" ]]; then
    echo "!! requested time is OUTSIDE the PITR window" >&2
    exit 1
  fi
fi

EXTRA=()
[[ -n "$SG" ]]      && EXTRA+=(--vpc-security-group-ids "$SG")
[[ -n "$SUBNETS" ]] && EXTRA+=(--db-subnet-group-name "$SUBNETS")
[[ -n "$CLASS" ]]   && EXTRA+=(--db-instance-class "$CLASS")

echo ">> Restoring $SRC -> $TARGET @ $RESTORE_TIME ..."
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "$SRC" \
  --target-db-instance-identifier "$TARGET" \
  --restore-time "$RESTORE_TIME" \
  --no-publicly-accessible \
  --auto-minor-version-upgrade \
  "${EXTRA[@]}"

echo ">> Waiting for $TARGET to reach 'available' ..."
aws rds wait db-instance-available --db-instance-identifier "$TARGET"

echo ">> Restore complete."
echo ">> 1) Validate money integrity before cutover:"
echo "      psql \"host=$TARGET ...\" < scripts/dr/verify-ledger.sql"
echo "      (must return ZERO mismatch rows)"
echo ">> 2) Smoke test: curl -fsS https://<elb>//health"
echo ">> 3) Cutover: repoint APP DB_HOST to $TARGET (or promote to primary)."