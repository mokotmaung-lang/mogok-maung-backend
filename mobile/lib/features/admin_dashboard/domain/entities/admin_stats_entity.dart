/// Domain entities for the admin control-plane dashboard (read-only).
///
/// These are pure Dart values — no Flutter/package imports — so business
/// logic stays testable and framework-agnostic (Clean Architecture).
library;

/// Control-plane view of an AGENT-role user.
class AgentEntity {
  final int id;
  final String username;
  final String name;
  final double currentBalance;
  final double holdBalance;
  final int activeUsersCount;
  final String status; // ACTIVE | SUSPENDED

  const AgentEntity({
    required this.id,
    required this.username,
    required this.name,
    required this.currentBalance,
    required this.holdBalance,
    required this.activeUsersCount,
    required this.status,
  });

  bool get isActive => status == 'ACTIVE';
}

/// Read-only fixture snapshot (BODY/MAUNG odds) for the control plane.
class FixtureEntity {
  final int id;
  final String homeTeam;
  final String awayTeam;
  final String leagueName;
  final DateTime matchTime;
  final String handicapSide;
  final String handicap; // Myanmar odds, e.g. "1+25"
  final double homeBodyPayout;
  final double awayBodyPayout;
  final double maungHomeMultiplier;
  final double maungAwayMultiplier;
  final double maungDrawMultiplier;
  final String status; // OPEN | CLOSED | FINISHED

  const FixtureEntity({
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

  bool get isOpen => status == 'OPEN';
}

/// House-wide weekly settlement aggregate (agent_id = 0 when unfiltered).
class SettlementEntity {
  final int agentId;
  final String agentName;
  final String billingPeriod;
  final int totalBetsCount;
  final double totalTurnover;
  final double totalPayoutWin;
  final double totalRetainedLose;
  final double netSettlementAmount;
  final String settlementStatus; // NONE | PENDING | SETTLED

  const SettlementEntity({
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
}

/// Aggregated snapshot backing the admin dashboard screen (read-only).
///
/// [countActiveAgents] / [countOpenFixtures] are derived views so the UI never
/// drives side effects from this data.
class AdminDashboardStats {
  final List<AgentEntity> agents;
  final List<FixtureEntity> fixtures;
  final SettlementEntity settlement;

  const AdminDashboardStats({
    this.agents = const [],
    this.fixtures = const [],
    required this.settlement,
  });

  int get countActiveAgents =>
      agents.where((agent) => agent.isActive).length;

  int get countOpenFixtures =>
      fixtures.where((fixture) => fixture.isOpen).length;
}