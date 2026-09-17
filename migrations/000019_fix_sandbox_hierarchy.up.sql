-- ==============================================================================
-- 000019: Sandbox hierarchy realignment (Strict Tenant Isolation Law).
--
-- Idempotent data fix that guarantees the sandbox downline tree is coherent:
--   * sandbox_agent_55840 (the production E2E agent) is rooted to the Super
--     Admin (id = 1), preserving the SUPER_ADMIN -> AGENT delegation chain.
--   * every sandbox USER (dl_82767 + the drift accounts user / user1) is
--     explicitly re-parented to sandbox_agent_55840's integer id, keyed by
--     username (NOT a hard-coded surrogate id) so the mapping survives an
--     id reshuffle.
--
-- Both statements are no-ops when the tree is already coherent, so re-running
-- or applying against a healthy database is safe. The second UPDATE runs only
-- when the agent row exists (FROM-clause guard) — it can never null a
-- parent_id.
--
-- NOTE: executed by pkg/database/migrate.go via Simple Query (multi-statement).
-- ==============================================================================

UPDATE users
   SET parent_id     = 1,
       updated_at    = CURRENT_TIMESTAMP
 WHERE username      = 'sandbox_agent_55840'
   AND role          = 'AGENT';

WITH sandbox_agent AS (
    SELECT id
      FROM users
     WHERE username = 'sandbox_agent_55840'
       AND role     = 'AGENT'
)
UPDATE users u
   SET parent_id  = sa.id,
       updated_at = CURRENT_TIMESTAMP
  FROM sandbox_agent sa
 WHERE u.username IN ('dl_82767', 'user', 'user1')
   AND u.role      = 'USER';