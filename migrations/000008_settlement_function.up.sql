-- ============================================================================
-- 000008: Settlement Release Formula (SQL Multiplier Execution Logic)
--
-- Storefront logic that mirrors pkg/worker/formula.go and pkg/worker/settlement.go
-- as a SQL-side executor. Primary path is the Go worker (per-bet tx, SKIP LOCKED,
-- Redelivery-safe). This function is the fire-and-forget / manual recovery path
-- (ops/kickoff, backfill, or a standalone cron) and is safe to run repeatedly:
--
--   SELECT fn_settle_match(837492);
--
-- Multiplier matrix (Myanmar, identical to SelectionMultiplier/TicketMultiplier):
--   WIN        -> odds
--   HALF_WIN   -> 1 + (odds - 1) / 2
--   DRAW       -> 1.0 (neutral, no parlay impact)
--   HALF_LOSE  -> 0.5 (ticket cut in half)
--   LOSE       -> 0.0 (ticket broken)
--   BODY       -> payout profile of the selection's body_odds_type
--   MAUNG      -> product of the selected team's live maung multiplier
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_body_payout_multiplier(p_body_odds_type TEXT)
RETURNS NUMERIC AS $$
    SELECT CASE UPPER(TRIM(p_body_odds_type))
        WHEN '1+50' THEN 1.50          -- ၁+၅၀ : win earns 1.5x net stake
        ELSE 1.0                       -- အရှုံးမရှိ / 1-50 / 2-00 / level : 1.0x
    END
$$ LANGUAGE sql IMMUTABLE;

-- Settle a single pending bet. Idempotent: skips non-PENDING bets and bets
-- whose selections have not all resolved yet.
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
       SET status = bet_status, updated_at = CURRENT_TIMESTAMP
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

-- Settle every still-pending bet that references the finished match.
CREATE OR REPLACE FUNCTION fn_settle_match(p_match_id BIGINT)
RETURNS INTEGER AS $$
DECLARE
    settled INTEGER := 0;
    b       RECORD;
BEGIN
    FOR b IN
        SELECT DISTINCT bs.bet_id
          FROM bet_selections bs
          JOIN bets b ON b.id = bs.bet_id
         WHERE bs.match_id = p_match_id
           AND bs.status   = 'PENDING'
           AND b.status    = 'PENDING'
    LOOP
        PERFORM fn_settle_bet(b.bet_id);
        settled := settled + 1;
    END LOOP;
    RETURN settled;
END;
$$ LANGUAGE plpgsql;