import 'package:flutter/foundation.dart';

/// One leg of a bet: the match, the pick and the odds the settlement applied.
@immutable
class BetSelectionDetail {
  final int matchId;
  final String homeTeam;
  final String awayTeam;
  final String pick; // HOME | AWAY | DRAW
  final String bodyOddsType; // handicap string, e.g. "1+50"
  final double oddsUsed; // multiplier the settlement applied
  final String result; // WIN/LOSE/DRAW/HALF_WIN/HALF_LOSE/PENDING

  const BetSelectionDetail({
    required this.matchId,
    required this.homeTeam,
    required this.awayTeam,
    required this.pick,
    required this.bodyOddsType,
    required this.oddsUsed,
    required this.result,
  });

  factory BetSelectionDetail.fromJson(Map<String, dynamic> json) =>
      BetSelectionDetail(
        matchId: (json['match_id'] as num?)?.toInt() ?? 0,
        homeTeam: json['home_team'] as String? ?? '',
        awayTeam: json['away_team'] as String? ?? '',
        pick: ((json['pick'] as String?) ?? 'HOME').toUpperCase(),
        bodyOddsType: json['body_odds_type'] as String? ?? '',
        oddsUsed: (json['odds_used'] as num?)?.toDouble() ?? 1.0,
        result: ((json['result'] as String?) ?? 'PENDING').toUpperCase(),
      );
}

/// One row of the user's wagering history (GET /api/v1/user/bets).
///
/// Mirrors the backend `betHistoryItem` JSON shape; tolerates the legacy
/// `stake` alias in case older API versions only sent that field.
@immutable
class BetHistoryItem {
  final int betId;
  final String betType; // BODY | MAUNG
  final double totalStake;
  final double holdAmount;
  final double potentialPayout;
  final String status; // PENDING | APPROVED | REJECTED
  final int selectionsCount;
  final DateTime createdAt;
  final List<BetSelectionDetail> selections;

  const BetHistoryItem({
    required this.betId,
    required this.betType,
    required this.totalStake,
    required this.holdAmount,
    required this.potentialPayout,
    required this.status,
    required this.selectionsCount,
    required this.createdAt,
    required this.selections,
  });

  factory BetHistoryItem.fromJson(Map<String, dynamic> json) {
    final double stake =
        (json['total_stake'] as num?)?.toDouble() ??
        (json['stake'] as num?)?.toDouble() ??
        0;
    return BetHistoryItem(
      betId: (json['bet_id'] as num?)?.toInt() ?? 0,
      betType: ((json['bet_type'] as String?) ?? 'BODY').toUpperCase(),
      totalStake: stake,
      holdAmount: (json['hold_amount'] as num?)?.toDouble() ?? 0,
      potentialPayout: (json['potential_payout'] as num?)?.toDouble() ?? 0,
      status: ((json['status'] as String?) ?? 'PENDING').toUpperCase(),
      selectionsCount: (json['selections_count'] as num?)?.toInt() ?? 1,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '')
              ?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      selections: (json['selections'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(BetSelectionDetail.fromJson)
          .toList(),
    );
  }

  bool get isPending => status == 'PENDING';
  bool get isApproved => status == 'APPROVED';
  bool get isMaung => betType == 'MAUNG';
}