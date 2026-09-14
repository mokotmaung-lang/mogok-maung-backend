import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/service_locator.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/myanmar_datetime.dart';
import '../../data/unit_request_repository.dart';
import '../../data/wallet_repository.dart';
import '../bloc/wallet_bloc.dart';

/// Transaction History — the user's wallet balance plus their own
/// deposit/withdraw tickets (ငွေစာရင်းများ).
class TransactionHistoryScreen extends StatefulWidget {
  const TransactionHistoryScreen({super.key});

  @override
  State<TransactionHistoryScreen> createState() =>
      _TransactionHistoryScreenState();
}

class _TransactionHistoryScreenState extends State<TransactionHistoryScreen> {
  late final UnitRequestRepository _repository = sl<UnitRequestRepository>();
  late Future<List<UnitRequestItem>> _requests;

  @override
  void initState() {
    super.initState();
    _requests = _repository.listMine();
  }

  Future<void> _reload() async {
    setState(() {
      _requests = _repository.listMine();
    });
    await _requests;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ငွေစာရင်းများ'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          BlocProvider<WalletBloc>(
            create: (_) => WalletBloc(sl<WalletRepository>())
              ..add(const LoadWalletBalance()),
            child: const _BalanceSummaryCard(),
          ),
          Expanded(
            child: FutureBuilder<List<UnitRequestItem>>(
              future: _requests,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return _ErrorState(onRetry: _reload);
                }
                final items = snapshot.data ?? const <UnitRequestItem>[];
                if (items.isEmpty) {
                  return _EmptyState(onRefresh: _reload);
                }
                return RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) =>
                        _RequestTile(item: items[index]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Live balance card reusing the dashboard WalletBloc pattern.
class _BalanceSummaryCard extends StatelessWidget {
  const _BalanceSummaryCard();

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletBloc>().state.wallet;

    return Card(
      margin: const EdgeInsets.all(12),
      color: AppTheme.navySurface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('လက်ကျန်ငွေ', style: TextStyle(color: Colors.white70)),
                Text('ပိတ်ထားငွေ (Hold)', style: TextStyle(color: Colors.white54)),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  wallet == null
                      ? '…'
                      : '${_formatUnits(wallet.currentBalance)} ฿',
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  wallet == null
                      ? '…'
                      : '${_formatUnits(wallet.holdBalance)} ฿',
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  final UnitRequestItem item;

  const _RequestTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final bool isDeposit = item.type == 'DEPOSIT';
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isDeposit ? Colors.teal : Colors.pink,
        child: Icon(
          isDeposit ? Icons.add_circle_outline : Icons.remove_circle_outline,
          color: Colors.white,
        ),
      ),
      title: Text(isDeposit ? 'ငွေသွင်း (Deposit) #${item.id}' : 'ငွေထုတ် (Withdraw) #${item.id}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_formatUnits(item.amount)} ฿'
            '${item.note != null && item.note!.isNotEmpty ? ' · ${item.note}' : ''}',
          ),
          const SizedBox(height: 2),
          Text(
            formatMyanmarDateTime(item.createdAt),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      trailing: _StatusChip(status: item.status),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;

  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (status) {
      'PENDING' => ('စောင့်ဆိုင်းဆဲ', Colors.orange),
      'APPROVED' => ('အတည်ပြုပြီး', Colors.green),
      'REJECTED' => ('ငြင်းပယ်ခဲ့', Colors.redAccent),
      _ => (status, Colors.blueGrey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12)),
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
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('မှတ်တမ်း ရယူ၍မရပါ (ချိတ်ဆက်မှု စစ်ဆေးပါ)'),
          const SizedBox(height: 8),
          FilledButton(onPressed: onRetry, child: const Text('ထပ်စမ်းကြည့်ရန်')),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final Future<void> Function() onRefresh;

  const _EmptyState({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Icon(Icons.receipt_long, size: 56, color: Colors.white24),
          SizedBox(height: 12),
          Center(child: Text('ငွေသွင်း/ငွေထုတ် မှတ်တမ်း မရှိပါသေးပါ')),
        ],
      ),
    );
  }
}

/// Formats a value with thousand separators, e.g. 500000.5 -> "500,000".
String _formatUnits(double value) {
  final String raw = value.toStringAsFixed(2);
  final int dot = raw.indexOf('.');
  final String intPart = dot < 0 ? raw : raw.substring(0, dot);

  final StringBuffer out = StringBuffer();
  for (int i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) out.write(',');
    out.write(intPart[i]);
  }
  return out.toString();
}