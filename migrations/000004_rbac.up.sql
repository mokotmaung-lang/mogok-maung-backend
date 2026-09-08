-- RBAC support: elevated admin role + agent onboarding contact column.
--
-- NOTE: ALTER TYPE ... ADD VALUE cannot run inside a DB transaction block on
-- PostgreSQL < 12. Apply this migration outside any wrapping transaction.

ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'SUPER_ADMIN';

-- Phone contact captured when an Agent provisions a downline user.
ALTER TABLE users ADD COLUMN IF NOT EXISTS phone VARCHAR(30) UNIQUE;

CREATE INDEX IF NOT EXISTS idx_users_parent_id ON users(parent_id);