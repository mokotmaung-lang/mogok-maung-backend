import '../../../core/network/api_client.dart';

/// Data source for the account security settings (POST /api/v1/user/password).
class SecuritySettingsRepository {
  final ApiClient client;

  SecuritySettingsRepository({required this.client});

  /// Rotates the caller's password. Requires the current password; the backend
  /// returns 401 if it does not match and enforces a minimum 8-char new
  /// password.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await client.post('/api/v1/user/password', body: {
      'current_password': currentPassword,
      'new_password': newPassword,
    });
  }
}