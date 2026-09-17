import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/admin_stats_entity.dart';
import '../bloc/admin_dashboard_bloc.dart';
import '../bloc/admin_dashboard_event.dart';
import '../bloc/admin_dashboard_state.dart';
import '../widgets/admin_stat_card.dart';

/// Admin control-plane dashboard (read-only).
///
/// Fetches agents, fixtures and the house-wide weekly settlement through the
/// [AdminDashboardBloc] and renders them as stat cards — no mutating actions
/// are exposed from this screen.
class AdminDashboardScreen extends StatelessWidget {
  final String username;
  final String role;

  const AdminDashboardScreen({super.key, required this.username, required this.role});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.navyBackground,
      appBar: AppBar(
        title: const Text(
          'ADMIN DASHBOARD',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
      body: BlocProvider<AdminDashboardBloc>(
        create: (_) => createAdminDashboardBloc()
          ..add(const LoadAdminDashboardStats()),
        child: BlocBuilder<AdminDashboardBloc, AdminDashboardState>(
          builder: (context, state) {
            switch (state) {
              case AdminDashboardInitial():
              case AdminDashboardLoading():
                return const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                );
              case AdminDashboardError(:final error):
                return _ErrorView(
                  message: error,
                  onRetry: () => context
                      .read<AdminDashboardBloc>()
                      .add(const RefreshAdminDashboardStats()),
                );
              case AdminDashboardLoaded(:final stats):
                return RefreshIndicator(
                  onRefresh: () async {
                    context
                        .read<AdminDashboardBloc>()
                        .add(const RefreshAdminDashboardStats());
                    // RefreshIndicator needs a future; the bloc reload is
                    // brief, a fire-and-forget retrigger is sufficient here.
                  },
                  child: _StatsView(username: username, role: role, stats: stats),
                );
            }
          },
        ),
      ),
    );
  }
}

class _StatsView extends StatelessWidget {
  final String username;
  final String role;
  final AdminDashboardStats stats;

  const _StatsView({
    required this.username,
    required this.role,
    required this.stats,
  });

  String _kyat(double value) {
    final raw = value.toStringAsFixed(0);
    final buf = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      if (i > 0 && (raw.length - i) % 3 == 0) buf.write(',');
      buf.write(raw[i]);
    }
    return '$buf';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _RoleHeader(username: username, role: role),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AdminStatCard(
                label: 'အေးဂျင့်များ',
                value: '${stats.agents.length}',
                icon: Icons.groups_outlined,
                color: AppTheme.accentBlue,
                subtitle: 'ဆင်းနေ ${stats.countActiveAgents}',
                secondary: 'ပိတ်ထား '
                    '${stats.agents.length - stats.countActiveAgents}',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AdminStatCard(
                label: 'ပွဲများ',
                value: '${stats.fixtures.length}',
                icon: Icons.sports_soccer,
                color: AppTheme.accentAmber,
                subtitle: 'ဖွင့်ထား ${stats.countOpenFixtures}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        AdminStatCard(
          label: 'အပတ်စဉ် စာရင်း (settlement)',
          value: '${_kyat(stats.settlement.netSettlementAmount)} ကျပ်',
          icon: Icons.account_balance_outlined,
          color: AppColors.amber,
          subtitle:
              'bets ${stats.settlement.totalBetsCount} · status ${stats.settlement.settlementStatus}',
          secondary: 'turnover ${_kyat(stats.settlement.totalTurnover)} · '
              'win ${_kyat(stats.settlement.totalPayoutWin)} · '
              'lose ${_kyat(stats.settlement.totalRetainedLose)}',
        ),
        const SizedBox(height: 18),
        Text(
          'အေးဂျင့်များ စာရင်း',
          style: theme.textTheme.titleMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        _AgentsList(agents: stats.agents),
        const SizedBox(height: 18),
        Text(
          'ပွဲစဉ်များ စာရင်း',
          style: theme.textTheme.titleMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        _FixturesList(fixtures: stats.fixtures),
      ],
    );
  }
}

class _RoleHeader extends StatelessWidget {
  final String username;
  final String role;

  const _RoleHeader({required this.username, required this.role});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: AppTheme.accentBlue,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.shield_outlined, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              username,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: role == 'SUPER_ADMIN'
                    ? AppTheme.accentAmber
                    : AppTheme.navySurface,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                role,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AgentsList extends StatelessWidget {
  final List<AgentEntity> agents;

  const _AgentsList({required this.agents});

  @override
  Widget build(BuildContext context) {
    if (agents.isEmpty) {
      return const Text(
        'အေးဂျင့် မရှိသေးပါ',
        style: TextStyle(color: AppColors.textDim),
      );
    }
    return _ListCard(
      children: [
        for (final agent in agents)
          _ListTileData(
            title: agent.name.isNotEmpty ? agent.name : agent.username,
            subtitle: '@${agent.username} · active ${agent.activeUsersCount}',
            trailingStatus: agent.status,
            trailingColor: agent.isActive
                ? Colors.greenAccent
                : AppColors.textDim,
            icon: agent.isActive
                ? Icons.person_outline
                : Icons.person_off_outlined,
            iconColor: agent.isActive ? AppTheme.accentBlue : AppColors.textDim,
          ),
      ],
    );
  }
}

class _FixturesList extends StatelessWidget {
  final List<FixtureEntity> fixtures;

  const _FixturesList({required this.fixtures});

  @override
  Widget build(BuildContext context) {
    if (fixtures.isEmpty) {
      return const Text(
        'ပွဲ မရှိသေးပါ',
        style: TextStyle(color: AppColors.textDim),
      );
    }
    return _ListCard(
      children: [
        for (final fixture in fixtures)
          _ListTileData(
            title: '${fixture.homeTeam} vs ${fixture.awayTeam}',
            subtitle: '${fixture.leagueName} · ${fixture.handicap}',
            trailingStatus: fixture.status,
            trailingColor:
                fixture.isOpen ? Colors.greenAccent : AppColors.textDim,
            icon: Icons.sports_soccer,
            iconColor: fixture.isOpen ? AppTheme.accentAmber : AppColors.textDim,
          ),
      ],
    );
  }
}

class _ListCard extends StatelessWidget {
  final List<Widget> children;

  const _ListCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _ListTileData extends StatelessWidget {
  final String title;
  final String subtitle;
  final String trailingStatus;
  final Color trailingColor;
  final IconData icon;
  final Color iconColor;

  const _ListTileData({
    required this.title,
    required this.subtitle,
    required this.trailingStatus,
    required this.trailingColor,
    required this.icon,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(
        title,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: AppColors.textDim, fontSize: 12),
      ),
      trailing: Text(
        trailingStatus,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: trailingColor,
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: AppColors.error, size: 40),
          const SizedBox(height: 12),
          Text(
            'စာရင်း ရယူ၍ မရပါ ($message)',
            style: const TextStyle(color: AppColors.textDim),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onRetry,
            child: const Text('ပြန်ကြိုးစားရန်'),
          ),
        ],
      ),
    );
  }
}