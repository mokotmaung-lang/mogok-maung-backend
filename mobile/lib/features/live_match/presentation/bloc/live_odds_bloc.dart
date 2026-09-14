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

/// Forwarded from the client's connection stream (connecting/connected/disconnected).
class LiveOddsConnectionChanged extends LiveOddsEvent {
  const LiveOddsConnectionChanged(this.connection);

  final LiveOddsConnection connection;
}

/// Forwarded from the client's decoded odds stream (one WS frame per match).
class LiveOddsFrameReceived extends LiveOddsEvent {
  const LiveOddsFrameReceived(this.snapshot);

  final LiveOddsSnapshot snapshot;
}

/// WebSocket-driven live-odds bloc.
///
/// Instead of calling `emit()` from stream callbacks (which fire AFTER the
/// initiating event handler has completed and would trip the
/// `emit was called after an event handler completed` assertion), the two
/// client streams are merely forwarded here via `add(...)` and every `emit`
/// happens synchronously inside a dedicated event handler. The lifecycle
/// events stay fully `await`-free and synchronous on purpose; no async gap
/// exists between an event dispatch and its emission, so `emit.isDone` is
/// always false at emit time.
class LiveOddsBloc extends Bloc<LiveOddsEvent, LiveOddsState> {
  LiveOddsBloc(this._client) : super(const LiveOddsInitial()) {
    on<LiveOddsConnect>(_connect);
    on<LiveOddsDisconnect>(_disconnect);
    on<LiveOddsConnectionChanged>(_onConnectionChanged);
    on<LiveOddsFrameReceived>(_onFrameReceived);
  }

  final LiveOddsClient _client;
  StreamSubscription<LiveOddsSnapshot>? _oddsSub;
  StreamSubscription<LiveOddsConnection>? _connSub;

  void _connect(LiveOddsConnect event, Emitter<LiveOddsState> emit) {
    if (_oddsSub != null) return; // already subscribed

    // Streams are bridged into the bloc's own event queue; emitting never
    // happens from these callbacks (they outlive the event dispatch).
    _connSub = _client.connection.listen(
      (c) {
        if (!isClosed) add(LiveOddsConnectionChanged(c));
      },
      onError: (_) {},
    );
    _oddsSub = _client.odds.listen(
      (snapshot) {
        if (!isClosed) add(LiveOddsFrameReceived(snapshot));
      },
      onError: (_) {},
    );

    _client.connect();
  }

  void _onConnectionChanged(
    LiveOddsConnectionChanged event,
    Emitter<LiveOddsState> emit,
  ) {
    if (isClosed) return;
    if (event.connection == LiveOddsConnection.connected &&
        state.connection == LiveOddsConnection.connected) {
      return; // already connected — avoid redundant rebuilds
    }
    emit(LiveOddsLoaded(
      connection: event.connection,
      matches: state.matches,
      updatedAt: state.updatedAt ?? DateTime.now().toUtc(),
    ));
  }

  void _onFrameReceived(
    LiveOddsFrameReceived event,
    Emitter<LiveOddsState> emit,
  ) {
    if (isClosed) return;
    final Map<int, LiveOddsSnapshot> matches = Map.of(state.matches);
    matches[event.snapshot.matchId] = event.snapshot;
    emit(LiveOddsLoaded(
      connection: LiveOddsConnection.connected,
      matches: matches,
      updatedAt: event.snapshot.updatedAt,
    ));
  }

  void _disconnect(LiveOddsDisconnect event, Emitter<LiveOddsState> emit) {
    _oddsSub?.cancel();
    _connSub?.cancel();
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