/// Live odds feed models for the Mogok Maung WebSocket gateway.
library live_odds_models;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Wire-level match lifecycle mirrored from the backend
/// `match_status` enum (OPEN / SUSPENDED / CLOSED / FINISHED).
enum LiveMatchState {
  open('OPEN'),
  suspended('SUSPENDED'),
  closed('CLOSED'),
  finished('FINISHED'),
  unknown('UNKNOWN');

  final String wireValue;

  const LiveMatchState(this.wireValue);

  static LiveMatchState fromWire(String? raw) {
    switch (raw?.trim().toUpperCase()) {
      case 'OPEN':
        return LiveMatchState.open;
      case 'SUSPENDED':
        return LiveMatchState.suspended;
      case 'CLOSED':
        return LiveMatchState.closed;
      case 'FINISHED':
        return LiveMatchState.finished;
      default:
        return LiveMatchState.unknown;
    }
  }
}

/// Immutable, self-contained snapshot of one live match's odds. The gateway
/// publishes the full odds row on every change so clients key by [matchId].
@immutable
class LiveOddsSnapshot {
  final int matchId;
  final String leagueName;
  final String homeTeam;
  final String awayTeam;
  final int homeScore;
  final int awayScore;
  final LiveMatchState state;
  final String? bodyHandicap;
  final double? homeBodyPayout;
  final double? awayBodyPayout;
  final double? maungHome;
  final double? maungAway;
  final double? maungDraw;
  final String? streamUrl;
  final DateTime updatedAt;

  const LiveOddsSnapshot({
    required this.matchId,
    this.leagueName = '',
    required this.homeTeam,
    required this.awayTeam,
    this.homeScore = 0,
    this.awayScore = 0,
    required this.state,
    this.bodyHandicap,
    this.homeBodyPayout,
    this.awayBodyPayout,
    this.maungHome,
    this.maungAway,
    this.maungDraw,
    this.streamUrl,
    required this.updatedAt,
  });

  bool get isOpen => state == LiveMatchState.open;

  bool get isLive =>
      state == LiveMatchState.open || state == LiveMatchState.suspended;

  bool get hasStream => (streamUrl?.trim().isNotEmpty ?? false);

  factory LiveOddsSnapshot.fromJson(Map<String, dynamic> json) {
    double? d(Object? v) =>
        v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    int i(Object? v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

    return LiveOddsSnapshot(
      matchId: i(json['match_id'] ?? json['id']),
      leagueName: (json['league_name'] as String?) ?? '',
      homeTeam: (json['home_team'] as String?) ?? '',
      awayTeam: (json['away_team'] as String?) ?? '',
      homeScore: i(json['home_score']),
      awayScore: i(json['away_score']),
      state: LiveMatchState.fromWire(json['status'] as String?),
      bodyHandicap: json['body_odds_type'] as String?,
      homeBodyPayout:
          d(json['home_body_payout'] ?? json['home_odds']),
      awayBodyPayout:
          d(json['away_body_payout'] ?? json['away_odds']),
      maungHome: d(json['maung_home_multiplier']),
      maungAway: d(json['maung_away_multiplier']),
      maungDraw: d(json['maung_draw_multiplier']),
      streamUrl: json['stream_url'] as String?,
      updatedAt: DateTime.now().toUtc(),
    );
  }
}

/// Decoded result of a single WebSocket frame.
@immutable
class LiveOddsEnvelope {
  final LiveOddsSnapshot? snapshot;
  final String? error;

  const LiveOddsEnvelope._({this.snapshot, this.error});

  static LiveOddsEnvelope decoded(dynamic raw) {
    try {
      final String text = raw is String
          ? raw
          : const Utf8Decoder().convert(raw as List<int>);
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        return const LiveOddsEnvelope._(error: 'Unexpected frame shape');
      }

      // Envelope form: {"type": "odds_update", "data": {...}}.
      final dynamic inner = decoded['type'] == 'odds_update'
          ? decoded['data']
          : decoded;
      if (inner is! Map<String, dynamic>) {
        return const LiveOddsEnvelope._(error: 'Odds payload missing');
      }
      if (inner['error'] is String) {
        return LiveOddsEnvelope._(error: inner['error'] as String);
      }
      return LiveOddsEnvelope._(snapshot: LiveOddsSnapshot.fromJson(inner));
    } catch (e) {
      return LiveOddsEnvelope._(error: 'Invalid frame: $e');
    }
  }
}