/// Myanmar Odds Calculator (ကြေးတွက်စက်)
///
/// Master Prompt Blueprint 2 — exact Pure-Dart payout engine for the
/// traditional Myanmar handicap system used across the MGM platform:
///
///   "0-50"   → 0 goal line; win = full profit, draw = 50% of stake lost
///   "1+25"   → win by 2+ = full, win by exactly 1 = 25% profit
///   "-36"    → win by 1+ = full, draw = half loss (blueprint -0.5)
///   "70++"   → high handicap win line pays 70% profit factor
///
/// All payouts are PROFIT factors relative to the stake:
///   total return = stake + stake * payoutFactor
///   (full win => +1.0 → returns 2x; half loss => -0.5 → returns 0.5x stake)
///
/// Mirrors web/lib/myanmar-settlement.ts and pkg/settlement (Go) so every
/// layer settles identical values.
library;

enum MMOddsStatus { win, halfWin, loss, halfLoss, draw }

class MMOddsResult {
  /// Profit factor: 1.0 full win, 0.25 (1+25), -0.5 half loss, -1.0 loss.
  final double payoutFactor;
  final MMOddsStatus status;

  const MMOddsResult({required this.payoutFactor, required this.status});
}

class MMOddsCalculator {
  MMOddsCalculator._();

  /// Total-return multiplier for the "full win" branch.
  static const double winTotalMultiplier = 2.0;

  /// Calculates Body (single bet) outcomes for the Myanmar Odds System.
  ///
  /// * [homeGoals]/[awayGoals] — final score of the settled match.
  /// * [selectedTeam] — "HOME" or "AWAY".
  /// * [handicapLine] — "1+25", "-36", "0-50", "70++", "100--", ...
  static MMOddsResult calculateBodyPayout({
    required int homeGoals,
    required int awayGoals,
    required String selectedTeam, // "HOME" or "AWAY"
    required String handicapLine, // e.g., "1+25", "-36", "0-50", "70++", "100--"
  }) {
    int diff = homeGoals - awayGoals;
    if (selectedTeam == 'AWAY') diff = -diff;

    switch (handicapLine) {
      case '0-50': // 0 Equal Line, 50% loss on draw
        if (diff > 0) {
          return const MMOddsResult(payoutFactor: 1.0, status: MMOddsStatus.win);
        }
        if (diff == 0) {
          return const MMOddsResult(
              payoutFactor: -0.5, status: MMOddsStatus.halfLoss);
        }
        return const MMOddsResult(payoutFactor: -1.0, status: MMOddsStatus.loss);

      case '1+25': // 1 Goal Handicap with +25 bonus payout on 1-goal victory
        if (diff >= 2) {
          return const MMOddsResult(payoutFactor: 1.0, status: MMOddsStatus.win);
        }
        if (diff == 1) {
          return const MMOddsResult(
              payoutFactor: 0.25, status: MMOddsStatus.halfWin);
        }
        return const MMOddsResult(payoutFactor: -1.0, status: MMOddsStatus.loss);

      case '-36': // Blueprint: win by 1+ = full, draw = 50% half loss
        if (diff >= 1) {
          return const MMOddsResult(payoutFactor: 1.0, status: MMOddsStatus.win);
        }
        if (diff == 0) {
          return const MMOddsResult(
              payoutFactor: -0.5, status: MMOddsStatus.halfLoss);
        }
        return const MMOddsResult(payoutFactor: -1.0, status: MMOddsStatus.loss);

      case '70++': // High handicap 70% win factor line
        if (diff >= 1) {
          return const MMOddsResult(payoutFactor: 0.7, status: MMOddsStatus.win);
        }
        return const MMOddsResult(payoutFactor: -1.0, status: MMOddsStatus.loss);

      default:
        if (diff > 0) {
          return const MMOddsResult(payoutFactor: 1.0, status: MMOddsStatus.win);
        }
        if (diff == 0) {
          return const MMOddsResult(payoutFactor: 0.0, status: MMOddsStatus.draw);
        }
        return const MMOddsResult(payoutFactor: -1.0, status: MMOddsStatus.loss);
    }
  }

  /// Calculates Maung (mix parlay) cumulative odds factor.
  ///
  /// A fully-lost leg voids the whole ticket (0.0x). Half outcomes scale the
  /// running product by the leg's effective multiplier (0.5x / 1.25x).
  static double calculateMaungTotalPayout(List<MMOddsResult> results) {
    double totalFactor = 1.0;
    for (var res in results) {
      if (res.status == MMOddsStatus.loss) return 0.0; // whole parlay loses
      if (res.status == MMOddsStatus.halfLoss) totalFactor *= 0.5;
      if (res.status == MMOddsStatus.halfWin) totalFactor *= 1.25;
      if (res.status == MMOddsStatus.win) totalFactor *= 2.0;
      // draw → no-op (factor unchanged)
    }
    return totalFactor;
  }

  /// Total cash returned for a stake given a profit [payoutFactor].
  static double totalReturn(double stake, double payoutFactor) =>
      stake + stake * payoutFactor;
}