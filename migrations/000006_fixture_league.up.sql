-- League attribution for the post-match feed (Sportradar / API-Football).
-- The web control plane filters fixtures by league, so the source feed must
-- carry league_name into the backend matches table.

ALTER TABLE matches
    ADD COLUMN IF NOT EXISTS league_name VARCHAR(100) NOT NULL DEFAULT 'Unknown League';

CREATE INDEX IF NOT EXISTS idx_matches_league ON matches(league_name);