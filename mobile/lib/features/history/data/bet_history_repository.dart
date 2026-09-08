import '../../../core/network/api_client.dart';
import '../../../core/network/offline_cache.dart';
import '../domain/bet_history_item.dart';

/// Data source for the user's bet history feed (GET /api/v1/user/bets).
///
/// Offline-first: successful reads are written through to [cache]; when the
/// network drops, page 0 is rehydrated from the last-known-good response so
/// the feed never goes blank on a dead line.
class BetHistoryRepository {
  final ApiClient client;
  final OfflineCache cache;

  BetHistoryRepository({required this.client, OfflineCache? cache})
      : cache = cache ?? OfflineCache.instance;

  static String _pageKey(int offset) => 'bet_history:$offset';

  Future<List<BetHistoryItem>> fetchBetHistory({
    int limit = 20,
    int offset = 0,
  }) async {
    try {
      final json = await client
          .get('/api/v1/user/bets?limit=$limit&offset=$offset');
      if (offset == 0) {
        // Fire-and-forget; a failed write must never fail a live read.
        await cache.write(_pageKey(offset), json);
      }
      return _parse(json);
    } on NetworkException {
      final cachedJson = cache.read(_pageKey(offset));
      if (cachedJson != null) return _parse(cachedJson);
      rethrow;
    }
  }

  List<BetHistoryItem> _parse(Map<String, dynamic> json) {
    final Map<String, dynamic> data =
        (json['data'] as Map<String, dynamic>?) ?? const {};
    final List<dynamic> bets = data['bets'] as List<dynamic>? ?? const [];
    return bets
        .whereType<Map<String, dynamic>>()
        .map(BetHistoryItem.fromJson)
        .toList();
  }
}