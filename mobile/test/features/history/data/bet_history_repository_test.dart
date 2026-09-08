import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mogok_maung_mobile/core/network/api_client.dart';
import 'package:mogok_maung_mobile/core/network/offline_cache.dart';
import 'package:mogok_maung_mobile/features/history/data/bet_history_repository.dart';

const Map<String, dynamic> _betJson = {
  'bet_id': 1,
  'bet_type': 'BODY',
  'total_stake': 100,
  'hold_amount': 150,
  'potential_payout': 200,
  'status': 'PENDING',
  'selections_count': 1,
  'created_at': '2026-09-07T03:00:00Z',
  'selections': [],
};

ApiClient _api(MockClient mock) => ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: mock,
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mgm_history_test_');
    await OfflineCache.instance.init(directory: tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('live fetch decodes and writes page 0 through to the cache', () async {
    final repo = BetHistoryRepository(
      client: _api(MockClient((_) async => http.Response(
            jsonEncode({'data': {'bets': [_betJson]}}),
            200,
          ))),
    );

    final items = await repo.fetchBetHistory();

    expect(items.length, 1);
    expect(items.first.betId, 1);
    expect(items.first.totalStake, 100);
    expect(items.first.isPending, isTrue);
    expect(OfflineCache.instance.read('bet_history:0'), isNotNull);
  });

  test('offline fetch falls back to the cached page 0', () async {
    await OfflineCache.instance.write('bet_history:0', {
      'data': {
        'bets': [_betJson],
      },
    });

    final repo = BetHistoryRepository(
      client: _api(MockClient(
        (_) async => throw http.ClientException('connection refused'),
      )),
    );

    final items = await repo.fetchBetHistory();

    expect(items.length, 1);
    expect(items.first.betId, 1);
  });

  test('offline fetch with no cached page rethrows NetworkException', () async {
    final repo = BetHistoryRepository(
      client: _api(MockClient(
        (_) async => throw http.ClientException('connection refused'),
      )),
    );

    expect(repo.fetchBetHistory(), throwsA(isA<NetworkException>()));
  });

  test('paged offline load beyond page 0 does not poison the feed', () async {
    final repo = BetHistoryRepository(
      client: _api(MockClient(
        (_) async => throw http.ClientException('connection refused'),
      )),
    );

    expect(repo.fetchBetHistory(offset: 20), throwsA(isA<NetworkException>()));
  });
}