import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mogok_maung_mobile/core/di/service_locator.dart';
import 'package:mogok_maung_mobile/core/network/api_client.dart';
import 'package:mogok_maung_mobile/core/network/live_odds_client.dart';
import 'package:mogok_maung_mobile/features/betting/domain/entities/fixture.dart';
import 'package:mogok_maung_mobile/features/betting/domain/repositories/odds_repository.dart';
import 'package:mogok_maung_mobile/features/betting/presentation/screens/mix_parlay_screen.dart';
import 'package:mogok_maung_mobile/features/betting/presentation/screens/single_bet_screen.dart';
import 'package:mogok_maung_mobile/features/dashboard/presentation/screens/dashboard_screen.dart';
import 'package:mogok_maung_mobile/features/dashboard/presentation/screens/profile_screen.dart';
import 'package:mogok_maung_mobile/features/history/data/bet_history_repository.dart';
import 'package:mogok_maung_mobile/features/history/domain/bet_history_item.dart';
import 'package:mogok_maung_mobile/features/history/presentation/screens/bet_history_screen.dart';
import 'package:mogok_maung_mobile/features/live_match/domain/live_odds_models.dart';
import 'package:mogok_maung_mobile/features/live_match/presentation/screens/live_match_screen.dart';
import 'package:mogok_maung_mobile/features/wallet/data/unit_request_repository.dart';
import 'package:mogok_maung_mobile/features/wallet/data/wallet_repository.dart';
import 'package:mogok_maung_mobile/features/wallet/presentation/screens/transaction_history_screen.dart';
import 'package:mogok_maung_mobile/features/wallet/presentation/screens/unit_request_screen.dart';

class _FakeOddsRepository implements OddsRepository {
  @override
  Future<List<FixtureTeam>> fetchEnabledFixtures() async => const [];

  @override
  Future<BetPlacement> placeBodyBet({
    required int fixtureId,
    required SelectionPick pick,
    required double stake,
    required String handicap,
  }) =>
      throw UnimplementedError();

  @override
  Future<BetPlacement> placeMaungBet({
    required List<SelectionInput> selections,
    required double stake,
  }) =>
      throw UnimplementedError();
}

class _FakeBetHistoryRepository extends BetHistoryRepository {
  _FakeBetHistoryRepository()
      : super(
          client: ApiClient(
            baseUrl: 'http://localhost',
            httpClient: MockClient(
              (_) async => http.Response('{"data":{"bets":[]}}', 200),
            ),
          ),
        );

  @override
  Future<List<BetHistoryItem>> fetchBetHistory(
      {int limit = 20, int offset = 0}) async =>
      const [];
}

class _FakeLiveOddsClient extends LiveOddsClient {
  _FakeLiveOddsClient() : super(tokenProvider: () => null);

  @override
  void connect() {}

  @override
  Stream<LiveOddsConnection> get connection => const Stream.empty();

  @override
  Stream<LiveOddsSnapshot> get odds => const Stream.empty();
}

void _registerFakes() {
  sl.registerSingleton<WalletRepository>(
    WalletRepository(
      client: ApiClient(
        baseUrl: 'http://localhost',
        httpClient: MockClient(
          (_) async =>
              http.Response('{"current_balance":10000,"hold_balance":0}', 200),
        ),
      ),
    ),
  );
  sl.registerSingleton<OddsRepository>(_FakeOddsRepository());
  sl.registerSingleton<BetHistoryRepository>(_FakeBetHistoryRepository());
  sl.registerSingleton<LiveOddsClient>(_FakeLiveOddsClient());
  sl.registerSingleton<UnitRequestRepository>(
    UnitRequestRepository(
      client: ApiClient(
        baseUrl: 'http://localhost',
        httpClient: MockClient(
          (_) async =>
              http.Response('{"data":{"requests":[]}}', 200),
        ),
      ),
    ),
  );
}

Future<void> _pumpDashboard(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: DashboardScreen())),
  );
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _tapTile(WidgetTester tester, String title) async {
  final Finder tile = find.text(title);
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(tile, warnIfMissed: false);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUp(_registerFakes);
  tearDown(() {
    sl.reset();
  });

  group('Dashboard grid tiles respond to taps', () {
    testWidgets('ဘော်ဒီ navigates to SingleBetScreen', (tester) async {
      await _pumpDashboard(tester);
      await _tapTile(tester, 'ဘော်ဒီ');
      await tester.pumpAndSettle();
      expect(find.byType(SingleBetScreen), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('မောင်း navigates to MixParlayScreen', (tester) async {
      await _pumpDashboard(tester);
      await _tapTile(tester, 'မောင်း');
      await tester.pumpAndSettle();
      expect(find.byType(MixParlayScreen), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('လောင်းထားသောပွဲများ navigates to BetHistoryScreen',
        (tester) async {
      await _pumpDashboard(tester);
      await _tapTile(tester, 'လောင်းထားသောပွဲများ');
      await tester.pumpAndSettle();
      expect(find.byType(BetHistoryScreen), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('Live navigates to LiveMatchScreen', (tester) async {
      await _pumpDashboard(tester);
      await _tapTile(tester, 'Live');
      await tester.pumpAndSettle();
      expect(find.byType(LiveMatchScreen), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('ငွေစာရင်းများ navigates to TransactionHistoryScreen',
        (tester) async {
      await _pumpDashboard(tester);
      await _tapTile(tester, 'ငွေစာရင်းများ');
      await tester.pumpAndSettle();
      expect(find.byType(TransactionHistoryScreen), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('ငွေသွင်းရန် navigates to DepositRequestScreen', (tester) async {
      await _pumpDashboard(tester);
      await _tapTile(tester, 'ငွေသွင်းရန်');
      await tester.pumpAndSettle();
      expect(find.byType(DepositRequestScreen), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('ငွေထုတ်ရန် navigates to WithdrawRequestScreen', (tester) async {
      await _pumpDashboard(tester);
      await _tapTile(tester, 'ငွေထုတ်ရန်');
      await tester.pumpAndSettle();
      expect(find.byType(WithdrawRequestScreen), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('ကိုယ်ရေးအချက်အလက် navigates to ProfileScreen',
        (tester) async {
      await _pumpDashboard(tester);
      await _tapTile(tester, 'ကိုယ်ရေးအချက်အလက်');
      await tester.pumpAndSettle();
      expect(find.byType(ProfileScreen), findsOneWidget);
      await _unmount(tester);
    });
  });
}