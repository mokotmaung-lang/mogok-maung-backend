-- Settlement support columns & indexes
-- Track per-selection settlement status (WIN/LOSE/DRAW/HALF_WIN/HALF_LOSE/PENDING)
-- and make pending-bet scans efficient.

ALTER TABLE bet_selections
    ADD COLUMN status VARCHAR(20) NOT NULL DEFAULT 'PENDING';

CREATE INDEX idx_bet_selections_status
    ON bet_selections(status);

CREATE INDEX idx_bet_selections_bet_status
    ON bet_selections(bet_id, status);

-- Bets awaiting settlement are the hottest read path for the worker.
CREATE INDEX idx_bets_pending_status
    ON bets(status) WHERE status = 'PENDING';

-- Pending selections for a finished match (settlement worker scan).
CREATE INDEX idx_bet_selections_match_status
    ON bet_selections(match_id, status);