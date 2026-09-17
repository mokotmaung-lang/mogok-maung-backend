import '../entities/admin_stats_entity.dart';
import '../repositories/admin_repository.dart';

/// Loads the full read-only admin snapshot: agents + fixtures + weekly
/// settlement. The dashboard BLoC fires this once on mount and again on
/// pull-to-refresh.
class GetAdminDashboardStats {
  final AdminRepository _repository;

  GetAdminDashboardStats(this._repository);

  Future<AdminDashboardStats> call() async {
    final (agents, fixtures, settlement) = await (
      _repository.fetchAgents(),
      _repository.fetchFixtures(),
      _repository.fetchWeeklySettlement(),
    ).wait;
    return AdminDashboardStats(
      agents: agents,
      fixtures: fixtures,
      settlement: settlement,
    );
  }
}