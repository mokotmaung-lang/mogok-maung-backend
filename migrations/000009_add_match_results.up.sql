-- =============================================================================
-- 000009: final scores + per-team result ledger for finished matches.
-- The admin result-input endpoint (POST /api/v1/admin/matches/{match_id}/result)
-- writes here, then dispatches a SettlementEvent to the worker queue.
-- =============================================================================

ALTER TABLE matches
    ADD COLUMN home_score INTEGER,
    ADD COLUMN away_score INTEGER;

-- Traditional Myanmar per-team outcome, keyed per match. One row each for
-- HOME and AWAY; statuses follow the settlement vocabulary so the worker can
-- replay results without trusting only the in-flight AMQP event.
CREATE TABLE match_results (
    match_id   BIGINT      NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    team       VARCHAR(10) NOT NULL CHECK (team IN ('HOME', 'AWAY')),
    status     VARCHAR(10) NOT NULL CHECK (
        status IN ('WIN', 'LOSE', 'DRAW', 'HALF_WIN', 'HALF_LOSE')
    ),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (match_id, team)
);