/**
 * Myanmar Odds Settlement Engine (မောင်းကြေး) — pure, side-effect free.
 *
 * Traditional "goal line" handicaps are expressed as strings such as
 * "1+25", "-36" and "0-50":
 *
 *   - "1+25" : favourite must win by 2 to win fully; win by exactly 1 pays
 *              25% profit (1.25x) = HALF_WIN; anything else loses.
 *   - "-36"  : favourite must win (any margin) for a full win; draw returns
 *              64% of stake (loses 36%) = HALF_LOSE; a loss pays nothing.
 *   - "0-50" : like "-50" against a zero goal line — draw returns 50%.
 *
 * This module mirrors the authoritative Go implementation in
 * pkg/settlement so the web control plane can preview settlements for the
 * same values the settlement worker applies.
 */

export type MyanmarOutcome =
  | 'WIN'
  | 'HALF_WIN'
  | 'HALF_LOSE'
  | 'LOSE'
  | 'PENDING';

export interface MyanmarBetSettlement {
  stake: number;
  handicap: string; // e.g. "1+25", "-36", "0-50"
  isFavorite: boolean; // true when wagering on the favourite/handicap side
  scoreHome: number;
  scoreAway: number;
}

export interface MyanmarSettlementResult {
  payout: number;
  multiplier: number;
  status: MyanmarOutcome;
}

interface ParsedHandicap {
  base: number;
  fraction: number;
  connector: '+' | '-';
}

/** Parses "1+25", "-36", "0-50", "+25" into (base, fraction, connector). */
export function parseHandicap(handicap: string): ParsedHandicap | null {
  const trimmed = handicap.trim();
  const match = /^(\d*)([+-])(\d+)$/.exec(trimmed);
  if (!match) return null;
  const base = match[1] === '' ? 0 : Number(match[1]);
  if (!Number.isInteger(base)) return null;
  return { base, fraction: Number(match[3]), connector: match[2] as '+' | '-' };
}

/** Raw (unwrapped) moneyline result — win returns 2.0x of the stake. */
const WIN_MULTIPLIER = 2.0;

export function calculateMyanmarBodyResult(
  bet: MyanmarBetSettlement,
): MyanmarSettlementResult {
  const parsed = parseHandicap(bet.handicap);
  if (!parsed || !Number.isFinite(bet.stake)) {
    return { payout: 0, multiplier: 0, status: 'PENDING' };
  }

  const goalDiff = bet.isFavorite
    ? bet.scoreHome - bet.scoreAway
    : bet.scoreAway - bet.scoreHome;

  const { base, fraction, connector } = parsed;
  const stake = bet.stake;

  if (connector === '+') {
    if (goalDiff >= base + 1) {
      return {
        payout: stake * WIN_MULTIPLIER,
        multiplier: WIN_MULTIPLIER,
        status: 'WIN',
      };
    }
    if (goalDiff === base) {
      const multiplier = 1 + fraction / 100;
      return { payout: stake * multiplier, multiplier, status: 'HALF_WIN' };
    }
    return { payout: 0, multiplier: 0, status: 'LOSE' };
  }

  if (goalDiff >= base + 1) {
    return {
      payout: stake * WIN_MULTIPLIER,
      multiplier: WIN_MULTIPLIER,
      status: 'WIN',
    };
  }
  if (goalDiff === base) {
    const multiplier = Math.max(0, 1 - fraction / 100);
    return { payout: stake * multiplier, multiplier, status: 'HALF_LOSE' };
  }
  return { payout: 0, multiplier: 0, status: 'LOSE' };
}