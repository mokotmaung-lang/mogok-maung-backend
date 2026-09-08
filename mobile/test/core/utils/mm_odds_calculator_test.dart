import 'package:flutter_test/flutter_test.dart';
import 'package:mogok_maung_mobile/core/utils/mm_odds_calculator.dart';

void main() {
  group('MMOddsCalculator.calculateBodyPayout — 0-50', () {
    test('home win -> full win', () {
      final r = MMOddsCalculator.calculateBodyPayout(
        homeGoals: 2, awayGoals: 0, selectedTeam: 'HOME', handicapLine: '0-50');
      expect(r.status, MMOddsStatus.win);
      expect(r.payoutFactor, 1.0);
    });

    test('draw -> half loss', () {
      final r = MMOddsCalculator.calculateBodyPayout(
        homeGoals: 1, awayGoals: 1, selectedTeam: 'HOME', handicapLine: '0-50');
      expect(r.status, MMOddsStatus.halfLoss);
      expect(r.payoutFactor, -0.5);
    });

    test('away loss on draw (away side) -> half loss', () {
      final r = MMOddsCalculator.calculateBodyPayout(
        homeGoals: 1, awayGoals: 1, selectedTeam: 'AWAY', handicapLine: '0-50');
      expect(r.status, MMOddsStatus.halfLoss);
    });

    test('home loss -> full loss', () {
      final r = MMOddsCalculator.calculateBodyPayout(
        homeGoals: 0, awayGoals: 3, selectedTeam: 'HOME', handicapLine: '0-50');
      expect(r.status, MMOddsStatus.loss);
      expect(r.payoutFactor, -1.0);
    });
  });

  group('MMOddsCalculator.calculateBodyPayout — 1+25', () {
    test('win by 2+ -> full win', () {
      final r = MMOddsCalculator.calculateBodyPayout(
        homeGoals: 3, awayGoals: 1, selectedTeam: 'HOME', handicapLine: '1+25');
      expect(r.status, MMOddsStatus.win);
    });

    test('win by exactly 1 -> 25% half win', () {
      final r = MMOddsCalculator.calculateBodyPayout(
        homeGoals: 2, awayGoals: 1, selectedTeam: 'HOME', handicapLine: '1+25');
      expect(r.status, MMOddsStatus.halfWin);
      expect(r.payoutFactor, 0.25);
    });

    test('draw -> full loss for the favourite', () {
      final r = MMOddsCalculator.calculateBodyPayout(
        homeGoals: 1, awayGoals: 1, selectedTeam: 'HOME', handicapLine: '1+25');
      expect(r.status, MMOddsStatus.loss);
    });
  });

  group('MMOddsCalculator.calculateBodyPayout — -36 (draw = half loss)', () {
    test('win by 1+ -> full win', () {
      final r = MMOddsCalculator.calculateBodyPayout(
        homeGoals: 1, awayGoals: 0, selectedTeam: 'HOME', handicapLine: '-36');
      expect(r.status, MMOddsStatus.win);
      expect(r.payoutFactor, 1.0);
    });

    test('draw -> HALF_LOSE convention (0.64x offline, math -0.5 factor)', () {
      final r = MMOddsCalculator.calculateBodyPayout(
        homeGoals: 0, awayGoals: 0, selectedTeam: 'HOME', handicapLine: '-36');
      expect(r.status, MMOddsStatus.halfLoss);
      expect(r.payoutFactor, -0.5);
    });

    test('loss -> full loss', () {
      final r = MMOddsCalculator.calculateBodyPayout(
        homeGoals: 0, awayGoals: 1, selectedTeam: 'HOME', handicapLine: '-36');
      expect(r.status, MMOddsStatus.loss);
    });
  });

  group('MMOddsCalculator.calculateBodyPayout — 70++', () {
    test('win -> 70% profit factor', () {
      final r = MMOddsCalculator.calculateBodyPayout(
        homeGoals: 2, awayGoals: 0, selectedTeam: 'HOME', handicapLine: '70++');
      expect(r.status, MMOddsStatus.win);
      expect(r.payoutFactor, 0.7);
    });

    test('non-win -> full loss', () {
      final r = MMOddsCalculator.calculateBodyPayout(
        homeGoals: 0, awayGoals: 0, selectedTeam: 'HOME', handicapLine: '70++');
      expect(r.status, MMOddsStatus.loss);
    });
  });

  group('MMOddsCalculator.calculateMaungTotalPayout', () {
    const win = MMOddsResult(payoutFactor: 1.0, status: MMOddsStatus.win);
    const loss = MMOddsResult(payoutFactor: -1.0, status: MMOddsStatus.loss);
    const halfWin = MMOddsResult(payoutFactor: 0.25, status: MMOddsStatus.halfWin);
    const halfLoss =
        MMOddsResult(payoutFactor: -0.5, status: MMOddsStatus.halfLoss);
    const draw = MMOddsResult(payoutFactor: 0.0, status: MMOddsStatus.draw);

    test('all wins -> 2^n', () {
      expect(
        MMOddsCalculator.calculateMaungTotalPayout([win, win, win]),
        8.0,
      );
    });

    test('any loss voids the whole parlay', () {
      expect(
        MMOddsCalculator.calculateMaungTotalPayout([win, loss, win]),
        0.0,
      );
    });

    test('half outcomes scale the running product', () {
      expect(
        MMOddsCalculator.calculateMaungTotalPayout([win, halfWin]),
        2.5,
      );
      expect(
        MMOddsCalculator.calculateMaungTotalPayout([win, halfLoss]),
        1.0,
      );
    });

    test('draw is a no-op', () {
      expect(
        MMOddsCalculator.calculateMaungTotalPayout([win, draw, win]),
        4.0,
      );
    });

    test('single bone loses -> 0', () {
      expect(MMOddsCalculator.calculateMaungTotalPayout(const [loss]), 0.0);
    });
  });

  group('MMOddsCalculator.totalReturn', () {
    test('full win returns 2x stake', () {
      expect(MMOddsCalculator.totalReturn(100, 1.0), 200);
    });

    test('half loss returns half the stake', () {
      expect(MMOddsCalculator.totalReturn(100, -0.5), 50);
    });

    test('ten-token 70++ win returns 170%' , () {
      expect(MMOddsCalculator.totalReturn(200, 0.7), closeTo(340, 0.001));
    });
  });
}