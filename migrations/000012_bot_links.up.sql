-- ============================================================================
-- 000012: Bot Webhook Links (Viber / Telegram → user mapping)
--
-- The bot webhook worker receives "DEPOSIT 5000" style messages from the
-- agent's Viber/Telegram bot. To credit an audit-trailed PENDING unit request
-- it must map the platform's unique sender id back to a platform user: that
-- mapping lives here (one active link per (platform, platform_user_id)).
-- ============================================================================

CREATE TABLE IF NOT EXISTS bot_links (
    id               BIGSERIAL PRIMARY KEY,
    user_id          BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    platform         TEXT NOT NULL CHECK (platform IN ('VIBER', 'TELEGRAM')),
    platform_user_id TEXT NOT NULL,
    is_active        BOOLEAN NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (platform, platform_user_id)
);

CREATE INDEX IF NOT EXISTS idx_bot_links_user
    ON bot_links(user_id) WHERE is_active = TRUE;