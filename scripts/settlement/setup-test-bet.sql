-- ============================================================================
-- Setup: production-schema mock data for the Myanmar Maung settlement demo.
--
-- Mirrors the spec's "test_bets / test_bet_details" scenario but against the
-- REAL tables (bets / bet_selections / matches / match_results), because the
-- worker and fn_settle_bet only ever operate on the real schema.
--
-- Fixture (spec §1, adapted):
--   User "settle_test_user", MAUNG 3-leg ticket, stake 1,000 units
--     leg A  match 990001  pick HOME  maung 1.90  -> WIN        (×1.90)
--     leg B  match 990002  pick AWAY  maung 1.80  -> HALF_WIN   (×1.40)
--     leg C  match 990003  pick HOME  maung 2.00  -> HALF_LOSE  (×0.50)
--   => combined 1.90 × 1.40 × 0.50 = 1.33 → payout 1,000 × 1.33 = 1,330.00
--
-- A second, broken ticket proves the LOSE path:
--     match 990004  pick HOME  maung 1.80  -> LOSE   => REJECTED, payout 0
--
-- RUN via:  psql -f scripts/settlement/setup-test-bet.sql
-- Rerunnable: returns early (NOTICE) if the fixture already exists. Matches,
-- bets, selections and results are deletable; unit_ledger is append-only by
-- design (production audit rule), so ledger rows from a previous run remain.
-- ============================================================================

DO $fixture$
DECLARE
    u   BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM matches WHERE id BETWEEN 990001 AND 990004) THEN
        RAISE NOTICE 'Fixture matches 990001-990004 already exist; skipping setup.';
        RETURN;
    END IF;

    -- Sandbox user (idempotent by unique username).
    INSERT INTO users (username, password_hash, name, role, is_active)
    VALUES ('settle_test_user', 'x', 'Settlement Test User', 'USER', TRUE)
    ON CONFLICT (username) DO NOTHING;
    SELECT id INTO u FROM users WHERE username = 'settle_test_user';

    -- 3-leg happy-path matches + the broken-path match.
    INSERT INTO matches
        (id, home_team, away_team, match_time, handicap_team, body_odds_type,
         home_body_payout, away_body_payout,
         maung_home_multiplier, maung_away_multiplier, maung_draw_multiplier,
         status)
    VALUES
        (990001, 'Test H1', 'Test A1', now(), 'HOME', '1-50',
         1.00, 1.00, 1.90, 1.00, 1.00, 'FINISHED'),
        (990002, 'Test H2', 'Test A2', now(), 'HOME', '1-50',
         1.00, 1.00, 1.00, 1.80, 1.00, 'FINISHED'),
        (990003, 'Test H3', 'Test A3', now(), 'HOME', '1-50',
         1.00, 1.00, 2.00, 1.00, 1.00, 'FINISHED'),
        (990004, 'Test H4', 'Test A4', now(), 'HOME', '1-50',
         1.00, 1.00, 1.80, 1.00, 1.00, 'FINISHED');

    -- Official result record (what POST /api/v1/admin/matches/{id}/result
    -- writes today).
    INSERT INTO match_results (match_id, team, status) VALUES
        (990001, 'HOME', 'WIN'),
        (990002, 'AWAY', 'HALF_WIN'),
        (990003, 'HOME', 'HALF_LOSE'),
        (990004, 'HOME', 'LOSE');

    -- Fund the wallet: DEPOSIT 5,000 units through the real ledger trail.
    UPDATE users SET current_balance = 5000.00, hold_balance = 0.00 WHERE id = u;
    INSERT INTO unit_ledger
        (user_id, request_id, bet_id, type, amount_change,
         balance_before, balance_after, description)
    VALUES
        (u, NULL, NULL, 'DEPOSIT', 5000.00, 0.00, 5000.00, 'Settlement test funding');

    -- Two pending MAUNG tickets (hold_amount == stake, k_factor = 1.00).
    INSERT INTO bets (id, user_id, bet_type, total_stake, hold_amount, status)
    VALUES
        (9000001, u, 'MAUNG', 1000.00, 1000.00, 'PENDING'),
        (9000002, u, 'MAUNG', 1000.00, 1000.00, 'PENDING');

    INSERT INTO bet_selections (bet_id, match_id, pick, body_odds_type) VALUES
        (9000001, 990001, 'HOME', '1-50'),
        (9000001, 990002, 'AWAY', '1-50'),
        (9000001, 990003, 'HOME', '1-50'),
        (9000002, 990004, 'HOME', '1-50');

    RAISE NOTICE 'Fixture ready: settle_test_user id=%, bets 9000001 (3-leg) and 9000002 (broken)', u;
END
$fixture$;