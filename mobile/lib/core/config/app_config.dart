/// Compile-time-friendly app configuration for the Mogok Maung mobile client.
///
/// Both URLs are overridable at build/run time via
/// `--dart-define=API_BASE_URL=...` and `--dart-define=WS_BASE_URL=...`. The
/// default points at the local Go backend (host-run on :8081):
///   Android emulator:  http://10.0.2.2:8081   (host loopback alias)
///   Windows desktop:   http://localhost:8081
///   Web/Chrome:        http://localhost:8081
/// Supply `--dart-define` with the production origin for staging/prod builds.
class AppConfig {
  AppConfig._();

  /// Base origin of the Go backend. Override per environment (dev/staging/prod).
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8081',
  );

  /// Live odds WebSocket gateway origin.
  static const String wsBaseUrl = String.fromEnvironment(
    'WS_BASE_URL',
    defaultValue: 'ws://localhost:8081',
  );

  /// How often (ms) the wallet balance stream refreshes from the backend.
  static const Duration balanceRefreshInterval = Duration(seconds: 5);
}