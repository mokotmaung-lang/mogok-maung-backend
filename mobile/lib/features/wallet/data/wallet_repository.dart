import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';

/// Immutable snapshot of a user's wallet from the backend.
@immutable
class WalletSnapshot {
  final double currentBalance;
  final double holdBalance;

  const WalletSnapshot({
    required this.currentBalance,
    required this.holdBalance,
  });

  factory WalletSnapshot.fromJson(Map<String, dynamic> json) => WalletSnapshot(
        currentBalance: (json['current_balance'] as num?)?.toDouble() ?? 0,
        holdBalance: (json['hold_balance'] as num?)?.toDouble() ?? 0,
      );
}

/// Data source for the live wallet feed.
class WalletRepository {
  final ApiClient client;

  WalletRepository({required this.client});

  Future<WalletSnapshot> fetchWallet() async {
    final json = await client.get('/api/v1/user/wallet');
    return WalletSnapshot.fromJson(json);
  }
}