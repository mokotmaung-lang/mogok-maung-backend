import '../entities/admin_stats_entity.dart';

/// Repository contract for the admin control-plane (read-only data source).
///
/// Implemented in the data layer ([AdminRemoteDataSource]); consumed by
/// use-cases and BLoCs (Clean Architecture — the presentation layer never
/// touches Dio/HTTP directly).
abstract class AdminRepository {
  /// All AGENT-role users, oldest agent first.
  Future<List<AgentEntity>> fetchAgents();

  /// All fixtures for the control plane, ascending by match time.
  Future<List<FixtureEntity>> fetchFixtures();

  /// House-wide weekly settlement aggregate (agent_id = 0 when unfiltered).
  Future<SettlementEntity> fetchWeeklySettlement();
}