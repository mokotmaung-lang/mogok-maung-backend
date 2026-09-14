import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/service_locator.dart';
import '../../../../core/l10n/myanmar_locale.dart';
import '../../data/bet_history_repository.dart';
import '../../domain/bet_history_item.dart';
import '../bloc/bet_history_bloc.dart';

/// Bet History screen — the user's Body/Maung wagering history, Burmese UI.
///
/// Production states covered: initial loading, pull-to-refresh, infinite
/// scroll pagination, empty result and request failure with retry.
class BetHistoryScreen extends StatefulWidget {
  const BetHistoryScreen({super.key});

  @override
  State<BetHistoryScreen> createState() => _BetHistoryScreenState();
}

class _BetHistoryScreenState extends State<BetHistoryScreen> {
  final ScrollController _scrollController = ScrollController();
  late final BetHistoryBloc _bloc =
      BetHistoryBloc(sl<BetHistoryRepository>());

  @override
  void initState() {
    super.initState();
    _bloc.add(const LoadBetHistory());
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _bloc.add(const LoadMoreBetHistory());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _bloc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(MyanmarLocale.t('bettingHistory')),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: BlocProvider.value(
        value: _bloc,
        child: BlocBuilder<BetHistoryBloc, BetHistoryState>(
          builder: (context, state) {
            if (state.isLoading && state.items.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (state.error != null && state.items.isEmpty) {
              return _ErrorState(onRetry: () => _bloc.add(const RefreshBetHistory()));
            }
            if (state.items.isEmpty) {
              return _EmptyState(onRetry: () => _bloc.add(const RefreshBetHistory()));
            }
            return RefreshIndicator(
              onRefresh: () async => _bloc.add(const RefreshBetHistory()),
              child: ListView.builder(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: state.items.length + (state.isLoadingMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= state.items.length) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  return _BetHistoryCard(item: state.items[index]);
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BetHistoryCard extends StatelessWidget {
  final BetHistoryItem item;

  const _BetHistoryCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final bool isPending = item.isPending;
    final bool isWin = item.isApproved;

    final statusLabel = isPending
        ? MyanmarLocale.t('betStatusPending')
        : isWin
            ? MyanmarLocale.t('betStatusApproved')
            : MyanmarLocale.t('betStatusRejected');
    final statusColor = isPending
        ? Colors.grey.shade700
        : isWin
            ? Colors.green
            : Colors.red;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        backgroundColor: Colors.white,
        collapsedBackgroundColor: Colors.grey.shade50,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Row(
          children: [
            _TypeChip(item: item),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                statusLabel,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${MyanmarLocale.t('betStakeLabel')} ${_fmtAmount(item.totalStake)} ${MyanmarLocale.t('betUnit')}  |  ${MyanmarLocale.t('betReceiveLabel')} ${_fmtAmount(item.potentialPayout)} ${MyanmarLocale.t('betUnit')}',
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                '${MyanmarLocale.t('betPlacedAt')} ${_fmtTime(item.createdAt)}',
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ],
          ),
        ),
        children: [
          Container(
            width: double.infinity,
            color: Colors.grey.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                if (item.selections.isEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    MyanmarLocale.t('betLoading'),
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                ] else
                  for (final sel in item.selections) _SelectionDetailTile(sel: sel),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One leg of the bet: match, pick and the Burmese settlement result.
class _SelectionDetailTile extends StatelessWidget {
  final BetSelectionDetail sel;

  const _SelectionDetailTile({required this.sel});

  @override
  Widget build(BuildContext context) {
    final (label, color) = _resultPresentation(sel.result);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${sel.homeTeam} ${MyanmarLocale.t('vsLabel')} ${sel.awayTeam}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${MyanmarLocale.t('pickLabel')}: ${sel.pick} [${MyanmarLocale.t('oddsLabel')}: ${_oddsText(sel)}]',
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Displays the handicap string for Body tickets and the multiplier for Maung.
///
/// Backend returns both; Body legs read like "1+50", Maung legs show the
/// numeric multiplier actually applied at settlement.
String _oddsText(BetSelectionDetail sel) {
  final odds = sel.oddsUsed;
  return odds == odds.roundToDouble()
      ? odds.toStringAsFixed(0)
      : odds.toStringAsFixed(2);
}

/// Maps a leg result to its (Burmese label, severity color).
(String, Color) _resultPresentation(String result) {
  switch (result) {
    case 'WIN':
      return (MyanmarLocale.t('winFull'), Colors.green.shade700);
    case 'HALF_WIN':
      return (MyanmarLocale.t('winHalf'), Colors.green.shade700);
    case 'LOSE':
      return (MyanmarLocale.t('loseFull'), Colors.red.shade700);
    case 'HALF_LOSE':
      return (MyanmarLocale.t('loseHalf'), Colors.red.shade700);
    case 'DRAW':
      return (MyanmarLocale.t('drawNeutral'), Colors.orange.shade700);
    default:
      return (MyanmarLocale.t('selectionPending'), Colors.orange.shade700);
  }
}

class _TypeChip extends StatelessWidget {
  final BetHistoryItem item;

  const _TypeChip({required this.item});

  @override
  Widget build(BuildContext context) {
    final isMaung = item.isMaung;
    final label = isMaung
        ? '${MyanmarLocale.t('maung')} (${item.selectionsCount} ${MyanmarLocale.t('betLegs')})'
        : MyanmarLocale.t('body');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isMaung ? Colors.orange.shade100 : Colors.blue.shade100,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isMaung ? Colors.orange.shade900 : Colors.blue.shade900,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
          const SizedBox(height: 12),
          Text(MyanmarLocale.t('betHistoryError')),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(MyanmarLocale.t('betRetry')),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onRetry;

  const _EmptyState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.receipt_long_outlined, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            MyanmarLocale.t('betHistoryEmpty'),
            style: TextStyle(color: Colors.grey.shade600),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(MyanmarLocale.t('betRetry')),
          ),
        ],
      ),
    );
  }
}

String _fmtAmount(double v) => v.toStringAsFixed(0);

String _fmtTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}