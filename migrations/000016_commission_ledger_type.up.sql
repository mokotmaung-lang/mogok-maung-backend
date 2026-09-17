-- ==============================================================================
-- 000016: Commission credit ledger type.
--
-- Promotional commission credits are credited to an Agent by the Super Admin
-- via POST /api/v1/admin/agents/{agent_id}/credit. They are financially
-- distinct from paid unit purchases (STANDARD_PURCHASE -> ledger type DEPOSIT)
-- and must be trackable separately in the immutable unit_ledger, so the house
-- can separate commission-bonus unit flows from money-backed purchases.
--
-- Extends trx_type with 'COMMISSION_ADD' (the admin credit endpoint maps
-- allocation_type=COMMISSION_BONUS to this ledger tag). PG >= 12 allows
-- ALTER TYPE ... ADD VALUE inside the migrator's wrapping transaction.
-- ==============================================================================

ALTER TYPE trx_type ADD VALUE IF NOT EXISTS 'COMMISSION_ADD';