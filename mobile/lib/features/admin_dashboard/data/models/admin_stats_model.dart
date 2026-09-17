/// JSON models mirroring the Go backend wire contract. Conversions stay in
/// this feature's data layer; domain code only sees [AdminDashboardStats].
library;

import '../../domain/entities/admin_stats_entity.dart';

class AgentModel {
  final int id;
  final String username;
  final String name;
  final double currentBalance;
  final double holdBalance;
  final int activeUsersCount;
  final String status;

  const AgentModel({
    required this.id,
    required this.username,
    required this.name,
    required this.currentBalance,
    required this.holdBalance,
    required this.activeUsersCount,
    required this.status,
  });

  factory AgentModel.fromJson(Map<String, dynamic> json) => AgentModel(
        id: (json['id'] as num?)?.toInt() ?? 0,
        username: json['username'] as String? ?? '',
        name: json['name'] as String? ?? '',
        currentBalance: (json['current_balance'] as num?)?.toDouble() ?? 0,
        holdBalance: (json['hold_balance'] as num?)?.toDouble() ?? 0,
        activeUsersCount: (json['active_users_count'] as num?)?.toInt() ?? 0,
        status: json['status'] as String? ?? 'SUSPENDED',
      );

  AgentEntity toEntity() => AgentEntity(
        id: id,
        username: username,
        name: name,
        currentBalance: currentBalance,
        holdBalance: holdBalance,
        activeUsersCount: activeUsersCount,
        status: status,
      );
}

class FixtureModel {
  final int id;
  final String homeTeam;
  final String awayTeam;
  final String leagueName;
  final DateTime matchTime;
  final String handicapSide;
  final String handicap;
  final double homeBodyPayout;
  final double awayBodyPayout;
  final double maungHomeMultiplier;
  final double maungAwayMultiplier;
  final double maungDrawMultiplier;
  final String status;

  const FixtureModel({
    required this.id,
    required this.homeTeam,
    required this.awayTeam,
    required this.leagueName,
    required this.matchTime,
    required this.handicapSide,
    required this.handicap,
    required this.homeBodyPayout,
    required this.awayBodyPayout,
    required this.maungHomeMultiplier,
    required this.maungAwayMultiplier,
    required this.maungDrawMultiplier,
    required this.status,
  });

  factory FixtureModel.fromJson(Map<String, dynamic> json) => FixtureModel(
        id: (json['id'] as num?)?.toInt() ?? 0,
        homeTeam: json['home_team'] as String? ?? '',
        awayTeam: json['away_team'] as String? ?? '',
        leagueName: json['league_name'] as String? ?? '',
        matchTime:
            DateTime.tryParse(json['match_time'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
        handicapSide: json['handicap_side'] as String? ?? '',
        handicap: json['handicap'] as String? ?? '',
        homeBodyPayout: (json['home_body_payout'] as num?)?.toDouble() ?? 0,
        awayBodyPayout: (json['away_body_payout'] as num?)?.toDouble() ?? 0,
        maungHomeMultiplier:
            (json['maung_home_multiplier'] as num?)?.toDouble() ?? 0,
        maungAwayMultiplier:
            (json['maung_away_multiplier'] as num?)?.toDouble() ?? 0,
        maungDrawMultiplier:
            (json['maung_draw_multiplier'] as num?)?.toDouble() ?? 0,
        status: json['status'] as String? ?? 'CLOSED',
      );

  FixtureEntity toEntity() => FixtureEntity(
        id: id,
        homeTeam: homeTeam,
        awayTeam: awayTeam,
        leagueName: leagueName,
        matchTime: matchTime,
        handicapSide: handicapSide,
        handicap: handicap,
        homeBodyPayout: homeBodyPayout,
        awayBodyPayout: awayBodyPayout,
        maungHomeMultiplier: maungHomeMultiplier,
        maungAwayMultiplier: maungAwayMultiplier,
        maungDrawMultiplier: maungDrawMultiplier,
        status: status,
      );
}

class SettlementModel {
  final int agentId;
  final String agentName;
  final String billingPeriod;
  final int totalBetsCount;
  final double totalTurnover;
  final double totalPayoutWin;
  final double totalRetainedLose;
  final double netSettlementAmount;
  final String settlementStatus;

  const SettlementModel({
    required this.agentId,
    required this.agentName,
    required this.billingPeriod,
    required this.totalBetsCount,
    required this.totalTurnover,
    required this.totalPayoutWin,
    required this.totalRetainedLose,
    required this.netSettlementAmount,
    required this.settlementStatus,
  });

  factory SettlementModel.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> summary =
        (json['summary'] as Map<String, dynamic>?) ?? const {};
    return SettlementModel(
      agentId: (json['agent_id'] as num?)?.toInt() ?? 0,
      agentName: json['agent_name'] as String? ?? '',
      billingPeriod: json['billing_period'] as String? ?? '',
      totalBetsCount: (summary['total_bets_count'] as num?)?.toInt() ?? 0,
      totalTurnover: (summary['total_turnover'] as num?)?.toDouble() ?? 0,
      totalPayoutWin: (summary['total_payout_win'] as num?)?.toDouble() ?? 0,
      totalRetainedLose:
          (summary['total_retained_lose'] as num?)?.toDouble() ?? 0,
      netSettlementAmount:
          (summary['net_settlement_amount'] as num?)?.toDouble() ?? 0,
      settlementStatus: summary['settlement_status'] as String? ?? 'NONE',
    );
  }

  SettlementEntity toEntity() => SettlementEntity(
        agentId: agentId,
        agentName: agentName,
        billingPeriod: billingPeriod,
        totalBetsCount: totalBetsCount,
        totalTurnover: totalTurnover,
        totalPayoutWin: totalPayoutWin,
        totalRetainedLose: totalRetainedLose,
        netSettlementAmount: netSettlementAmount,
        settlementStatus: settlementStatus,
      );
}