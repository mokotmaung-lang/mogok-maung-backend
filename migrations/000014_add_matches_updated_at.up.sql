-- ============================================================================
-- 000014: matches.updated_at
--
-- The live-odds snapshot contract and UpdateMatchStatus both stamp/read
-- matches.updated_at (last status/odds change), but 000001 only created
-- matches.created_at. Missing column made every /ws/live-odds snapshot fail
-- with `pq: column "updated_at" does not exist` — add it (idempotent across
-- the 000001-000013-applied DBs and fresh installs alike).
-- ============================================================================

ALTER TABLE matches
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP;