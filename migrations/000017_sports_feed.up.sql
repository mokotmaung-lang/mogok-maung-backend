-- ==============================================================================
-- 000017: External sports-feed identity for the fixture sync pipeline.
--
-- The Sports API fixtures carry their own natural key (the provider's match id);
-- the local matches.id is a BIGSERIAL that the whole betting/settlement domain
-- references, so the sync layer must be able to find "the row that represents
-- provider match X" without inventing a new surrogate. external_match_id is that
-- stable provider key.
--
-- The UNIQUE index also backs the production merge path:
--
--   INSERT INTO matches (...) VALUES (...)
--   ON CONFLICT (external_match_id) DO UPDATE SET ...
--
-- ON CONFLICT requires a unique constraint/index on the conflict target; the
-- plain unique index satisfies inference. Pre-existing legacy rows have NULL
-- here — PostgreSQL allows unlimited NULLs in a unique index, so they are never
-- touched by a sync and stay fully under Super Admin control.
-- ==============================================================================

ALTER TABLE matches
    ADD COLUMN IF NOT EXISTS external_match_id VARCHAR(64);

CREATE UNIQUE INDEX IF NOT EXISTS uq_matches_external_match_id
    ON matches(external_match_id)
    WHERE external_match_id IS NOT NULL;