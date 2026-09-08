import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Watches the device's connectivity and exposes a single `offline` bool for
/// the UI banner.
///
/// Initial reachability is resolved once on [init], then followed live via the
/// `onConnectivityChanged` stream. A transport that reports no network types
/// (`ConnectivityResult.none`) or an empty list is treated as offline.
class ConnectivityController extends ChangeNotifier {
  ConnectivityController({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  bool _offline = false;
  bool get offline => _offline;

  bool _disposed = false;

  Future<void> init() async {
    try {
      _apply(await _connectivity.checkConnectivity());
    } catch (_) {
      // Platform channel unavailable (tests) -> assume online, never crash.
    }
    if (_disposed) return;
    _subscription = _connectivity.onConnectivityChanged.listen(_apply);
  }

  void _apply(List<ConnectivityResult> results) {
    if (_disposed) return;
    final offline = results.isEmpty ||
        results.every((result) => result == ConnectivityResult.none);
    if (offline != _offline) {
      _offline = offline;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}