/// Live match dashboard: the WebSocket odds are the single source of truth.
/// Screen state (scores, odds chips, bet-ability, video player) reacts to each
/// snapshot; a match flipping to CLOSED/SUSPENDED disables betting live.
library live_match_screen;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/l10n/myanmar_locale.dart';
import '../../../../core/network/live_odds_client.dart';
import '../../../betting/presentation/screens/single_bet_screen.dart';
import '../../domain/live_odds_models.dart';
import '../bloc/live_odds_bloc.dart';
import '../widgets/hls_video_player.dart';

class LiveMatchScreen extends StatelessWidget {
  const LiveMatchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<LiveOddsBloc>(
      create: (_) => LiveOddsBloc(GetIt.I.get<LiveOddsClient>())
        ..add(const LiveOddsConnect()),
      child: const _LiveMatchContent(),
    );
  }
}

class _LiveMatchContent extends StatefulWidget {
  const _LiveMatchContent();

  @override
  State<_LiveMatchContent> createState() => _LiveMatchContentState();
}

class _LiveMatchContentState extends State<_LiveMatchContent> {
  bool _liveOnly = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('တိုက်ရိုက်ပွဲစဉ် ကြေးနှုန်းများ')),
      body: Column(
        children: [
          _ConnectionBanner(
            onRetry: () => context.read<LiveOddsBloc>().add(const LiveOddsConnect()),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Text('ပွဲစဉ်များ'),
                const Spacer(),
                FilterChip(
                  label: const Text('တိုက်ရိုက်သာ'),
                  selected: _liveOnly,
                  onSelected: (v) => setState(() => _liveOnly = v),
                ),
              ],
            ),
          ),
          Expanded(
            child: BlocBuilder<LiveOddsBloc, LiveOddsState>(
              builder: (context, state) {
                final List<LiveOddsSnapshot> all =
                    state.matches.values.toList()
                      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
                final List<LiveOddsSnapshot> matches =
                    _liveOnly ? all.where((m) => m.isLive).toList() : all;

                if (matches.isEmpty) {
                  return const _EmptyState();
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: matches.length,
                  itemBuilder: (context, i) =>
                      _MatchTile(snapshot: matches[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Glows green while connected; amber while reconnecting; red when the gateway
/// is unreachable. Every reconnect emits [LiveOddsConnect] again.
class _ConnectionBanner extends StatelessWidget {
  final VoidCallback onRetry;

  const _ConnectionBanner({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LiveOddsBloc, LiveOddsState>(
      builder: (context, state) {
        final (Color color, String label) = switch (state.connection) {
          LiveOddsConnection.connected => (
              Colors.green,
              'WebSocket ချိတ်ဆက်ထားသည် • LIVE',
            ),
          LiveOddsConnection.connecting => (
              Colors.orange,
              'ပြန်လည်ချိတ်ဆက်နေသည်…',
            ),
          LiveOddsConnection.disconnected => (
              Colors.redAccent,
              'ချိတ်ဆက်မှု ပြတ်တောက်နေသည်',
            ),
        };
        return Material(
          color: color.withValues(alpha: 0.12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.circle, size: 10, color: color),
                const SizedBox(width: 8),
                Expanded(child: Text(label)),
                if (state.connection == LiveOddsConnection.disconnected)
                  TextButton(onPressed: onRetry, child: const Text('ပြန်ချိတ်မည်')),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.radar, size: 56, color: Colors.blueGrey.shade300),
          const SizedBox(height: 12),
          Text(MyanmarLocale.t('liveNoMatches',
              fallback: 'လက်ရှိ ကြေးနှုန်းဖွင့်ထားသော ပွဲစဉ်များ မရှိသေးပါ')),
        ],
      ),
    );
  }
}

/// One live match row. Renders the freshest snapshot; the row itself is the
/// only stateful part toggling the embedded HLS stream.
class _MatchTile extends StatefulWidget {
  final LiveOddsSnapshot snapshot;

  const _MatchTile({required this.snapshot});

  @override
  State<_MatchTile> createState() => _MatchTileState();
}

class _MatchTileState extends State<_MatchTile> {
  bool _watch = false;

  @override
  Widget build(BuildContext context) {
    final LiveOddsSnapshot s = widget.snapshot;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (s.isLive)
                      const Icon(Icons.circle, size: 10, color: Colors.redAccent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${s.leagueName} • ${s.homeScore} - ${s.awayScore}',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    _StatusChip(state: s.state),
                  ],
                ),
                const SizedBox(height: 10),
                _TeamLine(
                  name: s.homeTeam,
                  score: s.homeScore,
                  isOpen: s.isOpen,
                ),
                const SizedBox(height: 6),
                _TeamLine(
                  name: s.awayTeam,
                  score: s.awayScore,
                  isOpen: s.isOpen,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _OddsChip(
                      label: 'ဘောဒီ ${s.bodyHandicap ?? ''}'.trim(),
                      value: _fmtPct(s.homeBodyPayout),
                      dimmed: !s.isOpen,
                    ),
                    const SizedBox(width: 8),
                    _OddsChip(
                      label: 'ဘောဒီ ${s.bodyHandicap ?? ''}'.trim(),
                      value: _fmtPct(s.awayBodyPayout),
                      dimmed: !s.isOpen,
                    ),
                    const SizedBox(width: 8),
                    _OddsChip(
                      label: 'မောင်း',
                      value: _fmtX(s.maungHome ?? 0),
                      dimmed: !s.isOpen,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: s.isOpen
                            ? () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const SingleBetScreen(),
                                  ),
                                )
                            : null,
                        child: const Text('လောင်းမည်'),
                      ),
                    ),
                    if (s.hasStream) ...[
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () => setState(() => _watch = !_watch),
                        icon: Icon(_watch ? Icons.close : Icons.play_arrow),
                        label: Text(_watch ? 'ပိတ်မည်' : 'ကြည့်မည်'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (_watch && s.hasStream)
            HLSVideoPlayer(streamUrl: s.streamUrl!, matchTitle: s.homeTeam),
        ],
      ),
    );
  }
}

class _TeamLine extends StatelessWidget {
  final String name;
  final int score;
  final bool isOpen;

  const _TeamLine({
    required this.name,
    required this.score,
    required this.isOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.sports_soccer,
          size: 18,
          color: isOpen ? Colors.green : Colors.blueGrey,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(name, style: Theme.of(context).textTheme.titleMedium)),
        Text('$score', style: Theme.of(context).textTheme.titleLarge),
      ],
    );
  }
}

class _OddsChip extends StatelessWidget {
  final String label;
  final String value;
  final bool dimmed;

  const _OddsChip({
    required this.label,
    required this.value,
    required this.dimmed,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: dimmed
              ? Colors.blueGrey.withValues(alpha: 0.06)
              : Colors.blue.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.blueGrey.withValues(alpha: 0.25)),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: Theme.of(context).textTheme.titleMedium!.copyWith(
                    fontWeight: FontWeight.w700,
                    color: dimmed ? Colors.grey : Colors.blueAccent,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final LiveMatchState state;

  const _StatusChip({required this.state});

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (state) {
      LiveMatchState.open => ('LIVE', Colors.redAccent),
      LiveMatchState.suspended => ('ခေတ္တရပ်', Colors.orange),
      LiveMatchState.closed => ('ပိတ်ပြီး', Colors.blueGrey),
      LiveMatchState.finished => ('ပြီးဆုံး', Colors.teal),
      LiveMatchState.unknown => ('—', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall!.copyWith(color: color),
      ),
    );
  }
}

String _fmtPct(double? v) => v == null ? '—' : v.toStringAsFixed(2);
String _fmtX(double v) => '${_fmtPct(v)}x';