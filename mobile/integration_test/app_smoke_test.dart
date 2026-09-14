import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:mogok_maung_mobile/core/config/app_config.dart';
import 'package:mogok_maung_mobile/core/di/service_locator.dart';
import 'package:mogok_maung_mobile/main.dart';

/// Device smoke test (run via `flutter test integration_test`).
///
/// Requires a running local backend when API_BASE_URL points at one:
///   flutter test integration_test -d emulator-5554 \
///     --dart-define=API_BASE_URL=http://10.0.2.2:8081 \
///     --dart-define=WS_BASE_URL=ws://10.0.2.2:8081
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app boots to login screen and backend answers health ping',
      (tester) async {
    // Mirror the real entry point: DI first, keep the app shell channel-free
    // so the test does not depend on Hive/locale platform channels.
    setupServiceLocator();

    await tester.pumpWidget(const ProviderScope(child: MogokMaungApp()));
    await tester.pump(const Duration(milliseconds: 300));

    // Without a stored session the router must land on the login screen.
    expect(find.text('Username'), findsOneWidget,
        reason: 'login screen did not render');
    expect(find.text('အကောင့်ဝင်ရန် (Login)'), findsOneWidget,
        reason: 'login button not found');

    // Backend reachability: the health endpoint must answer from this device
    // (on the Android emulator the host loopback is 10.0.2.2). Fails loudly
    // when the local stack is not running or the base URL is misconfigured.
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/v1/health');
    final status = await http
        .get(uri)
        .timeout(const Duration(seconds: 10))
        .then((r) => r.statusCode);

    expect(status, 200, reason: 'GET $uri did not return 200');
  });
}