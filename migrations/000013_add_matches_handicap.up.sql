-- ============================================================================
-- 000013: matches.handicap display label
--
-- The live-odds snapshot contract (pkg/websocket/snapshot.go + the Flutter
-- LiveOddsSnapshot.fromJson) reads a `handicap` display string such as
-- "1+25". Only handicap_team + body_odds_type were migrated in 000001, so the
-- snapshot query failed with `column "handicap" does not exist` and the whole
-- /ws/live-odds + Redis fan-out was dead at runtime.
--
-- Add the column and treat body_odds_type as the authoritative label: every
-- admin odds write that changes body_odds_type also writes handicap, and the
-- snapshot query falls back to body_odds_type when handicap is NULL (covers
-- rows created before this migration / legacy seeds).
-- ============================================================================

ALTER TABLE matches
    ADD COLUMN IF NOT EXISTS handicap VARCHAR(50);