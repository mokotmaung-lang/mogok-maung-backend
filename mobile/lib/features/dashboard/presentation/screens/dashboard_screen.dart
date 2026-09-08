import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/service_locator.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../wallet/presentation/bloc/wallet_bloc.dart';
import '../../../wallet/data/wallet_repository.dart';
import '../widgets/grid_menu_card.dart';
import '../widgets/promo_banner_widget.dart';
import '../widgets/user_profile_info_bar.dart';

/// Home dashboard: dark navy, 8-grid menu layout with real-time entry points.
///
/// The 8 cells map to: BODY, MAUNG, bets, wallet, deposit, withdraw, profile,
/// and Live — each is a separate widget for clean reusability and dynamic
/// data binding.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  static const List<_MenuEntry> _menu = [
    _MenuEntry('ဘော်ဒီ', Icons.sports_soccer, Colors.blueAccent),
    _MenuEntry('မောင်း', Icons.format_list_bulleted, Colors.orangeAccent),
    _MenuEntry('လောင်းထားသောပွဲများ', Icons.history, Colors.greenAccent),
    _MenuEntry('ငွေစာရင်းများ', Icons.account_balance_wallet, Colors.purpleAccent),
    _MenuEntry('ငွေသွင်းရန်', Icons.add_circle_outline, Colors.tealAccent),
    _MenuEntry('ငွေထုတ်ရန်', Icons.remove_circle_outline, Colors.pinkAccent),
    _MenuEntry('ကိုယ်ရေးအချက်အလက်', Icons.person_outline, Colors.amberAccent),
    _MenuEntry('Live', Icons.live_tv, Colors.redAccent),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppTheme.navyBackground,
      appBar: AppBar(
        title: const Text(
          'SPORTS BETTING PLATFORM',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        actions: const [
          IconButton(
            onPressed: null,
            icon: Icon(Icons.notifications_none),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const PromoBannerWidget(),
            // Balance is bound live to the backend via the WalletBloc
            // (BLoC State Consumer; periodical refresh handled by the bloc).
            BlocProvider<WalletBloc>(
              create: (_) => WalletBloc(sl<WalletRepository>())
                ..add(const LoadWalletBalance()),
              child: const _LiveBalanceBar(username: 'User9482'),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                childAspectRatio: 1.4,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                children: [
                  for (final entry in _menu)
                    GridMenuCard(
                      title: entry.title,
                      icon: entry.icon,
                      color: entry.color,
                      onTap: () => _onMenuTap(context, entry.title),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onMenuTap(BuildContext context, String title) {
    // Navigation binding point: each cell routes to its feature module
    // (BodySheet, MaungSheet, BetHistoryScreen, LedgerScreen, etc.).
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$title ရွေးချယ်ပြီးပါပြီ')),
    );
  }
}

/// Balance bar consuming the [WalletBloc] state. Falls back to a placeholder
/// while the first snapshot is being fetched.
class _LiveBalanceBar extends StatelessWidget {
  final String username;

  const _LiveBalanceBar({required this.username});

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletBloc>().state.wallet;

    final String balance;
    if (wallet == null) {
      balance = '…';
    } else {
      balance = '${formatUnits(wallet.currentBalance)} ฿';
    }

    return UserProfileInfoBar(username: username, balance: balance);
  }
}

/// Formats a value with thousand separators, e.g. 500000.5 -> "500,000".
String formatUnits(double value) {
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

class _MenuEntry {
  final String title;
  final IconData icon;
  final Color color;

  const _MenuEntry(this.title, this.icon, this.color);
}