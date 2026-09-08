-- First-login password guard: accounts provisioned by agents carry the
-- bootstrap password and must force the user to rotate it before betting.

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS must_change_password BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_users_must_change_password
    ON users(must_change_password) WHERE must_change_password = TRUE;