/// Live Myanmar odds streamed over WebSocket with reactive UI state.
library live_match_odds_view;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/utils/myanmar_font_engine.dart';

// ============================================================================
// ENUM / DOMAIN MODELS
// ============================================================================

/// Wire-level match status coming from the Go WebSocket gateway.
enum MatchStatus {
  open('OPEN'),
  closed('CLOSED'),
  unknown('UNKNOWN');

  final String wireValue;

  const MatchStatus(this.wireValue);

  static MatchStatus fromWire(String? raw) {
    switch (raw?.trim().toUpperCase()) {
      case 'OPEN':
        return MatchStatus.open;
      case 'CLOSED':
        return MatchStatus.closed;
      default:
        return MatchStatus.unknown;
    }
  }
}

/// Immutable snapshot of a live odds payload decoded from the stream.
@immutable
class LiveMatchOdds {
  final String homeTeam;
  final String awayTeam;
  final String bodyOddsType;
  final MatchStatus status;

  const LiveMatchOdds({
    required this.homeTeam,
    required this.awayTeam,
    required this.bodyOddsType,
    required this.status,
  });

  factory LiveMatchOdds.fromJson(Map<String, dynamic> json) {
    return LiveMatchOdds(
      homeTeam: (json['home_team'] as String?) ?? '',
      awayTeam: (json['away_team'] as String?) ?? '',
      bodyOddsType: (json['body_odds_type'] as String?) ?? '',
      status: MatchStatus.fromWire(json['status'] as String?),
    );
  }

  bool get isOpen => status == MatchStatus.open;
}

/// Safe decode of a single WebSocket frame into odds or a raw error message.
@immutable
class _OddsFrame {
  final LiveMatchOdds? odds;
  final String? error;

  const _OddsFrame._({this.odds, this.error});

  static _OddsFrame decoded(dynamic raw) {
    try {
      final String text = raw is String
          ? raw
          : const Utf8Decoder().convert(raw as List<int>);
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        return const _OddsFrame._(error: 'Unexpected frame shape');
      }
      return _OddsFrame._(odds: LiveMatchOdds.fromJson(decoded));
    } catch (e) {
      return _OddsFrame._(error: 'Invalid frame: $e');
    }
  }
}

// ============================================================================
// MYANMAR FONT DETECTOR (Zawgyi / Unicode Auto-Detection)
// ============================================================================

/// Detects whether a Myanmar string payload is encoded in the legacy Zawgyi
/// font layout or standard Unicode, so a matching `fontFamily` can be applied
/// and the "font shattering" (တုံးတိတုံးရှည်) layout bug is avoided.
class MyanmarFontDetector {
  MyanmarFontDetector._();

  /// Zawgyi stores grapheme clusters in pre-base/infix order (e-vowel U+1031
  /// and medials U+103B..U+103E before the base consonant) and stacks asat
  /// (U+103A) / dot-below (U+1037) directly onto the base. Unicode never
  /// produces these sequences, so their presence is a reliable Zawgyi signal.
  static final RegExp _zawgyiSignature = RegExp(
    '(?:'
    r'[\u1000-\u1049]\u103a' // asat stacked directly on base
    r'|[\u1000-\u1049]\u1037' // dot-below stacked directly on base
    r'|\u1031[\u1000-\u1049]' // e-vowel preceding the base (Zawgyi order)
    r'|[\u1000-\u1049][\u103b-\u103e][\u1000-\u1049]' // medial sandwiched
    r'|[\u103d\u103e][\u103d\u103e]' // stacked wa/ha medials
    ')',
  );

  static const String zawgyiFontFamily = 'Zawgyi-One';
  static const String unicodeFontFamily = 'Pyidaungsu';

  /// Returns `true` when the payload uses the legacy Zawgyi layout.
  static bool isZawgyi(String? payload) {
    if (payload == null || payload.isEmpty) return false;
    return _zawgyiSignature.hasMatch(payload) &&
        !payload.contains(unicodeFontFamily); // never force-detect a tag
  }

  /// Assembles text with the font family matching the payload typography.
  /// Falls back to Unicode (Pyidaungsu) for non-Myanmar strings.
  static String fontFamilyFor(String? payload) =>
      isZawgyi(payload) ? zawgyiFontFamily : unicodeFontFamily;
}

// ============================================================================
// WIDGET
// ============================================================================

/// Real-time live odds + match status component for the mobile application.
///
/// Connects to the Go WebSocket gateway, decodes Myanmar odds streams and
/// disables the betting action the instant a match flips to 'CLOSED'.
class LiveMatchOddsView extends StatefulWidget {
  /// Identifier of the match whose odds feed is subscribed to.
  final int matchId;

  /// WebSocket gateway origin, e.g. `wss://myanmarbet.com`.
  final String baseUrl;

  const LiveMatchOddsView({
    super.key,
    required this.matchId,
    this.baseUrl = 'wss://myanmarbet.com',
  });

  @override
  State<LiveMatchOddsView> createState() => _LiveMatchOddsViewState();
}

class _LiveMatchOddsViewState extends State<LiveMatchOddsView> {
  WebSocketChannel? _channel;
  late final String _socketUrl;

  @override
  void initState() {
    super.initState();
    // Gateway route, e.g. /ws/odds/{matchId}.
    _socketUrl = '${widget.baseUrl}/ws/odds/${widget.matchId}';
    _connect();
  }

  void _connect() {
    setState(() {
      _channel =
          WebSocketChannel.connect(Uri.parse(_socketUrl));
    });
  }

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  Stream<_OddsFrame> get _oddsStream => (_channel?.stream ??
          const Stream<dynamic>.empty())
      .map(_OddsFrame.decoded);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<_OddsFrame>(
      stream: _oddsStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _buildFatalError(context);
        }
        if (snapshot.connectionState == ConnectionState.done) {
          return _buildDisconnected(context);
        }
        if (!snapshot.hasData) {
          return _buildLoading(context);
        }

        final _OddsFrame frame = snapshot.data!;
        if (frame.error != null) {
          return _buildDecodeError(frame.error!);
        }

        return _LiveOddsCard(odds: frame.odds!, onPlaceBet: _onPlaceBet);
      },
    );
  }

  void _onPlaceBet() {
    final int id = widget.matchId;
    // AUTH + stake payload goes here (Phase 3.5 / Phase 4). Left as a
    // template to demonstrate the interaction seam.
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Betting flow for match #$id (LIVE)')),
      );
    }
  }

  // --- State renderers ------------------------------------------------------

  Widget _buildLoading(BuildContext context) {
    return const _Panel(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('ကြေးနှုန်းဟောင်းများ ရယူနေပါသည်…'),
          ],
        ),
      ),
    );
  }

  Widget _buildDisconnected(BuildContext context) {
    return _Panel(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.signal_wifi_off, size: 48, color: Colors.blueGrey),
            const SizedBox(height: 12),
            Text(
              'ချိတ်ဆက်မှု ပြတ်တောက်သွားပါသည်',
              style: _myanmarTextStyle(context),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _connect,
              icon: const Icon(Icons.replay),
              label: const Text('ပြန်လည်ချိတ်ဆက်မည်'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFatalError(BuildContext context) {
    return _Panel(
      child: Center(
        child: Text(
          'ချိတ်ဆက်မှု အမှားဖြစ်နေပါသည်',
          style: _myanmarTextStyle(context).copyWith(color: Colors.red),
        ),
      ),
    );
  }

  Widget _buildDecodeError(String error) {
    return _Panel(
      child: Center(
        child: Text(
          'ဒေတာ ဖတ်ရှုရာတွင် အမှားဖြစ်သည်',
          style: _myanmarTextStyle(context).copyWith(color: Colors.orange),
        ),
      ),
    );
  }

  static TextStyle _myanmarTextStyle(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium!.copyWith(
            fontFamily: MyanmarFontEngine.unicodeFontFamily,
          );
}

// ============================================================================
// CARD LAYOUT
// ============================================================================

class _LiveOddsCard extends StatelessWidget {
  final LiveMatchOdds odds;
  final VoidCallback onPlaceBet;

  const _LiveOddsCard({required this.odds, required this.onPlaceBet});

  @override
  Widget build(BuildContext context) {
    final bool open = odds.isOpen;
    final ThemeData theme = Theme.of(context);

    return _Panel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StatusBar(open: open),
          const SizedBox(height: 20),
          _TeamRow(home: odds.homeTeam, away: odds.awayTeam),
          const SizedBox(height: 20),
          _OddsRow(oddsType: odds.bodyOddsType),
          const SizedBox(height: 24),
          _PlaceBetButton(
            open: open,
            onPressed: onPlaceBet,
            accentColor: theme.colorScheme.primary,
          ),
        ],
      ),
    );
  }
}

/// Glowing blue container for active matches; dark red "closed" banner.
class _StatusBar extends StatelessWidget {
  final bool open;

  const _StatusBar({required this.open});

  @override
  Widget build(BuildContext context) {
    final TextStyle base = Theme.of(context).textTheme.titleSmall!;
    if (open) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF0B3B6B),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.lightBlueAccent.withValues(alpha: 0.65),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.circle, size: 12, color: Colors.lightBlueAccent),
            const SizedBox(width: 8),
            Text('ပွဲစဉ် ဖွင့်ထားသည်',
                style: base.copyWith(color: Colors.white)),
            const Spacer(),
            Text('LIVE', style: base.copyWith(color: Colors.lightBlueAccent)),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF7A1010),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.gavel, size: 16, color: Colors.white70),
          const SizedBox(width: 8),
          Text('ဒိုင်ပိတ်သွားပါပြီ',
              style: base.copyWith(color: Colors.white)),
        ],
      ),
    );
  }
}

class _TeamRow extends StatelessWidget {
  final String home;
  final String away;

  const _TeamRow({required this.home, required this.away});

  @override
  Widget build(BuildContext context) {
    final TextStyle style = Theme.of(context).textTheme.headlineSmall!;
    return Row(
      children: [
        Expanded(
          child: _TeamHeader(
            label: home,
            style: style.copyWith(
              fontFamily: MyanmarFontDetector.fontFamilyFor(home),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('ဘောဒီ', style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(
          child: _TeamHeader(
            label: away,
            style: style.copyWith(
              fontFamily: MyanmarFontDetector.fontFamilyFor(away),
            ),
          ),
        ),
      ],
    );
  }
}

class _TeamHeader extends StatelessWidget {
  final String label;
  final TextStyle style;

  const _TeamHeader({required this.label, required this.style});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(label, textAlign: TextAlign.center, style: style),
          const SizedBox(height: 6),
          Icon(
            Icons.sports_soccer,
            size: 20,
            color: Theme.of(context).colorScheme.outline,
          ),
        ],
      ),
    );
  }
}

class _OddsRow extends StatelessWidget {
  final String oddsType;

  const _OddsRow({required this.oddsType});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('ကြေးနှုန်း', style: Theme.of(context).textTheme.labelLarge),
          Text(
            oddsType,
            style: Theme.of(context).textTheme.titleLarge!.copyWith(
                  fontFamily: MyanmarFontDetector.fontFamilyFor(oddsType),
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

/// Primary action button. `onPressed: null` (gray, disabled) the moment the
/// match closes — preventing race-condition invalid bets from being sent.
class _PlaceBetButton extends StatelessWidget {
  final bool open;
  final VoidCallback onPressed;
  final Color accentColor;

  const _PlaceBetButton({
    required this.open,
    required this.onPressed,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: open ? accentColor : Colors.blueGrey.shade400,
          disabledBackgroundColor: Colors.blueGrey.shade300,
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.blueGrey.shade100,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: open ? onPressed : null,
        child: Text(
          'လောင်းကြေးထပ်မည်',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
fontFamily: MyanmarFontEngine.unicodeFontFamily,
              ),
        ),
      ),
    );
  }
}

/// Shared container chrome for loading / error / data states.
class _Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;

  const _Panel({required this.child, this.padding});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
    );
  }
}