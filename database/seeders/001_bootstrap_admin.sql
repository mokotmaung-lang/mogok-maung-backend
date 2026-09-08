-- ============================================================================
-- 001: Bootstrap SUPER_ADMIN
-- ============================================================================
-- Run ONCE against the primary database after `docker compose up` has applied
-- the migrations (the API auto-migrates at boot). Creates the very first
-- SUPER_ADMIN account; the account ships with must_change_password=TRUE, so
-- the first interactive login forces a real password change.
--
-- The bcrypt hash is generated INSIDE PostgreSQL via the pgcrypto extension
-- (algorithm 'bf' == bcrypt) at runtime, so no password ever appears in the
-- repo and no external tooling is required.
--
-- Usage (Windows PowerShell, repo root) — credentials passed with -v so the
-- SQL file never includes them:
--   Get-Content database\seeders\001_bootstrap_admin.sql |
--     docker compose exec -T postgres-db psql -U bet_admin -d myanmar_bet_prod `
--       -v boot_user=superadmin -v "boot_pass=<your-password>"
--
-- Idempotent: inserts NOTHING when a SUPER_ADMIN already exists, and requires
-- a password of at least 8 characters.
-- ============================================================================

\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pgcrypto;

INSERT INTO users (username, password_hash, name, role, is_active, must_change_password)
SELECT COALESCE(NULLIF(:'boot_user', ''), 'superadmin'),
       crypt(:'boot_pass', gen_salt('bf', 10)),
       'System Administrator',
       'SUPER_ADMIN',
       TRUE,
       TRUE
WHERE NOT EXISTS (SELECT 1 FROM users WHERE role = 'SUPER_ADMIN')
  AND length(:'boot_pass') >= 8;

-- ============================================================================
-- Extend for the reference hierarchy when a new environment needs demo data:
--
--   INSERT INTO users (username, password_hash, name, role, parent_id)
--   SELECT 'agent.' || g, crypt(:'boot_pass', gen_salt('bf', 10)),
--          'Demo Agent ' || g, 'AGENT', a.id
--   FROM generate_series(1, 3) g,
--        (SELECT id FROM users WHERE role = 'SUPER_ADMIN' LIMIT 1) a
--   WHERE NOT EXISTS (SELECT 1 FROM users WHERE role = 'AGENT');
-- ============================================================================

\echo
\echo 'Resulting SUPER_ADMIN accounts:'
SELECT id, username, role, must_change_password
  FROM users
 WHERE role = 'SUPER_ADMIN';