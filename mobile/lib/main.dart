import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/di/service_locator.dart';
import 'core/l10n/myanmar_locale.dart';
import 'core/network/offline_cache.dart';
import 'core/providers/session_provider.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/offline_banner_builder.dart';
import 'features/auth/presentation/screens/force_password_change_screen.dart';
import 'features/auth/presentation/screens/login_screen.dart';
import 'features/admin_dashboard/presentation/screens/admin_dashboard_screen.dart';
import 'features/dashboard/presentation/screens/dashboard_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setupServiceLocator();
  try {
    await OfflineCache.instance.init();
  } catch (_) {
    // Cache is a soft dependency: transport still works, offline rehydration
    // is simply skipped. Never let storage failures block the app shell.
  }
  try {
    await MyanmarLocale.loadLocale();
  } catch (_) {
    // Locale is a soft dependency: fall back to embedded keys, never crash.
  }
  runApp(const ProviderScope(child: MogokMaungApp()));
}

class MogokMaungApp extends StatelessWidget {
  const MogokMaungApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mogok Maung',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const AuthGate(),
      // Injects the offline banner above the Navigator for every route.
      builder: (context, child) => OfflineBannerBuilder(child: child ?? const SizedBox.shrink()),
    );
  }
}

/// Session-driven router:
///  - no session        -> LoginScreen
///  - must change pw    -> ForcePasswordChangeScreen (backend blocks betting)
///  - SUPER_ADMIN/ADMIN -> AdminDashboardScreen (control plane)
///  - otherwise         -> DashboardScreen with live wallet binding
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Mirror the Riverpod session token into the GetIt containers so the
    // BLoC repositories (wallet, odds) share one bearer credential.
    ref.listenManual<Session?>(
      sessionProvider,
      (previous, next) => setSessionToken(next?.token),
      fireImmediately: true,
    );

    final session = ref.watch(sessionProvider);

    if (session == null) {
      return const LoginScreen();
    }
    if (session.mustChangePassword) {
      return const ForcePasswordChangeScreen();
    }
    if (session.role == 'SUPER_ADMIN' || session.role == 'ADMIN') {
      return AdminDashboardScreen(username: session.username, role: session.role);
    }
    return const DashboardScreen();
  }
}