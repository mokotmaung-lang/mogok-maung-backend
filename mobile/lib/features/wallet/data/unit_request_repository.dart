import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';

/// One DEPOSIT / WITHDRAW ticket the caller opened. Status lifecycle is
/// PENDING -> APPROVED / REJECTED (driven by the approving admin).
@immutable
class UnitRequestItem {
  final int id;
  final double amount;
  final String type; // DEPOSIT | WITHDRAW
  final String status; // PENDING | APPROVED | REJECTED
  final String? note;
  final DateTime createdAt;

  const UnitRequestItem({
    required this.id,
    required this.amount,
    required this.type,
    required this.status,
    this.note,
    required this.createdAt,
  });

  factory UnitRequestItem.fromJson(Map<String, dynamic> json) => UnitRequestItem(
        id: (json['id'] as num?)?.toInt() ?? 0,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        type: (json['type'] as String?) ?? 'DEPOSIT',
        status: (json['status'] as String?) ?? 'PENDING',
        note: json['note'] as String?,
        createdAt:
            DateTime.tryParse((json['created_at'] as String?) ?? '') ??
                DateTime.now(),
      );
}

/// Acknowledgement returned when a deposit/withdraw ticket is opened.
@immutable
class UnitRequestAck {
  final int requestId;
  final String status;

  const UnitRequestAck({required this.requestId, required this.status});
}

/// Data source for the user's deposit/withdraw tickets.
class UnitRequestRepository {
  final ApiClient client;

  UnitRequestRepository({required this.client});

  /// Opens a new DEPOSIT / WITHDRAW ticket.
  Future<UnitRequestAck> create({
    required String type,
    required double amount,
    String? note,
  }) async {
    final json = await client.post('/api/v1/units/request', body: {
      'type': type,
      'amount': amount,
      if (note != null && note.trim().isNotEmpty)
        'payment_info': {'note': note.trim()},
    });
    final data = (json['data'] as Map<String, dynamic>?) ?? const {};
    return UnitRequestAck(
      requestId: (data['request_id'] as num?)?.toInt() ?? 0,
      status: (data['status'] as String?) ?? 'PENDING',
    );
  }

  /// Lists the caller's own tickets, newest first.
  Future<List<UnitRequestItem>> listMine() async {
    final json = await client.get('/api/v1/user/units/requests');
    final data = (json['data'] as Map<String, dynamic>?) ?? const {};
    final list = (data['requests'] as List<dynamic>?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(UnitRequestItem.fromJson)
        .toList();
  }
}