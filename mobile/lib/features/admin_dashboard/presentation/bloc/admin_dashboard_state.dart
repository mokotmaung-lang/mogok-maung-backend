import '../../domain/entities/admin_stats_entity.dart';

/// Admin dashboard BLoC states.
sealed class AdminDashboardState {
  const AdminDashboardState();
}

/// Initial state before the first [LoadAdminDashboardStats] fires.
class AdminDashboardInitial extends AdminDashboardState {
  const AdminDashboardInitial();
}

/// A fetch is in flight (first load or refresh).
class AdminDashboardLoading extends AdminDashboardState {
  const AdminDashboardLoading();
}

/// Read-only snapshot successfully loaded.
class AdminDashboardLoaded extends AdminDashboardState {
  final AdminDashboardStats stats;

  const AdminDashboardLoaded(this.stats);
}

/// The fetch failed; [error] is safe to surface in the UI.
class AdminDashboardError extends AdminDashboardState {
  final String error;

  const AdminDashboardError(this.error);
}