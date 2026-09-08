/// Compile-time-friendly app configuration for the Mogok Maung mobile client.
class AppConfig {
  AppConfig._();

  /// Base origin of the Go backend. Override per environment (dev/staging/prod).
  static const String apiBaseUrl = 'https://myanmarbet.com';

  /// Live odds WebSocket gateway origin.
  static const String wsBaseUrl = 'wss://myanmarbet.com';

  /// How often (ms) the wallet balance stream refreshes from the backend.
  static const Duration balanceRefreshInterval = Duration(seconds: 5);
}