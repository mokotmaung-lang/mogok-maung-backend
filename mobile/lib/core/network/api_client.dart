import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Thin JSON HTTP wrapper that attaches the Bearer token to every request.
///
/// Failure taxonomy (kept explicit so the UI can react sensibly):
///  * HTTP-level errors (>= 400)  -> [ApiException]
///  * Timeouts / socket / network -> [NetworkException] (isOffline: true)
///
/// The [httpClient] is injectable for tests (`package:http/testing.dart`'s
/// MockClient) — production uses the default client.
class ApiClient {
  final String baseUrl;
  final String? token;
  final http.Client _http;

  static const Duration _receiveTimeout = Duration(seconds: 15);

  ApiClient({
    required this.baseUrl,
    this.token,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> get(String path) async {
    try {
      final res = await _http
          .get(Uri.parse('$baseUrl$path'), headers: _headers)
          .timeout(_receiveTimeout);
      return _decode(res);
    } on TimeoutException {
      throw NetworkException(
        message: 'Request timed out (${_receiveTimeout.inSeconds}s)',
        isOffline: true,
      );
    } on SocketException catch (e) {
      throw NetworkException(message: 'No connection: ${e.message}');
    } on http.ClientException catch (e) {
      throw NetworkException(message: e.message);
    }
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    try {
      final res = await _http
          .post(
            Uri.parse('$baseUrl$path'),
            headers: _headers,
            body: jsonEncode(body ?? const {}),
          )
          .timeout(_receiveTimeout);
      return _decode(res);
    } on TimeoutException {
      throw NetworkException(
        message: 'Request timed out (${_receiveTimeout.inSeconds}s)',
        isOffline: true,
      );
    } on SocketException catch (e) {
      throw NetworkException(message: 'No connection: ${e.message}');
    } on http.ClientException catch (e) {
      throw NetworkException(message: e.message);
    }
  }

  Map<String, dynamic> _decode(http.Response res) {
    final Object? decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    if (res.statusCode >= 400) {
      final String message = decoded is Map<String, dynamic>
          ? (decoded['error'] as String? ?? 'request failed')
          : 'request failed';
      throw ApiException(statusCode: res.statusCode, message: message);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ApiException(statusCode: 500, message: 'malformed response');
    }
    return decoded;
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException({required this.statusCode, required this.message});

  /// Sentinel code the server returns while the default password is pending.
  static const String passwordChangeRequired = 'PASSWORD_CHANGE_REQUIRED';

  bool get isPasswordChangeRequired =>
      message == passwordChangeRequired && statusCode == 403;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Transport-level failure (offline, DNS, timeout). The UI treats this as
/// "no internet" rather than a server error.
class NetworkException implements Exception {
  final String message;
  final bool isOffline;

  const NetworkException({
    required this.message,
    this.isOffline = true,
  });

  @override
  String toString() => 'NetworkException($isOffline): $message';
}