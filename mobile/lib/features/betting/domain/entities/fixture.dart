/// Domain entities for the betting feature.
library;

/// Wire-format pick sent to the backend ("HOME" | "AWAY").
enum SelectionPick {
  home,
  away,
}

extension SelectionPickWire on SelectionPick {
  String get wireName => this == SelectionPick.home ? 'HOME' : 'AWAY';
}

/// A match presented to the bettor, mirroring the backend fixture feed.
class FixtureTeam {
  final int id;
  final String homeTeam;
  final String awayTeam;
  final String leagueName;
  final DateTime matchTime;
  final bool isEnabled;
  final String handicap; // Myanmar odds string locked on the ticket, e.g. "1+25"
  final String handicapSide; // "HOME" | "AWAY"
  final double homeBodyPayout;
  final double awayBodyPayout;
  final double homeMaungMultiplier;
  final double awayMaungMultiplier;

  const FixtureTeam({
    required this.id,
    required this.homeTeam,
    required this.awayTeam,
    required this.leagueName,
    required this.matchTime,
    required this.isEnabled,
    required this.handicap,
    required this.handicapSide,
    required this.homeBodyPayout,
    required this.awayBodyPayout,
    required this.homeMaungMultiplier,
    required this.awayMaungMultiplier,
  });

  factory FixtureTeam.fromJson(Map<String, dynamic> json) => FixtureTeam(
        id: (json['id'] ?? json['fixture_id']!) as int,
        homeTeam: json['home_team'] as String? ?? '',
        awayTeam: json['away_team'] as String? ?? '',
        leagueName: json['league_name'] as String? ?? '',
        matchTime: DateTime.tryParse(json['match_time'] as String? ?? '') ??
            DateTime.now(),
        isEnabled: (json['status'] as String? ?? 'OPEN') == 'OPEN',
        handicap: json['handicap'] as String? ?? '',
        handicapSide: json['handicap_side'] as String? ?? 'HOME',
        homeBodyPayout: (json['home_body_payout'] as num?)?.toDouble() ?? 1.0,
        awayBodyPayout: (json['away_body_payout'] as num?)?.toDouble() ?? 1.0,
        homeMaungMultiplier:
            (json['maung_home_multiplier'] as num?)?.toDouble() ?? 1.0,
        awayMaungMultiplier:
            (json['maung_away_multiplier'] as num?)?.toDouble() ?? 1.0,
      );

  double payoutFor(SelectionPick pick) =>
      pick == SelectionPick.home ? homeBodyPayout : awayBodyPayout;
}

/// One selection inside a ticket placed with the backend.
class SelectionInput {
  final int matchId;
  final SelectionPick pick;
  final String? bodyOddsType;

  const SelectionInput({
    required this.matchId,
    required this.pick,
    this.bodyOddsType,
  });

  Map<String, dynamic> toJson() => {
        'match_id': matchId,
        'pick': pick.wireName,
        if (bodyOddsType != null && bodyOddsType!.isNotEmpty)
          'body_odds_type': bodyOddsType,
      };
}

/// Payload for POST /api/v1/user/bets.
class PlaceBetInput {
  final String betType; // "BODY" | "MAUNG"
  final double totalStake;
  final List<SelectionInput> selections;

  const PlaceBetInput({
    required this.betType,
    required this.totalStake,
    required this.selections,
  });

  Map<String, dynamic> toJson() => {
        'bet_type': betType,
        'total_stake': totalStake,
        'selections': selections.map((s) => s.toJson()).toList(),
      };
}

/// Confirmation returned by the backend after a successful placement.
class BetPlacement {
  final int betId;
  final double holdAmount;
  final double currentBalance;

  const BetPlacement({
    required this.betId,
    required this.holdAmount,
    required this.currentBalance,
  });

  factory BetPlacement.fromJson(Map<String, dynamic> json) => BetPlacement(
        betId: (json['bet_id'] ?? json['id']!) as int,
        holdAmount: (json['hold_amount'] as num?)?.toDouble() ?? 0,
        currentBalance: (json['current_balance'] as num?)?.toDouble() ?? 0,
      );
}