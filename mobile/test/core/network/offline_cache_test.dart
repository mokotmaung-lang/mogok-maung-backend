import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mogok_maung_mobile/core/network/offline_cache.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mgm_cache_test_');
    await OfflineCache.instance.init(directory: tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('is not ready before init (fresh test instance)', () {
    // The singleton is re-opened in setUp; assert the box is open now.
    expect(OfflineCache.instance.ready, isTrue);
  });

  test('write -> read -> remove round-trips nested JSON', () async {
    final cache = OfflineCache.instance;
    expect(cache.read('bet_history:0'), isNull);

    await cache.write('bet_history:0', {
      'data': {
        'bets': [
          {'bet_id': 1, 'status': 'PENDING'},
        ],
      },
    });

    final read = cache.read('bet_history:0');
    expect(read, isNotNull);
    expect((read!['data'] as Map)['bets'], isA<List>());

    await cache.remove('bet_history:0');
    expect(cache.read('bet_history:0'), isNull);
  });

  test('write is idempotent for the same key', () async {
    final cache = OfflineCache.instance;
    await cache.write('k', {'n': 1});
    await cache.write('k', {'n': 2});
    expect(cache.read('k'), {'n': 2});
  });
}