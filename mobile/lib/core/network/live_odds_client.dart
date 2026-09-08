/// WebSocket client for the `/ws/live-odds` gateway broadcast feed.
library live_odds_client;

import 'dart:async';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../features/live_match/domain/live_odds_models.dart';
import '../config/app_config.dart';

/// Lifecycle of the underlying socket.
enum LiveOddsConnection { connecting, connected, disconnected }

typedef TokenProvider = String? Function();

/// Owns the socket lifecycle: bearer-token handshake, exponential-backoff
/// reconnection, and fan-out of decoded odds snapshots to one broadcast stream.
class LiveOddsClient {
  LiveOddsClient({required this.tokenProvider});

  final TokenProvider tokenProvider;

  final StreamController<LiveOddsSnapshot> _odds =
      StreamController<LiveOddsSnapshot>.broadcast();
  final StreamController<LiveOddsConnection> _connection =
      StreamController<LiveOddsConnection>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  int _attempt = 0;
  bool _disposed = false;

  static const Duration _maxBackoff = Duration(seconds: 30);

  Stream<LiveOddsSnapshot> get odds => _odds.stream;
  Stream<LiveOddsConnection> get connection => _connection.stream;

  Uri get _uri {
    final String? token = tokenProvider();
    final uri = Uri.parse('${AppConfig.wsBaseUrl}/ws/live-odds');
    if (token == null || token.isEmpty) return uri;
    return uri.replace(queryParameters: {'token': token});
  }

  /// Opens (or reopens) the socket. Safe to call repeatedly; closed sockets
  /// are torn down first so a manual retry does not leak a second channel.
  void connect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _emit(LiveOddsConnection.connecting);

    final WebSocketChannel channel = WebSocketChannel.connect(_uri);
    _channel = channel;

    _sub = channel.stream.listen(
      _onFrame,
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
      cancelOnError: true,
    );
  }

  void _onFrame(dynamic raw) {
    final LiveOddsEnvelope envelope = LiveOddsEnvelope.decoded(raw);
    final LiveOddsSnapshot? snapshot = envelope.snapshot;
    if (snapshot == null || _disposed) return;
    _attempt = 0; // got a healthy frame — reset backoff
    _emit(LiveOddsConnection.connected);
    _odds.add(snapshot);
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _emit(LiveOddsConnection.disconnected);
    final int backoffMs = min(1000 * (1 << _attempt), _maxBackoff.inMilliseconds);
    _attempt += 1;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: backoffMs), connect);
  }

  void _emit(LiveOddsConnection state) {
    if (!_disposed && !_connection.isClosed) {
      _connection.add(state);
    }
  }

  /// Stops reconnection and releases all sockets/timers.
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
  }
}