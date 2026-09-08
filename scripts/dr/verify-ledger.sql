-- =============================================================================
-- verify-ledger.sql — double-entry ledger integrity checks.
--
-- Run on a recovered RDS instance (or periodically in staging) BEFORE restoring
-- traffic. Every check must return ZERO rows; any row is a signal to stall the
-- cutover and investigate.
--
--   psql "$RECOVERED_CONN" -v ON_ERROR_STOP=1 -f scripts/dr/verify-ledger.sql
--
-- Ledger convention: unit_ledger.amount_change is signed (+credit / -debit).
-- Invariant:  users.current_balance + users.hold_balance == SUM(amount_change)
-- Holding is a zero-sum movement (current -stake, hold +stake), so the sum of
-- the ledger ALWAYS equals the combined spendable+held balance.
-- =============================================================================

\echo '=== 1) Per-user ledger parity (expect ZERO rows) ==='
WITH ledger AS (
    SELECT user_id, ROUND(SUM(amount_change)::numeric, 2) AS ledger_total
      FROM unit_ledger
     GROUP BY user_id
)
SELECT u.id,
       u.username,
       u.role,
       ROUND(u.current_balance, 2) AS current,
       ROUND(u.hold_balance, 2)    AS held,
       (ROUND(u.current_balance, 2) + ROUND(u.hold_balance, 2)) AS combined,
       l.ledger_total,
       (ROUND(u.current_balance, 2) + ROUND(u.hold_balance, 2))
         - l.ledger_total                                        AS delta
  FROM users u
  JOIN ledger l ON l.user_id = u.id
 WHERE ABS((ROUND(u.current_balance, 2) + ROUND(u.hold_balance, 2))
          - l.ledger_total) > 0.01
 ORDER BY delta DESC;

\echo '=== 2) Ledger chain consistency (expect ZERO rows) ==='
-- Each row's balance_before must equal the previous row's balance_after when
-- ordered by (created_at, id). A broken chain implies missing/reordered writes.
WITH chained AS (
    SELECT user_id,
           created_at,
           id,
           balance_before,
           balance_after,
           LAG(balance_after) OVER (
               PARTITION BY user_id ORDER BY created_at, id
           ) AS prev_after
      FROM unit_ledger
)
SELECT user_id, id, created_at, balance_before, prev_after
  FROM chained
 WHERE prev_after IS NOT NULL
   AND ABS(prev_after - balance_before) > 0.01
 ORDER BY user_id, created_at, id;

\echo '=== 3) Ledger rows without a valid cause (expect ZERO rows) ==='
-- Every row must reference a unit_request, a bet, or carry a recognised
-- movement type. Orphans indicate partial restore / lost writes.
SELECT id, user_id, bet_id, request_id, type, amount_change, description
  FROM unit_ledger
 WHERE bet_id   IS NULL
   AND request_id IS NULL
   AND type NOT IN ('DEPOSIT', 'WITHDRAW', 'BET_HOLD', 'BET_WIN',
                    'BET_LOSE', 'BET_REFUND')
 ORDER BY id;

\echo '=== DONE: three checks above must all have returned zero rows. ==='