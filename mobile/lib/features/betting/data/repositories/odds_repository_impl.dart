import 'package:dio/dio.dart';

import '../../../../core/config/app_config.dart';
import '../../domain/entities/fixture.dart';
import '../../domain/repositories/odds_repository.dart';

/// Dio-backed implementation of [OddsRepository].
///
/// Talks to the Go backend (/api/v1/...) using the same wire contract as the
/// Next.js portal. The JWT is injected on construction via [tokenProvider]
/// so this layer stays Riverpod/Flutter-agnostic (Clean Architecture).
class OddsRepositoryImpl implements OddsRepository {
  final Dio _dio;
  final String? Function() _tokenProvider;
  final bool useDemoFeed;

  OddsRepositoryImpl({
    String? Function()? tokenProvider,
    this.useDemoFeed = false,
  })  : _tokenProvider = tokenProvider ?? _noopTokenProvider,
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

  @override
  Future<List<FixtureTeam>> fetchEnabledFixtures() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/api/v1/user/fixtures',
        options: _auth(),
      );
      final list = res.data?['fixtures'] as List<dynamic>? ?? [];
      return list
          .map((e) => FixtureTeam.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      // The user-facing feed endpoint is not deployed yet. Until it lands,
      // fall back to demo data for local development only (never in prod).
      // @audit remove when GET /api/v1/user/fixtures ships.
      final isMissing = e.response?.statusCode == 404 ||
          e.response?.statusCode == 501 ||
          e.type == DioExceptionType.connectionError;
      if (useDemoFeed && isMissing) {
        return _demoFixtures();
      }
      rethrow;
    }
  }

  @override
  Future<BetPlacement> placeBodyBet({
    required int fixtureId,
    required SelectionPick pick,
    required double stake,
    required String handicap,
  }) {
    final input = PlaceBetInput(
      betType: 'BODY',
      totalStake: stake,
      selections: [
        SelectionInput(matchId: fixtureId, pick: pick, bodyOddsType: handicap),
      ],
    );
    return _place(input.toJson());
  }

  @override
  Future<BetPlacement> placeMaungBet({
    required List<SelectionInput> selections,
    required double stake,
  }) {
    return _place(
      PlaceBetInput(betType: 'MAUNG', totalStake: stake, selections: selections)
          .toJson(),
    );
  }

  Future<BetPlacement> _place(Map<String, dynamic> payload) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/api/v1/user/bets',
      data: payload,
      options: _auth(),
    );
    return BetPlacement.fromJson(res.data ?? const {});
  }

  List<FixtureTeam> _demoFixtures() => const [];
}