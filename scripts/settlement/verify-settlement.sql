-- ============================================================================
-- Settlement Verification — end-to-end, hermetic, self-asserting.
--
-- Recreates the 3-leg scenario on the REAL tables inside one transaction,
-- resolves per-selection status exactly like the worker (outcome from
-- match_results), settles via the ground-truth fn_settle_bet (migrations/
-- 000008), then asserts the full Myanmar math end-to-end:
--
--   1.90 (WIN) × 1.40 (HALF_WIN) × 0.50 (HALF_LOSE) = 1.3300
--   payout = 1,000 × 1.3300 = 1,330.00  (current_balance 5,000 → 6,330)
--   hold_balance released fully (1,000 → 0)
--   broken ticket  9000012 → REJECTED, payout 0
--
-- FINAL ROLLBACK ⇒ zero side effects; safe to run repeatedly
-- (unit_ledger is append-only by production rule — rollback sidesteps cleanup).
--
-- RUN via:  psql -f scripts/settlement/verify-settlement.sql
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- 1. Fixtures (real schema, dedicated ids in the 9900xx / 90000xx range).
DO $setup$
DECLARE
    u BIGINT;
BEGIN
    INSERT INTO users (username, password_hash, name, role, is_active)
    VALUES ('settle_verify_user', 'x', 'Settlement Verify User', 'USER', TRUE)
    ON CONFLICT (username) DO NOTHING;
    SELECT id INTO u FROM users WHERE username = 'settle_verify_user';
    UPDATE users SET current_balance = 5000.00, hold_balance = 0.00 WHERE id = u;

    INSERT INTO matches
        (id, home_team, away_team, match_time, handicap_team, body_odds_type,
         home_body_payout, away_body_payout,
         maung_home_multiplier, maung_away_multiplier, maung_draw_multiplier, status)
    VALUES
        (990011, 'Verify H1', 'Verify A1', now(), 'HOME', '1-50',
         1.00, 1.00, 1.90, 1.00, 1.00, 'FINISHED'),   -- leg A WIN
        (990012, 'Verify H2', 'Verify A2', now(), 'HOME', '1-50',
         1.00, 1.00, 1.00, 1.80, 1.00, 'FINISHED'),   -- leg B HALF_WIN
        (990013, 'Verify H3', 'Verify A3', now(), 'HOME', '1-50',
         1.00, 1.00, 2.00, 1.00, 1.00, 'FINISHED'),   -- leg C HALF_LOSE
        (990014, 'Verify H4', 'Verify A4', now(), 'HOME', '1-50',
         1.00, 1.00, 1.80, 1.00, 1.00, 'FINISHED');   -- broken LOSE

    INSERT INTO match_results (match_id, team, status) VALUES
        (990011, 'HOME', 'WIN'),
        (990012, 'AWAY', 'HALF_WIN'),
        (990013, 'HOME', 'HALF_LOSE'),
        (990014, 'HOME', 'LOSE');

    INSERT INTO bets (id, user_id, bet_type, total_stake, hold_amount, status) VALUES
        (9000011, u, 'MAUNG', 1000.00, 1000.00, 'PENDING'),   -- happy 3-leg
        (9000012, u, 'MAUNG', 1000.00, 1000.00, 'PENDING');   -- broken

    INSERT INTO bet_selections (bet_id, match_id, pick, body_odds_type) VALUES
        (9000011, 990011, 'HOME', '1-50'),
        (9000011, 990012, 'AWAY', '1-50'),
        (9000011, 990013, 'HOME', '1-50'),
        (9000012, 990014, 'HOME', '1-50');
END
$setup$;

-- 2. Resolve per-selection status like the worker (pkg/worker/settlement.go
--    resolveOutcome): outcome = match_results[CASE pick ...] row.
UPDATE bet_selections bs
   SET status = mr.status
  FROM match_results mr
 WHERE mr.match_id = bs.match_id
   AND mr.team    = UPPER(bs.pick)
   AND bs.bet_id IN (9000011, 9000012);

-- 3. Settle through the production function (the same one the worker calls).
SELECT fn_settle_bet(9000011);
SELECT fn_settle_bet(9000012);

-- 4. Assert. Any mismatch aborts the transaction (and the ROLLBACK restores
--    the DB); success prints NOTICEs.
DO $check$
DECLARE
    v_status  TEXT;
    v_cur     NUMERIC;
    v_hold    NUMERIC;
    v_ledger  NUMERIC;
BEGIN
    SELECT status INTO v_status FROM bets WHERE id = 9000011;
    IF v_status <> 'APPROVED' THEN
        RAISE EXCEPTION 'happy ticket 9000011 = % (expected APPROVED)', v_status;
    END IF;

    SELECT status INTO v_status FROM bets WHERE id = 9000012;
    IF v_status <> 'REJECTED' THEN
        RAISE EXCEPTION 'broken ticket 9000012 = % (expected REJECTED)', v_status;
    END IF;

    SELECT current_balance, hold_balance INTO v_cur, v_hold
      FROM users WHERE username = 'settle_verify_user';
    IF v_cur <> 6330.00 THEN
        RAISE EXCEPTION 'final balance = % (expected 6330.00)', v_cur;
    END IF;
    IF v_hold <> 0.00 THEN
        RAISE EXCEPTION 'hold balance = % (expected 0.00)', v_hold;
    END IF;

    SELECT amount_change INTO v_ledger
      FROM unit_ledger WHERE bet_id = 9000011 AND type = 'BET_WIN';
    IF v_ledger <> 1330.00 THEN
        RAISE EXCEPTION 'ledger BET_WIN = % (expected 1330.00)', v_ledger;
    END IF;

    SELECT amount_change INTO v_ledger
      FROM unit_ledger WHERE bet_id = 9000012 AND type = 'BET_LOSE';
    IF v_ledger IS DISTINCT FROM 0.00 THEN
        RAISE EXCEPTION 'ledger BET_LOSE = % (expected 0.00)', v_ledger;
    END IF;

    RAISE NOTICE 'PASS 1.90×1.40×0.50 = 1.3300; payout = 1,330.00; broken ticket REJECTED @ 0.00';
    RAISE NOTICE 'PASS wallet: current 6,330.00, hold 0.00; ledger BET_WIN 1,330.00 / BET_LOSE 0.00';
END
$check$;

ROLLBACK;

-- NOTE: ROLLBACK discards these fixtures; run setup-test-bet.sql first for a
-- persistent sandbox to poke at with settlement-preview.sql (:bid=9000001/9000002).