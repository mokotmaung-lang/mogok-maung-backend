import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/connectivity_controller.dart';
import '../utils/myanmar_font_engine.dart';

/// Single source of truth for "is the device online?" exposed to the widget
/// tree. Initialised on first read by [OfflineBannerBuilder].
final connectivityProvider = ChangeNotifierProvider<ConnectivityController>(
  (ref) {
    final controller = ConnectivityController();
    controller.init();
    ref.onDispose(controller.dispose);
    return controller;
  },
);

/// `MaterialApp.builder` shim: draws a "No Internet Connection" banner above
/// the Navigator whenever [ConnectivityController] reports offline.
///
/// The banner is a soft indicator only — it never blocks navigation — and it
/// is rendered through [MyanmarFontEngine] so the Burmese label displays on
/// both Zawgyi and Unicode devices.
class OfflineBannerBuilder extends ConsumerWidget {
  const OfflineBannerBuilder({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool offline = ref.watch(connectivityProvider).offline;
    return Column(
      children: [
        if (offline)
          Material(
            color: const Color(0xFFB71C1C),
            child: SafeArea(
              bottom: false,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: MyanmarFontEngine.renderText(
                  'အင်တာနက် ချိတ်ဆက်မှု မရရှိပါ (No Internet Connection)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        Expanded(child: child),
      ],
    );
  }
}