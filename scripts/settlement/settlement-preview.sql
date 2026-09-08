-- ============================================================================
-- Settlement Preview — the Myanmar Maung multiplier, one pass, on REAL tables.
--
-- Production-hardened version of the spec's EXP(SUM(LN(...))) "advanced SQL".
-- Two fixes vs the original:
--   1.  LN(0) is an ERROR in PostgreSQL ("cannot take logarithm of zero"), so
--       the original query CRASHES on any LOSE leg. Here LOSE legs are excluded
--       from the log-product and a separate is_broken flag forces total 0
--       (မောင်းပြတ်). Non-LOSE factors are always > 0, so the log trick stays
--       exact.
--   2.  Data comes from the real schema: per-leg odds are the LIVE
--       maung_*_multiplier of the match (exactly what fn_settle_bet uses) and
--       outcomes come from match_results (what the Admin result endpoint wrote),
--       not made-up columns on throwaway test tables.
--
-- The worker (pkg/worker/settlement.go + migrations/000008 fn_settle_bet)
-- applies the identical matrix; this preview is the read-only ground truth
-- check. Preview only — never mutates.
--
-- RUN via:  psql -f scripts/settlement/settlement-preview.sql -v bid=9000001
-- (psql interpolates :bid; 9000002 shows the broken-ticket path.)
-- ============================================================================

\set ON_ERROR_STOP on

WITH legs AS (
    SELECT bs.bet_id,
           CASE UPPER(bs.pick)
               WHEN 'HOME' THEN m.maung_home_multiplier
               WHEN 'AWAY' THEN m.maung_away_multiplier
               ELSE            m.maung_draw_multiplier
           END AS odds_multiplier,          -- လောင်းစဉ် မောင်းအလေးပေးဂဏန်း
           r.status AS match_result,        -- WIN/LOSE/DRAW/HALF_WIN/HALF_LOSE
           b.total_stake AS stake,
           b.user_id
      FROM bet_selections bs
      JOIN matches       m ON m.id = bs.match_id
      JOIN match_results r ON r.match_id = bs.match_id AND r.team = UPPER(bs.pick)
      JOIN bets          b ON b.id = bs.bet_id
     WHERE bs.bet_id = :bid
),
-- ပွဲတစ်ပွဲချင်းစီ၏ မြန်မာ့ရိုးရာ adjustment: WIN→odds, HALF_WIN→1+(odds-1)/2,
-- DRAW→1.0 (ပယ်), HALF_LOSE→0.5 (သေ/စား), LOSE→0.0 (ပြတ်).
factors AS (
    SELECT bet_id, user_id, stake,
           CASE match_result
               WHEN 'WIN'      THEN odds_multiplier
               WHEN 'HALF_WIN' THEN 1.0 + (odds_multiplier - 1.0) / 2.0
               WHEN 'DRAW'     THEN 1.0
               WHEN 'HALF_LOSE' THEN 0.50
               WHEN 'LOSE'     THEN 0.0
           END AS factor,
           (match_result = 'LOSE') AS is_lose
      FROM legs
),
agg AS (
    SELECT bet_id, user_id, stake,
           -- LOSE ရှိလျှင် မောင်းပြတ် ↦ 0.0; မရှိလျှင် အားလုံးမြှောက် via log-sum-exp;
           -- LOSE မဟုတ်သည့် legs အားလုံး factor > 0 ဖြစ်၍ ln() safe.
           CASE WHEN BOOL_OR(is_lose) THEN 0.0
                ELSE COALESCE(EXP(SUM(LN(factor)) FILTER (WHERE NOT is_lose)), 1.0)
           END AS combined,
           CASE WHEN BOOL_OR(is_lose) THEN 'REJECTED' ELSE 'APPROVED' END AS final_status
      FROM factors
     GROUP BY bet_id, user_id, stake
)
SELECT bet_id                                               AS "မောင်းစဉ် ID",
       user_id                                              AS "ယူဆာရှင် ID",
       stake                                                AS "မူလလောင်းကြေး",
       ROUND(combined, 4)                                   AS "စုစုပေါင်း အဆ multiplier",
       ROUND(CASE WHEN combined = 0 THEN 0 ELSE stake * combined END, 2)
                                                            AS "ပြန်လည်ရရှိမည့် ဆုကြေးပမာဏ",
       final_status                                         AS "မောင်းအခြေအနေ"
  FROM agg;

-- Mathematical verification (spec §2, unchanged):
--   1.90 (WIN) × 1.40 (HALF_WIN) × 0.50 (HALF_LOSE) = 1.3300
--   payout = 1,000 × 1.3300 = 1,330.00   (profit 330 units)
-- Broken ticket (LOSE leg): 0.00 / REJECTED.