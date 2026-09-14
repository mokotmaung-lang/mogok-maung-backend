import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/service_locator.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../security_settings/presentation/screens/user_security_settings_screen.dart';
import '../../../wallet/data/wallet_repository.dart';
import '../../../wallet/presentation/bloc/wallet_bloc.dart';

/// ကိုယ်ရေးအချက်အလက် — profile identity, live wallet balance, security
/// settings entry point and logout.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final String displayName = session?.username ?? 'User9482';
    final String role = session?.role ?? 'USER';

    return Scaffold(
      appBar: AppBar(
        title: const Text('ကိုယ်ရေးအချက်အလက်'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: BlocProvider<WalletBloc>(
        create: (_) => WalletBloc(sl<WalletRepository>())
          ..add(const LoadWalletBalance()),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 28,
                      child: Icon(Icons.person, size: 32),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(displayName,
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 4),
                          _RoleBadge(role: role),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            const _WalletTile(),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.security, color: Colors.teal),
                    title: const Text('လုံခြုံရေး ဆက်တင်များ (လျှို့ဝှက်နံပါတ် ပြောင်းရန်)'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const UserSecuritySettingsScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.logout, color: Colors.redAccent),
                    title: const Text('ထွက်ရန် (Logout)'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _confirmLogout(context, ref),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ထွက်ရန် သေချာပါသလား?'),
        content: const Text('အကောင့်မှ ထွက်မည်လား။'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('မထွက်တော့ပါ'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('ထွက်မည်'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    setSessionToken(null);
    ref.read(sessionProvider.notifier).state = null;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

class _RoleBadge extends StatelessWidget {
  final String role;

  const _RoleBadge({required this.role});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.indigo.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(role, style: const TextStyle(fontSize: 12, color: Colors.indigo)),
    );
  }
}

class _WalletTile extends StatelessWidget {
  const _WalletTile();

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletBloc>().state.wallet;

    return Card(
      child: ListTile(
        leading: const Icon(Icons.account_balance_wallet, color: Colors.green),
        title: const Text('လက်ကျန်ငွေ'),
        trailing: Text(
          wallet == null ? '…' : '${_formatUnits(wallet.currentBalance)} ฿',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.green,
          ),
        ),
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