-- ==============================================================================
-- 000015: Master superadmin (id=1) — rigid identity + credentials.
--
-- THE single bootstrap for the master SUPER_ADMIN account. Applies exactly-once
-- at API container boot (schema_migrations), so it can be run against any
-- environment (local compose, staging, production) with no manual SQL.
--
-- Credentials contract (fixed — username `sysadmin`; master password set at
-- provision time, do not rotate via this file — use the change-password
-- endpoint instead so the JWT guard stays in sync).
--
-- The password_hash is a REAL bcrypt hash (cost 12) of the master secret,
-- verified via pgcrypto crypt() AND Go's x/crypto/bcrypt (the verifier the
-- login handler uses). DO NOT replace it with a placeholder/base64 string — a
-- fake hash locks the master out with 401 "invalid credentials".
--
-- Notes on deviations from the original request SQL:
--   * role is 'SUPER_ADMIN' (not 'ADMIN') — our RBAC distinguishes the two; the
--     admin/agent control-plane handlers (e.g. POST /api/v1/admin/agents/create)
--     require SUPER_ADMIN. A bare 'ADMIN' row cannot provision agents.
--   * File name follows the auto-migrator contract `<6-digit>_*.up.sql` so it is
--     picked up by pkg/database/migrate.go on boot.
-- ==============================================================================

INSERT INTO users
    (id, username, password_hash, name, role, parent_id, current_balance, is_active, must_change_password)
VALUES
    (1, 'sysadmin', '$2a$12$rtekPILDvxvP/vxYNMMQeOreWvH4BzFhVS/1P1YTaesb4M9mYz1a2',
     'စနစ်ကြီးကြပ်သူချုပ်', 'SUPER_ADMIN', NULL, 1000000.00, TRUE, FALSE)
ON CONFLICT (id) DO UPDATE
    SET username            = EXCLUDED.username,
        password_hash       = EXCLUDED.password_hash,
        name                = EXCLUDED.name,
        role                = EXCLUDED.role,
        parent_id           = NULL,
        current_balance     = EXCLUDED.current_balance,
        is_active           = TRUE,
        must_change_password = FALSE,
        updated_at          = CURRENT_TIMESTAMP;