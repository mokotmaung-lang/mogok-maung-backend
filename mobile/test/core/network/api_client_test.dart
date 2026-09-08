import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mogok_maung_mobile/core/network/api_client.dart';

void main() {
  group('ApiClient.get', () {
    test('attaches bearer token and decodes a JSON body', () async {
      late http.Request captured;
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        token: 'secret-token',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response('{"success":true,"data":{}}', 200,
              headers: {'content-type': 'application/json'});
        }),
      );

      final json = await client.get('/api/v1/user/wallet');

      expect(captured.headers['Authorization'], 'Bearer secret-token');
      expect(captured.headers['Content-Type'], 'application/json');
      expect(json['success'], true);
    });

    test('no token means no Authorization header', () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        httpClient: MockClient(
            (request) async => http.Response('{"success":true}', 200)),
      );

      final json = await client.get('/x');
      expect(json['success'], true);
    });
  });

  group('ApiClient error handling', () {
    test('HTTP >= 400 with error message throws ApiException', () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        httpClient: MockClient(
            (_) async => http.Response('{"error":"bad request"}', 400)),
      );

      expect(
        () => client.get('/x'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'bad request')),
      );
    });

    test('403 PASSWORD_CHANGE_REQUIRED is flagged for the pw-gate', () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        httpClient: MockClient((_) async =>
            http.Response('{"error":"PASSWORD_CHANGE_REQUIRED"}', 403)),
      );

      try {
        await client.get('/x');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 403);
        expect(e.isPasswordChangeRequired, isTrue);
      }
    });

    test('non-map success body throws ApiException(500, malformed)', () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        httpClient: MockClient((_) async => http.Response('[]', 200)),
      );

      expect(
        () => client.get('/x'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('connection failure surfaces as NetworkException(offline)', () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        httpClient: MockClient(
            (_) async => throw http.ClientException('connection refused')),
      );

      expect(
        () => client.get('/x'),
        throwsA(isA<NetworkException>()
            .having((e) => e.isOffline, 'isOffline', isTrue)),
      );
    });
  });

  group('ApiClient.post', () {
    test('sends a JSON-encoded body', () async {
      late Map<String, String> headers;
      late String body;
      final client = ApiClient(
        baseUrl: 'https://api.example.test',
        token: 't',
        httpClient: MockClient((request) async {
          headers = request.headers;
          body = request.body;
          return http.Response('{"success":true}', 200);
        }),
      );

      await client.post('/api/v1/auth/login', body: {'username': 'u'});

      expect(headers['Content-Type'], 'application/json');
      expect(body, '{"username":"u"}');
    });
  });
}