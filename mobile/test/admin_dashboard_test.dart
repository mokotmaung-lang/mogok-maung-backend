import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mogok_maung_mobile/core/di/service_locator.dart';
import 'package:mogok_maung_mobile/features/admin_dashboard/domain/entities/admin_stats_entity.dart';
import 'package:mogok_maung_mobile/features/admin_dashboard/domain/repositories/admin_repository.dart';
import 'package:mogok_maung_mobile/features/admin_dashboard/domain/usecases/get_admin_dashboard_stats.dart';
import 'package:mogok_maung_mobile/features/admin_dashboard/presentation/screens/admin_dashboard_screen.dart';

class _FakeAdminRepository implements AdminRepository {
  @override
  Future<List<AgentEntity>> fetchAgents() async => const [
        AgentEntity(
          id: 1,
          username: 'agent01',
          name: 'Agent Khaing',
          currentBalance: 200000,
          holdBalance: 0,
          activeUsersCount: 2,
          status: 'ACTIVE',
        ),
        AgentEntity(
          id: 2,
          username: 'agent02',
          name: 'Agent Wai Yan',
          currentBalance: 150000,
          holdBalance: 0,
          activeUsersCount: 0,
          status: 'SUSPENDED',
        ),
      ];

  @override
  Future<List<FixtureEntity>> fetchFixtures() async => [
        FixtureEntity(
          id: 1,
          homeTeam: 'Yangon FC',
          awayTeam: 'Mandalay FC',
          leagueName: 'Myanmar League',
          matchTime: DateTime(2026, 9, 12),
          handicapSide: 'HOME',
          handicap: '1+25',
          homeBodyPayout: 0.85,
          awayBodyPayout: 0.95,
          maungHomeMultiplier: 1.1,
          maungAwayMultiplier: 1.2,
          maungDrawMultiplier: 1.3,
          status: 'OPEN',
        ),
      ];

  @override
  Future<SettlementEntity> fetchWeeklySettlement() async =>
      const SettlementEntity(
        agentId: 0,
        agentName: '',
        billingPeriod: '2026-09-07 to 2026-09-13',
        totalBetsCount: 42,
        totalTurnover: 500000,
        totalPayoutWin: 120000,
        totalRetainedLose: 380000,
        netSettlementAmount: 260000,
        settlementStatus: 'PENDING',
      );
}

class _FailingAdminRepository implements AdminRepository {
  @override
  Future<List<AgentEntity>> fetchAgents() async =>
      throw Exception('boom agents');

  @override
  Future<List<FixtureEntity>> fetchFixtures() async =>
      throw Exception('boom fixtures');

  @override
  Future<SettlementEntity> fetchWeeklySettlement() async =>
      throw Exception('boom settlement');
}

// Register a mock repo into GetIt. reset() first so the usecase type is never
// registered twice across tests ("already registered" error) or stale.
// NOTE: get_it >=7.4 reset() is async — must await, otherwise the async reset
// clears the registration we just made ("not registered inside GetIt").
Future<void> _register(AdminRepository repo) async {
  await sl.reset();
  sl.registerLazySingleton<GetAdminDashboardStats>(
    () => GetAdminDashboardStats(repo),
  );
}

// The screen builds its own bloc from GetIt (admin_dashboard_screen.dart:33),
// so pump it as-is after registering the mock in GetIt.
Future<void> _pumpAdminDash(WidgetTester tester, AdminRepository repo) async {
  await _register(repo);
  // The _StatsView is a lazy ListView; use a tall surface so below-the-fold
  // sections (agents, fixtures) are actually built and findable.
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const MaterialApp(
      home: AdminDashboardScreen(
        username: 'superadmin',
        role: 'SUPER_ADMIN',
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 150));
}

void main() {
  tearDown(() async {
    await sl.reset();
  });

  testWidgets('loads agents/fixtures/settlement aggregates', (tester) async {
    await _pumpAdminDash(tester, _FakeAdminRepository());

    expect(find.text('ADMIN DASHBOARD'), findsOneWidget);
    expect(find.text('superadmin'), findsOneWidget);
    expect(find.text('SUPER_ADMIN'), findsOneWidget);

    expect(find.text('2'), findsOneWidget); // agent count card value
    expect(find.text('ဆင်းနေ 1'), findsOneWidget); // active agents subtitle

    expect(find.text('Agent Khaing'), findsOneWidget);
    expect(find.text('Agent Wai Yan'), findsOneWidget);

    expect(find.text('Yangon FC vs Mandalay FC'), findsOneWidget);
    expect(find.textContaining('1+25'), findsOneWidget);

    expect(find.textContaining('bets 42'), findsOneWidget);
    expect(find.textContaining('PENDING'), findsOneWidget);
    expect(find.text('260,000 ကျပ်'), findsOneWidget); // net settlement
  });

  testWidgets('shows error view with retry when repository fails',
      (tester) async {
    await _pumpAdminDash(tester, _FailingAdminRepository());

    expect(find.textContaining('ရယူ၍ မရပါ'), findsOneWidget);
    expect(find.text('ပြန်ကြိုးစားရန်'), findsOneWidget);
  });
}