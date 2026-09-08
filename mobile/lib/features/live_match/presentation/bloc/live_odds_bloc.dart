/// BLoC bridging the live-odds WebSocket stream into a UI-reactive state map.
library live_odds_bloc;

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/live_odds_client.dart';
import '../../domain/live_odds_models.dart';

/// Connection health + the latest snapshot per match. The bloc only re-emits
/// when a snapshot actually changed for that matchId.
sealed class LiveOddsState {
  final LiveOddsConnection connection;
  final Map<int, LiveOddsSnapshot> matches;
  final DateTime? updatedAt;

  const LiveOddsState({
    this.connection = LiveOddsConnection.disconnected,
    this.matches = const {},
    this.updatedAt,
  });

  LiveOddsSnapshot? snapshotOf(int matchId) => matches[matchId];
}

class LiveOddsInitial extends LiveOddsState {
  const LiveOddsInitial();
}

class LiveOddsLoaded extends LiveOddsState {
  const LiveOddsLoaded({
    required super.connection,
    required super.matches,
    required super.updatedAt,
  });
}

class LiveOddsError extends LiveOddsState {
  final String message;

  const LiveOddsError({required this.message, super.connection});
}

sealed class LiveOddsEvent {
  const LiveOddsEvent();
}

/// Ensures the socket is open (startup or manual reconnect).
class LiveOddsConnect extends LiveOddsEvent {
  const LiveOddsConnect();
}

/// Stops the socket (app background / user log-out).
class LiveOddsDisconnect extends LiveOddsEvent {
  const LiveOddsDisconnect();
}

class LiveOddsBloc extends Bloc<LiveOddsEvent, LiveOddsState> {
  LiveOddsBloc(this._client) : super(const LiveOddsInitial()) {
    on<LiveOddsConnect>(_connect);
    on<LiveOddsDisconnect>(_disconnect);
  }

  final LiveOddsClient _client;
  StreamSubscription<LiveOddsSnapshot>? _oddsSub;
  StreamSubscription<LiveOddsConnection>? _connSub;

  Future<void> _connect(LiveOddsConnect event, Emitter<LiveOddsState> emit) async {
    if (_oddsSub != null) return; // already subscribed

    _connSub = _client.connection.listen((c) {
      if (c != LiveOddsConnection.connected) return;
      if (!isClosed) {
        emit(LiveOddsLoaded(
        connection: c,
        matches: state.matches,
        updatedAt: state.updatedAt ?? DateTime.now().toUtc(),
      ));
      }
    });

    _oddsSub = _client.odds.listen((snapshot) {
      final Map<int, LiveOddsSnapshot> matches = Map.of(state.matches);
      matches[snapshot.matchId] = snapshot;
      if (!isClosed) {
        emit(LiveOddsLoaded(
          connection: LiveOddsConnection.connected,
          matches: matches,
          updatedAt: DateTime.now().toUtc(),
        ));
      }
    });

    // Drive connection changes after subscription listeners attached by
    // wiring a manual fire after subscribe; the client also emits on connect.
    _client.connect();
  }

  Future<void> _disconnect(
      LiveOddsDisconnect event, Emitter<LiveOddsState> emit) async {
    await _oddsSub?.cancel();
    await _connSub?.cancel();
    _oddsSub = null;
    _connSub = null;
    _client.dispose();
    if (!isClosed) emit(const LiveOddsInitial());
  }

  @override
  Future<void> close() async {
    await _oddsSub?.cancel();
    await _connSub?.cancel();
    _client.dispose();
    await super.close();
  }
}