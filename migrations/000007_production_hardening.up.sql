-- ============================================================================
-- Migration 000007 — Production Hardening per Enterprise Architecture Spec
-- Apply outside a wrapping DB transaction (ALTER TYPE ... ADD VALUE).
-- ============================================================================

-- 1. Extend match_status enum with SUSPENDED (live adjustment / suspension).
--    NOTE: ALTER TYPE cannot run inside a transaction block on PG < 12.
ALTER TYPE match_status ADD VALUE IF NOT EXISTS 'SUSPENDED';

-- 2. Add odds_version and k_factor columns to matches for optimistic
--    conflict detection during bet placement and Admin odds propagation.
ALTER TABLE matches
    ADD COLUMN IF NOT EXISTS odds_version  BIGINT        NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS k_factor      NUMERIC(3,2) NOT NULL DEFAULT 1.00;

-- 3. Add potential_payout to bets (hold_amount serves as reserved_amount).
ALTER TABLE bets
    ADD COLUMN IF NOT EXISTS potential_payout NUMERIC(15,2) NOT NULL DEFAULT 0;

-- 4. Add ref_user_id (counterparty) to unit_ledger for double-entry clarity.
ALTER TABLE unit_ledger
    ADD COLUMN IF NOT EXISTS ref_user_id BIGINT REFERENCES users(id);

-- 5. Append-Only Immutability Rules on unit_ledger.
--    These prevent UPDATE/DELETE via SQL while the transaction is in effect.
CREATE OR REPLACE RULE prevent_ledger_update
    AS ON UPDATE TO unit_ledger DO INSTEAD NOTHING;
CREATE OR REPLACE RULE prevent_ledger_delete
    AS ON DELETE TO unit_ledger DO INSTEAD NOTHING;

-- 6. Index for pending-bet scans and live odds version checks.
CREATE INDEX IF NOT EXISTS idx_matches_odds_version
    ON matches(odds_version);

-- NOTE: Partitioning unit_ledger by month (for scaling past ~100M rows)
-- requires a table rebuild and is documented here as a future production task:
--   ALTER TABLE unit_ledger PARTITION BY RANGE (created_at);
--   CREATE TABLE unit_ledger_y2026m09 PARTITION OF unit_ledger
--       FOR VALUES FROM ('2026-09-01 00:00:00+00') TO ('2026-10-01 00:00:00+00');
-- Add monthly partitions via a separate maintenance migration or CronScript.