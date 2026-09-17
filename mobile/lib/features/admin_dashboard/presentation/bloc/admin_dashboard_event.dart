/// Admin dashboard BLoC events (read-only) — [LoadAdminDashboardStats] on
/// mount, [RefreshAdminDashboardStats] on pull-to-refresh.
sealed class AdminDashboardEvent {
  const AdminDashboardEvent();
}

class LoadAdminDashboardStats extends AdminDashboardEvent {
  const LoadAdminDashboardStats();
}

class RefreshAdminDashboardStats extends AdminDashboardEvent {
  const RefreshAdminDashboardStats();
}