#!/usr/bin/env bash
# ==============================================================================
# enable-pitr.sh — turns a production RDS PostgreSQL instance into a
# Point-in-Time-Recovery (PITR) source:
#   * continuous WAL archiving (managed by RDS -> S3 automatically when the
#     backup retention period > 0), restorable to any second in the window
#   * daily automated full snapshot (preferred window off-peak, 03:00)
#   * Multi-AZ synchronous standby (zero-data-loss tier for money-ledger rows)
#   * accidental-deletion protection
#
# Usage:
#   AWS_PROFILE=prod ./scripts/dr/enable-pitr.sh myanmar-bet-prod-db [retention_days]
#
#   retention_days: 7 (default) or 30 for compliance/forensics retention.
#   This scales your storage cost; the S3 WAL archive grows with write volume.
# ==============================================================================
set -euo pipefail

INSTANCE_ID="${1:?usage: enable-pitr.sh <db-instance-identifier> [retention_days=7]}"
RETENTION="${2:-7}"

if ! [[ "$RETENTION" =~ ^([7-9]|[1-2][0-9]|3[0-5])$ ]]; then
  echo "retention_days must be 7..35" >&2
  exit 1
fi

echo ">> Enabling PITR-grade backup on '$INSTANCE_ID' (retention=${RETENTION}d) ..."
aws rds modify-db-instance \
  --db-instance-identifier "$INSTANCE_ID" \
  --backup-retention-period "$RETENTION" \
  --preferred-backup-window "03:00-03:30" \
  --preferred-maintenance-window "sun:04:00-sun:04:30" \
  --multi-az \
  --deletion-protection \
  --apply-immediately

echo ">> Waiting for the modification to reach 'available' ..."
aws rds wait db-instance-available --db-instance-identifier "$INSTANCE_ID"

echo ">> Config summary:"
aws rds describe-db-instances --db-instance-identifier "$INSTANCE_ID" \
  --query "DBInstances[0].{
    identifier:   DBInstanceIdentifier,
    engine:       Engine,
    retention:    BackupRetentionPeriod,
    backup_window:PreferredBackupWindow,
    multi_az:     MultiAZ,
    deletion_protection: DeletionProtection,
    latest_restorable_time: LatestRestorableTime
  }" --output table

echo ">> PITR active. Latest restorable time refreshes roughly every 5 minutes."
echo ">> Validate the ledger with:  psql <conn> -f scripts/dr/verify-ledger.sql"