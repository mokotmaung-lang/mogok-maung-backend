import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/service_locator.dart';
import '../../domain/usecases/get_admin_dashboard_stats.dart';
import 'admin_dashboard_event.dart';
import 'admin_dashboard_state.dart';

/// Read-only admin control-plane dashboard.
///
/// Loads agents + fixtures + weekly settlement in parallel via
/// [GetAdminDashboardStats]; never mutates server state (GET only).
class AdminDashboardBloc
    extends Bloc<AdminDashboardEvent, AdminDashboardState> {
  final GetAdminDashboardStats _getStats;

  AdminDashboardBloc(this._getStats)
      : super(const AdminDashboardInitial()) {
    on<LoadAdminDashboardStats>(_load);
    on<RefreshAdminDashboardStats>(_load);
  }

  Future<void> _load(
    AdminDashboardEvent event,
    Emitter<AdminDashboardState> emit,
  ) async {
    emit(const AdminDashboardLoading());
    try {
      final stats = await _getStats();
      emit(AdminDashboardLoaded(stats));
    } catch (e) {
      emit(AdminDashboardError(_errorMessage(e)));
    }
  }

  String _errorMessage(Object error) {
    final message = '$error';
    if (message.contains('401')) return 'session expired';
    if (message.contains('403')) return 'forbidden';
    return 'load failed';
  }
}

/// Wires the bloc from the get_it container (registered in service_locator).
AdminDashboardBloc createAdminDashboardBloc() =>
    AdminDashboardBloc(sl<GetAdminDashboardStats>());