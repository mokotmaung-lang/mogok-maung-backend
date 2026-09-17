import 'package:get_it/get_it.dart';

import '../config/app_config.dart';
import '../network/api_client.dart';
import '../network/live_odds_client.dart';
import '../../features/admin_dashboard/data/datasources/admin_remote_ds.dart';
import '../../features/admin_dashboard/data/repositories/admin_repository_impl.dart';
import '../../features/admin_dashboard/domain/repositories/admin_repository.dart';
import '../../features/admin_dashboard/domain/usecases/get_admin_dashboard_stats.dart';
import '../../features/betting/data/repositories/odds_repository_impl.dart';
import '../../features/betting/domain/repositories/odds_repository.dart';
import '../../features/history/data/bet_history_repository.dart';
import '../../features/wallet/data/wallet_repository.dart';
import '../../features/wallet/data/unit_request_repository.dart';
import '../../features/security_settings/data/security_settings_repository.dart';

/// Global service locator (get_it).
///
/// Wired in main(): `setupServiceLocator()` then `await sl.getAsync...`.
/// The session token is injected via [_sessionToken] so repositories stay
/// framework-agnostic (Clean Architecture) while sharing one bearer credential.
final GetIt sl = GetIt.instance;

void setupServiceLocator() {
  sl.registerLazySingleton<OddsRepository>(
    () => OddsRepositoryImpl(
      tokenProvider: () => _sessionToken,
      useDemoFeed: const bool.fromEnvironment('MGM_DEMO_FEED'),
    ),
  );
  sl.registerLazySingleton<WalletRepository>(
    () => WalletRepository(
      client: ApiClient(baseUrl: AppConfig.apiBaseUrl, token: _sessionToken),
    ),
  );
  sl.registerLazySingleton<LiveOddsClient>(
    () => LiveOddsClient(tokenProvider: () => _sessionToken),
  );
  sl.registerLazySingleton<BetHistoryRepository>(
    () => BetHistoryRepository(
      client: ApiClient(baseUrl: AppConfig.apiBaseUrl, token: _sessionToken),
    ),
  );
  sl.registerLazySingleton<SecuritySettingsRepository>(
    () => SecuritySettingsRepository(
      client: ApiClient(baseUrl: AppConfig.apiBaseUrl, token: _sessionToken),
    ),
  );
  sl.registerLazySingleton<UnitRequestRepository>(
    () => UnitRequestRepository(
      client: ApiClient(baseUrl: AppConfig.apiBaseUrl, token: _sessionToken),
    ),
  );
  sl.registerLazySingleton<AdminRemoteDataSource>(
    () => AdminRemoteDataSource(tokenProvider: () => _sessionToken),
  );
  sl.registerLazySingleton<AdminRepository>(
    () => AdminRepositoryImpl(sl<AdminRemoteDataSource>()),
  );
  sl.registerLazySingleton<GetAdminDashboardStats>(
    () => GetAdminDashboardStats(sl<AdminRepository>()),
  );
}

/// Set once at app start (from the Riverpod session provider) before login.
String? _sessionToken;
void setSessionToken(String? token) => _sessionToken = token;