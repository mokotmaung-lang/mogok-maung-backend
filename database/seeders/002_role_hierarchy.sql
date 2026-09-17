-- ============================================================================
-- 002: Role hierarchy bootstrap (SUPER_ADMIN -> ADMIN -> AGENT -> USER)
-- ============================================================================
-- Creates the demo role accounts the staging seed (mock_data.sql) provides, so
-- a production host backing the public domain carries the full tested role
-- hierarchy WITHOUT importing the staging data (matches/odds/bets stay prod-
-- side). Run AFTER 001: a SUPER_ADMIN must already exist.
--
-- Cost control: the_password is generated inside PostgreSQL via pgcrypto
-- (algorithm 'bf' == bcrypt); no password ever appears in this repo.
--
-- Usage (Windows PowerShell, repo root) — creds passed with -v:
--   Get-Content database\seeders\002_role_hierarchy.sql |
--     ssh mmvps "docker exec -i mm_prod_postgres psql -U bet_admin -d myanmar_bet_prod \
--       -v seed_pass='<your-password>'"            # VPS prod
--   Get-Content database\seeders\002_role_hierarchy.sql |
--     docker compose exec -T postgres-db psql -U bet_admin -d myanmar_bet_prod \
--       -v seed_pass='Staging123!'                 # local Docker stack
--
-- Idempotent: each INSERT is guarded by NOT EXISTS so re-runs never duplicate,
-- and existing accounts (same username) are left untouched.
-- ============================================================================

\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Guard: refuse to run before a SUPER_ADMIN exists.
\if :{?seed_pass}
\else
  \echo 'ERROR: -v seed_pass=... is required (>= 8 chars)'
  \quit 1
\endif

SELECT count(*) AS superadmin_count FROM users WHERE role = 'SUPER_ADMIN' \gset
\if :superadmin_count
\else
  \echo 'ERROR: no SUPER_ADMIN account exists yet — run 001_bootstrap_admin.sql first'
  \quit 1
\endif

-- ---------------------------------------------------------------------------
-- 1. ROLE ACCOUNTS (username -> name -> role). Zero balances; units arrive
--    through the real allocation/request flow on prod.
-- ---------------------------------------------------------------------------
INSERT INTO users (username, password_hash, name, role, is_active, must_change_password)
SELECT c.username, crypt(:'seed_pass', gen_salt('bf', 10)), c.name, c.role::user_role,
       TRUE, FALSE
FROM (VALUES
  ('admin01', 'Admin Officer',     'ADMIN'),
  ('agent01', 'Agent Khaing',      'AGENT'),
  ('agent02', 'Agent Wai Yan',     'AGENT'),
  ('user01',  'User One',          'USER'),
  ('user02',  'User Two',          'USER'),
  ('user03',  'User Three',        'USER'),
  ('user04',  'User Four',         'USER')
) AS c(username, name, role)
WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.username = c.username)
  AND length(:'seed_pass') >= 8;

-- ---------------------------------------------------------------------------
-- 2. MATERIALISE THE HIERARCHY (separate statement: rows of one INSERT are not
--    visible to its own sub-selects under MVCC).
-- ---------------------------------------------------------------------------
WITH hierarchy AS (
  SELECT 'admin01' AS child,  'SUPER_ADMIN' AS parent_role
  UNION ALL SELECT 'agent01', 'ADMIN'
  UNION ALL SELECT 'agent02', 'ADMIN'
  UNION ALL SELECT 'user01',  'AGENT_agent01'
  UNION ALL SELECT 'user02',  'AGENT_agent01'
  UNION ALL SELECT 'user03',  'AGENT_agent02'
  UNION ALL SELECT 'user04',  'AGENT_agent02'
)
UPDATE users AS u
SET parent_id = CASE h.parent_role
                    WHEN 'SUPER_ADMIN' THEN (SELECT s.id FROM users s
                                             WHERE s.role = 'SUPER_ADMIN' ORDER BY s.id LIMIT 1)
                    WHEN 'ADMIN'       THEN (SELECT a.id FROM users a
                                             WHERE a.username = 'admin01')
                    WHEN 'AGENT_agent01' THEN (SELECT a.id FROM users a
                                               WHERE a.username = 'agent01')
                    WHEN 'AGENT_agent02' THEN (SELECT a.id FROM users a
                                               WHERE a.username = 'agent02')
                END
FROM hierarchy AS h
WHERE u.username = h.child;

\echo
\echo 'Resulting role hierarchy:'
SELECT u.id, u.username, u.role, p.username AS parent, u.is_active
  FROM users u
  LEFT JOIN users p ON p.id = u.parent_id
 WHERE u.username IN ('admin01','agent01','agent02','user01','user02','user03','user04')
 ORDER BY u.id;