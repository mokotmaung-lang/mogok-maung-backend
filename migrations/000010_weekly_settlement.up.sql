-- ============================================================================
-- 000010: Weekly Financial Settlement (Admin <-> Agent)
--
-- Adds the settlement window stamp to bets so the weekly settlement summary
-- can attribute settled bets/payouts to the correct billing period, plus the
-- weekly_settlements ledger that marks an agent+period as SETTLED.
-- ============================================================================

-- 1) Settlement timestamp on bets. Stamped by fn_settle_bet and the Go worker
--    inside the SAME transaction that flips status PENDING -> APPROVED/REJECTED,
--    so the column is the settlement-time frontier (not approval/placement).
ALTER TABLE bets
    ADD COLUMN IF NOT EXISTS settled_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_bets_settled_at
    ON bets(settled_at) WHERE settled_at IS NOT NULL;

-- bets has no updated_at column (only created_at); fn_settle_bet (000008/000010)
-- stamps it on every status transition, so create it here (IF NOT EXISTS keeps
-- this re-runnable on DBs that already applied 000001-000009).
ALTER TABLE bets
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP;

-- Backfill anything already settled before this column existed (ops safety).
UPDATE bets
   SET settled_at = updated_at
 WHERE settled_at IS NULL
   AND status IN ('APPROVED', 'REJECTED');

-- 2) Weekly settlement ledger: one row per (agent, billing period) once the
--    super admin confirms the period, recording the agreed figures at that
--    moment (figures themselves stay live-derived from the ledger).
CREATE TABLE IF NOT EXISTS weekly_settlements (
    id                      BIGSERIAL PRIMARY KEY,
    agent_id                BIGINT NOT NULL REFERENCES users(id),
    period_start            DATE NOT NULL,
    period_end              DATE NOT NULL,
    total_bets_count        INTEGER      NOT NULL DEFAULT 0,
    total_turnover          NUMERIC(15,2) NOT NULL DEFAULT 0,
    total_payout_win        NUMERIC(15,2) NOT NULL DEFAULT 0,
    total_retained_lose     NUMERIC(15,2) NOT NULL DEFAULT 0,
    net_settlement_amount   NUMERIC(15,2) NOT NULL DEFAULT 0,
    status                  TEXT NOT NULL DEFAULT 'SETTLED'
                            CHECK (status IN ('PENDING', 'SETTLED')),
    note                    TEXT,
    settled_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    settled_by              BIGINT REFERENCES users(id),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_weekly_settlement_period
    ON weekly_settlements(agent_id, period_start, period_end);

CREATE INDEX IF NOT EXISTS idx_weekly_settlements_agent
    ON weekly_settlements(agent_id);
-- ============================================================================

-- 3) Re-arm fn_settle_bet to stamp settled_at (idempotent re-create).
CREATE OR REPLACE FUNCTION fn_settle_bet(p_bet_id BIGINT)
RETURNS VOID AS $$
DECLARE
    rec      RECORD;
    sel      RECORD;
    combined NUMERIC := 1.0;
    payout   NUMERIC;
    cur      NUMERIC;
    hold     NUMERIC;
    new_hold NUMERIC;
    new_cur  NUMERIC;
    bet_status  TEXT := 'REJECTED';
    ledger_type TEXT := 'BET_LOSE';
BEGIN
    -- Lock the bet row. Serializes concurrent settlements; status guard is the
    -- idempotency boundary (PENDING -> APPROVED/REJECTED happens once).
    SELECT id, user_id, bet_type, total_stake, hold_amount, status
      INTO rec
      FROM bets
     WHERE id = p_bet_id
       FOR UPDATE;
    IF NOT FOUND OR rec.status <> 'PENDING' THEN
        RETURN; -- already settled or does not exist
    END IF;

    -- A MAUNG ticket only releases when EVERY inner match has resolved.
    -- BODY singles (or mixed parlays) wait until all their legs settle too.
    IF EXISTS (
        SELECT 1 FROM bet_selections WHERE bet_id = p_bet_id AND status = 'PENDING'
    ) THEN
        RETURN;
    END IF;

    -- Per-selection multiplier execution.
    FOR sel IN
        SELECT bs.pick, bs.status, bs.body_odds_type,
               m.maung_home_multiplier, m.maung_away_multiplier, m.maung_draw_multiplier
          FROM bet_selections bs
          JOIN matches m ON m.id = bs.match_id
         WHERE bs.bet_id = p_bet_id
    LOOP
        DECLARE
            mult NUMERIC;
        BEGIN
            IF UPPER(rec.bet_type) = 'MAUNG' THEN
                mult := CASE UPPER(TRIM(sel.pick))
                            WHEN 'HOME' THEN sel.maung_home_multiplier
                            WHEN 'AWAY' THEN sel.maung_away_multiplier
                            ELSE            sel.maung_draw_multiplier
                        END;
            ELSE
                mult := fn_body_payout_multiplier(sel.body_odds_type);
            END IF;

            combined := combined * CASE UPPER(sel.status)
                WHEN 'WIN'       THEN mult
                WHEN 'HALF_WIN'  THEN 1.0 + (mult - 1.0) / 2.0
                WHEN 'DRAW'      THEN 1.0
                WHEN 'HALF_LOSE' THEN 0.50
                ELSE 0.0                                   -- LOSE breaks ticket
            END;
        END;
    END LOOP;

    payout := ROUND(rec.total_stake * combined, 2);

    -- Lock the wallet; release the original hold and credit the payout on top.
    SELECT current_balance, hold_balance
      INTO cur, hold
      FROM users
     WHERE id = rec.user_id
       FOR UPDATE;

    new_hold := GREATEST(hold - rec.hold_amount, 0.0);
    new_cur  := ROUND(cur + payout, 2);

    UPDATE users
       SET current_balance = new_cur,
           hold_balance    = new_hold,
           updated_at      = CURRENT_TIMESTAMP
     WHERE id = rec.user_id;

    IF payout > 0 THEN
        bet_status  := 'APPROVED';
        ledger_type := 'BET_WIN';
    END IF;

    UPDATE bets
       SET status = bet_status, updated_at = CURRENT_TIMESTAMP,
           settled_at = CURRENT_TIMESTAMP
     WHERE id = p_bet_id AND status = 'PENDING';

    -- Append-only audit entry: one row per released hold.
    INSERT INTO unit_ledger
        (user_id, request_id, bet_id, type, amount_change,
         balance_before, balance_after, description)
    VALUES
        (rec.user_id, NULL, p_bet_id, ledger_type, payout, cur, new_cur,
         'Settle bet ' || p_bet_id || ' (' || rec.bet_type || '): '
         || bet_status || ', payout ' || payout);
END;
$$ LANGUAGE plpgsql;