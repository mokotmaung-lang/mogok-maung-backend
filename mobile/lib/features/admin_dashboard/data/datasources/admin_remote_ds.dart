import 'package:dio/dio.dart';

import '../../../../core/config/app_config.dart';

/// Dio-backed remote data source for the admin control plane.
///
/// Read-only by contract: exposes only the GET endpoints consumed by the
/// dashboard. Money-mutating admin routes are intentionally NOT reachable
/// from the mobile admin feature.
class AdminRemoteDataSource {
  final Dio _dio;
  final String? Function() _tokenProvider;

  AdminRemoteDataSource({String? Function()? tokenProvider})
      : _tokenProvider = tokenProvider ?? _noopTokenProvider,
        _dio = Dio(
          BaseOptions(
            baseUrl: AppConfig.apiBaseUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 15),
            headers: {'Content-Type': 'application/json'},
          ),
        );

  static String? _noopTokenProvider() => null;

  Options _auth() {
    final token = _tokenProvider();
    return Options(headers: {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    });
  }

  Future<Map<String, dynamic>> listAgents() async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/api/v1/admin/agents',
      options: _auth(),
    );
    final data = (res.data?['data'] as Map<String, dynamic>?) ?? const {};
    final agents = (data['agents'] as List<dynamic>?) ?? const [];
    return {'agents': agents};
  }

  Future<Map<String, dynamic>> listFixtures() async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/api/v1/admin/fixtures',
      options: _auth(),
    );
    return res.data ?? const {};
  }

  Future<Map<String, dynamic>> weeklySettlement() async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/api/v1/settlements/weekly',
      options: _auth(),
    );
    final data = (res.data?['data'] as Map<String, dynamic>?) ?? const {};
    return data;
  }
}