-- ============================================================================
-- mock_data.sql — Staging environment seed data.
--
-- Loads sample hierarchical users, traditional Myanmar odds matches, pending
-- bets and a finished match with recorded results so the full flow
-- (login → place bet → settle) can be exercised out of the box.
--
-- Run AFTER the schema is migrated (the API applies 000001→000012 on boot):
--
--   docker compose exec -T postgres-db \
--     env PGPASSWORD=... psql -U bet_admin -d myanmar_bet_prod \
--     -v ON_ERROR_STOP=1 -q -f /dev/stdin < database/seeders/mock_data.sql
--
-- NOTE: this is indicative data for smoke testing, NOT an accounting
-- reconciliation — balances and bet holds are illustrative.
-- All mock accounts share one password: Staging123!
--
-- Idempotency: guarded by ON CONFLICT on natural keys, safe to re-run.
-- ============================================================================
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. HIERARCHICAL USERS (Super Admin -> Admin -> Agent -> User)
-- ---------------------------------------------------------------------------
INSERT INTO users (username, password_hash, name, role, parent_id,
                   current_balance, hold_balance, phone, must_change_password)
VALUES
  ('root',    crypt('Staging123!', gen_salt('bf', 10)), 'Root Admin (Staging)',
             'SUPER_ADMIN', NULL, 1000000.00, 0.00, NULL,              FALSE),
  ('admin01', crypt('Staging123!', gen_salt('bf', 10)), 'Admin Officer',
             'ADMIN',       NULL,  500000.00, 0.00, '+959100000000',   FALSE),
  ('agent01', crypt('Staging123!', gen_salt('bf', 10)), 'Agent Khaing',
             'AGENT',       NULL,  200000.00, 0.00, '+959100000001',   FALSE),
  ('agent02', crypt('Staging123!', gen_salt('bf', 10)), 'Agent Wai Yan',
             'AGENT',       NULL,  150000.00, 0.00, '+959100000002',   FALSE),
  ('user01',  crypt('Staging123!', gen_salt('bf', 10)), 'User One',
             'USER',        NULL,   50000.00, 0.00, '+959200000001',   FALSE),
  ('user02',  crypt('Staging123!', gen_salt('bf', 10)), 'User Two',
             'USER',        NULL,   30000.00, 0.00, '+959200000002',   FALSE),
  ('user03',  crypt('Staging123!', gen_salt('bf', 10)), 'User Three',
             'USER',        NULL,   40000.00, 0.00, '+959200000003',   FALSE),
  ('user04',  crypt('Staging123!', gen_salt('bf', 10)), 'User Four',
             'USER',        NULL,   25000.00, 0.00, '+959200000004',   FALSE)
ON CONFLICT (username) DO NOTHING;

-- Materialise the hierarchy (separate statement: rows of one INSERT are not
-- visible to its own sub-selects under MVCC).
WITH hierarchy AS (
  SELECT 'admin01' AS username, 'root'    AS parent FROM (SELECT 1) x
  UNION ALL SELECT 'agent01', 'admin01' UNION ALL SELECT 'agent02', 'admin01'
  UNION ALL SELECT 'user01',  'agent01' UNION ALL SELECT 'user02',  'agent01'
  UNION ALL SELECT 'user03',  'agent02' UNION ALL SELECT 'user04',  'agent02'
)
UPDATE users AS u
SET parent_id = parent.id
FROM hierarchy AS h
JOIN users AS parent ON parent.username = h.parent
WHERE u.username = h.username;

-- Deposit ledger rows so the double-entry invariant (get_balance == sum of
-- unit_ledger) holds for the seeded balances.
INSERT INTO unit_ledger (user_id, request_id, bet_id, type, amount_change,
                         balance_before, balance_after, description)
SELECT u.id, NULL, NULL, 'DEPOSIT', u.current_balance, 0.00, u.current_balance,
       'Staging bootstrap deposit'
FROM users u
WHERE u.current_balance > 0
  AND NOT EXISTS (
    SELECT 1 FROM unit_ledger l
    WHERE l.user_id = u.id AND l.type = 'DEPOSIT'
  );

-- ---------------------------------------------------------------------------
-- 2. MATCHES WITH TRADITIONAL MYANMAR ODDS
--    body_odds_type  -> BODY handicap label ("1-50", "-36", "0-50", "1+25")
--    maung_*         -> Maung (parlay) multiplier per outcome
-- ---------------------------------------------------------------------------
INSERT INTO matches (home_team, away_team, match_time, handicap_team,
                     body_odds_type, home_body_payout, away_body_payout,
                     maung_home_multiplier, maung_away_multiplier,
                     maung_draw_multiplier, status, league_name)
VALUES
  -- Upcoming fixtures for betting (all OPEN)
  ('Yangon United',   'Shan United',       now() + interval '2 hours',
      'HOME', '1-50', 1.50, 1.90, 1.90, 1.80, 1.00, 'OPEN',
      'Myanmar National League'),
  ('Mandalay FC',     'Rakhine United',    now() + interval '4 hours',
      'AWAY', '-36',  0.64, 0.64, 1.85, 1.85, 1.00, 'OPEN',
      'Myanmar National League'),
  ('Ayeyawady United','Hantharwady United',now() + interval '6 hours',
      'HOME', '0-50', 0.50, 0.50, 1.90, 1.82, 1.00, 'OPEN',
      'Myanmar National League'),
  ('Yangon United U21','Shan United U21',  now() + interval '26 hours',
      'AWAY', '1+25', 1.25, 1.25, 1.92, 1.84, 1.00, 'OPEN', 'MNL U-21'),
  ('Islanders FC',    'Marine FC',         now() + interval '30 hours',
      'HOME', '1-50', 1.50, 1.50, 1.88, 1.88, 1.00, 'OPEN',
      'Myanmar Youth League')
ON CONFLICT DO NOTHING;

-- One finished match with a recorded score so settlement can be demonstrated.
INSERT INTO matches (home_team, away_team, match_time, handicap_team,
                     body_odds_type, home_body_payout, away_body_payout,
                     maung_home_multiplier, maung_away_multiplier,
                     maung_draw_multiplier, status, league_name,
                     home_score, away_score)
VALUES
  ('Zwekapin United', 'Sagaing United', now() - interval '3 days',
      'HOME', '1-50', 1.50, 1.90, 1.90, 1.80, 1.00, 'FINISHED',
      'Myanmar National League', 2, 1)
ON CONFLICT DO NOTHING;

-- Per-team Myanmar outcome for the finished match (feed for settlement replay).
INSERT INTO match_results (match_id, team, status)
SELECT m.id, 'HOME', 'WIN'  FROM matches m WHERE m.away_team = 'Sagaing United'
UNION ALL
SELECT m.id, 'AWAY', 'LOSE' FROM matches m WHERE m.away_team = 'Sagaing United'
ON CONFLICT (match_id, team) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. PENDING BETS + SELECTIONS (BODY and MAUNG parlays)
-- ---------------------------------------------------------------------------
-- user01: Body bet on Yangon United (HOME), 1-50 line -> 1.5x hold.
INSERT INTO bets (user_id, bet_type, total_stake, hold_amount, status)
SELECT u.id, 'BODY', 1000.00, 1500.00, 'PENDING'
FROM users u WHERE u.username = 'user01'
ON CONFLICT DO NOTHING;

INSERT INTO bet_selections (bet_id, match_id, pick, body_odds_type, status)
SELECT b.id, m.id, 'HOME', '1-50', 'PENDING'
FROM bets b
JOIN users u ON u.id = b.user_id
JOIN matches m ON m.home_team = 'Yangon United'
WHERE u.username = 'user01' AND b.bet_type = 'BODY'
ON CONFLICT DO NOTHING;

-- user02: Maung parlay across two upcoming fixtures (full-win multiplier chain).
INSERT INTO bets (user_id, bet_type, total_stake, hold_amount, status)
SELECT u.id, 'MAUNG', 2000.00, 2000.00, 'PENDING'
FROM users u WHERE u.username = 'user02'
ON CONFLICT DO NOTHING;

INSERT INTO bet_selections (bet_id, match_id, pick, body_odds_type, status)
SELECT b.id, m.id, 'HOME', '1-50', 'PENDING'
FROM bets b
JOIN users u ON u.id = b.user_id
JOIN matches m ON m.home_team = 'Yangon United'
WHERE u.username = 'user02' AND b.bet_type = 'MAUNG'
ON CONFLICT DO NOTHING;

INSERT INTO bet_selections (bet_id, match_id, pick, body_odds_type, status)
SELECT b.id, m.id, 'HOME', '0-50', 'PENDING'
FROM bets b
JOIN users u ON u.id = b.user_id
JOIN matches m ON m.home_team = 'Ayeyawady United'
WHERE u.username = 'user02' AND b.bet_type = 'MAUNG'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. VERIFICATION
-- ---------------------------------------------------------------------------
SELECT 'users'      AS table_name, count(*) FROM users
UNION ALL SELECT 'matches',      count(*) FROM matches
UNION ALL SELECT 'unit_ledger',  count(*) FROM unit_ledger
UNION ALL SELECT 'bets',         count(*) FROM bets
UNION ALL SELECT 'bet_selections', count(*) FROM bet_selections
UNION ALL SELECT 'match_results',  count(*) FROM match_results;

\echo 'Mock data loaded. Login as root / admin01 / agent01 / user01 with password Staging123!'