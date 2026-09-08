-- ============================================================================
-- 000011: Agent Contact Profile (Viber / Telegram / Phone / Webhook)
--
-- One row per AGENT, upserted from PUT /api/v1/agent/profile/contact-info.
-- Raw display values are stored here; the client builds protocol-specific
-- deep links (viber://, t.me/, tel:) from them at render time.
-- ============================================================================

CREATE TABLE IF NOT EXISTS agent_profiles (
    agent_id         BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    viber_number     TEXT,
    telegram_username TEXT,
    phone_number     TEXT,
    webhook_url      TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_agent_profiles_updated_at
    ON agent_profiles(updated_at DESC);