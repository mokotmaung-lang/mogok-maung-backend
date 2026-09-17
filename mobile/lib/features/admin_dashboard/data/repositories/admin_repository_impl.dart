import 'package:dio/dio.dart';

import '../../domain/entities/admin_stats_entity.dart';
import '../../domain/repositories/admin_repository.dart';
import '../datasources/admin_remote_ds.dart';
import '../models/admin_stats_model.dart';

/// Dio-backed implementation of [AdminRepository].
///
/// Pure delegation: parses the wire contract into models and maps them to
/// domain entities. No business logic lives here (Clean Architecture).
class AdminRepositoryImpl implements AdminRepository {
  final AdminRemoteDataSource _dataSource;

  AdminRepositoryImpl(this._dataSource);

  @override
  Future<List<AgentEntity>> fetchAgents() async {
    final json = await _dataSource.listAgents();
    final agents = (json['agents'] as List<dynamic>?) ?? const [];
    return agents
        .map((e) => AgentModel.fromJson(e as Map<String, dynamic>).toEntity())
        .toList();
  }

  @override
  Future<List<FixtureEntity>> fetchFixtures() async {
    final json = await _dataSource.listFixtures();
    final fixtures = (json['fixtures'] as List<dynamic>?) ?? const [];
    return fixtures
        .map((e) =>
            FixtureModel.fromJson(e as Map<String, dynamic>).toEntity())
        .toList();
  }

  @override
  Future<SettlementEntity> fetchWeeklySettlement() async {
    final json = await _dataSource.weeklySettlement();
    return SettlementModel.fromJson(json).toEntity();
  }
}

/// Maps transport failures (DioException, network) into a stable error the
/// BLoC/UI can surface without leaking internals.
class AdminDataException implements Exception {
  final String message;

  const AdminDataException(this.message);

  @override
  String toString() => message;
}

AdminDataException mapAdminError(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status != null && status >= 400) return AdminDataException('API $status');
    return const AdminDataException('network');
  }
  return const AdminDataException('error');
}