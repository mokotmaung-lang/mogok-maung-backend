import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../data/wallet_repository.dart';

/// Builds the HTTP client bound to the current session token.
final apiClientProvider = Provider<ApiClient>((ref) {
  final token = ref.watch(sessionProvider)?.token;
  return ApiClient(baseUrl: AppConfig.apiBaseUrl, token: token);
});

final walletRepositoryProvider = Provider<WalletRepository>((ref) {
  return WalletRepository(client: ref.watch(apiClientProvider));
});

/// Live, reactive wallet feed. The stream polls the backend on a short
/// interval so balance changes (deposits, holds, settlements) appear without
/// a manual refresh — the dashboard binds to this via `ref.watch`.
final userBalanceProvider = StreamProvider<WalletSnapshot>((ref) {
  final repo = ref.watch(walletRepositoryProvider);

  Stream<WalletSnapshot> feed() async* {
    while (true) {
      try {
        yield await repo.fetchWallet();
      } catch (_) {
        // Transient network/auth errors are swallowed; the next tick retries.
        // The UI reflects staleness via the loading placeholder.
      }
      await Future<void>.delayed(AppConfig.balanceRefreshInterval);
    }
  }

  return feed();
});