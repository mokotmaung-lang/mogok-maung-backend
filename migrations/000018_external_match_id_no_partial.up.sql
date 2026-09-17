-- 000018_external_match_id_no_partial.up.sql
-- ---------------------------------------------------------------------------
-- 000017 created the unique index on matches(external_match_id) as a PARTIAL
-- index (WHERE external_match_id IS NOT NULL). PostgreSQL's INSERT ... ON
-- CONFLICT (column) arbiter inference requires a NON-partial unique index on
-- exactly those columns, so the feed upsert failed with:
--
--     there is no unique or exclusion constraint matching the ON CONFLICT
--     specification
--
-- Recreate the constraint as a plain unique index. NULLs remain free (Postgres
-- treats NULL values as distinct in unique indexes), so manually-created
-- fixtures without an external id are unaffected.
-- ---------------------------------------------------------------------------

DROP INDEX IF EXISTS uq_matches_external_match_id;
CREATE UNIQUE INDEX uq_matches_external_match_id ON matches (external_match_id);