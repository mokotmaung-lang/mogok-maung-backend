import 'package:hive_flutter/hive_flutter.dart';

/// Small Hive-backed store for last-known-good API responses.
///
/// Offline-first contract:
///  * repositories write-through on every successful read (cheap JSON map),
///  * on a [NetworkException] they rehydrate the cache instead of failing,
///  * everything is keyed by endpoint so pages do not stomp each other.
///
/// The cache is *soft*: if Hive was never initialised (e.g. unit tests that
/// only exercise transport logic) every read/write is a no-op so callers do
/// not need guarding.
class OfflineCache {
  OfflineCache._();

  static final OfflineCache instance = OfflineCache._();

  static const String boxName = 'mgm_offline_cache';

  Box<dynamic>? _box;

  /// Opens the cache. [directory] is only used by tests; production uses
  /// HiveFlutter's default (path_provider) location.
  Future<void> init({String? directory}) async {
    if (directory != null) {
      Hive.init(directory);
    } else {
      await Hive.initFlutter();
    }
    _box = await Hive.openBox<dynamic>(boxName);
  }

  bool get ready => _box != null && _box!.isOpen;

  Map<String, dynamic>? read(String key) {
    if (!ready) return null;
    final value = _box!.get(key);
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  Future<void> write(String key, Map<String, dynamic> json) async {
    if (!ready) return;
    await _box!.put(key, json);
  }

  Future<void> remove(String key) async {
    if (!ready) return;
    await _box!.delete(key);
  }
}