import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/service_locator.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/mm_odds_calculator.dart';
import '../../domain/entities/fixture.dart';
import '../../domain/repositories/odds_repository.dart';
import '../bloc/single_bet_bloc.dart';
import '../widgets/fixture_card.dart';

/// Body (single) bet screen: one match, one pick, Myanmar odds preview.
class SingleBetScreen extends StatelessWidget {
  const SingleBetScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Body Bet - တစ်ပွဲတည်း')),
      body: BlocProvider(
        create: (_) => SingleBetBloc(sl<OddsRepository>())
          ..add(const LoadFixtures()),
        child: const _SingleBetView(),
      ),
    );
  }
}

class _SingleBetView extends StatelessWidget {
  const _SingleBetView();

  @override
  Widget build(BuildContext context) {
    final bloc = context.watch<SingleBetBloc>();
    final state = bloc.state;

    return BlocListener<SingleBetBloc, SingleBetState>(
      listener: (context, state) {
        final placed = state.placed;
        if (placed != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'အောင်မြင်ပါသည် — bet #${placed.betId}, '
                'hold ${formatUnits(placed.holdAmount)}, '
                'လက်ကျန် ${formatUnits(placed.currentBalance)}',
              ),
              backgroundColor: AppColors.amber,
            ),
          );
        }
        final error = state.error;
        if (error != null && error.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error), backgroundColor: AppColors.error),
          );
        }
      },
      child: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => bloc.add(const LoadFixtures()),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (state.isLoading)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (state.fixtures.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      'ပွဲစဉ်မရှိသေးပါ',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: AppColors.textDim),
                    ),
                  ),
                )
              else ...[
                for (final fixture in state.fixtures)
                  FixtureCard(
                    fixture: fixture,
                    highlighted:
                        state.selectedFixture?.id == fixture.id,
                    onTap: fixture.isEnabled
                        ? () => bloc.add(SelectFixture(fixture))
                        : null,
                  ),
              ],
              if (state.selectedFixture != null) ...[
                const SizedBox(height: 8),
                _PickRow(bloc: bloc, state: state),
                _StakePanel(bloc: bloc, state: state),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PickRow extends StatelessWidget {
  final SingleBetBloc bloc;
  final SingleBetState state;

  const _PickRow({required this.bloc, required this.state});

  @override
  Widget build(BuildContext context) {
    final fixture = state.selectedFixture!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: _PickButton(
              label: fixture.homeTeam,
              active: state.pick == SelectionPick.home,
              payout: fixture.homeBodyPayout,
              onTap: () => bloc.add(const SelectPick(SelectionPick.home)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _PickButton(
              label: fixture.awayTeam,
              active: state.pick == SelectionPick.away,
              payout: fixture.awayBodyPayout,
              onTap: () => bloc.add(const SelectPick(SelectionPick.away)),
            ),
          ),
        ],
      ),
    );
  }
}

class _PickButton extends StatelessWidget {
  final String label;
  final bool active;
  final double payout;
  final VoidCallback onTap;

  const _PickButton({
    required this.label,
    required this.active,
    required this.payout,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: active ? AppColors.amber : AppColors.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? AppColors.amber : AppColors.edge,
          ),
        ),
        child: Column(
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: active ? const Color(0xFF1A1206) : AppColors.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${payout.toStringAsFixed(2)}x',
              style: TextStyle(
                fontSize: 13,
                color: active ? const Color(0xFF1A1206) : AppColors.amber,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StakePanel extends StatefulWidget {
  final SingleBetBloc bloc;
  final SingleBetState state;

  const _StakePanel({required this.bloc, required this.state});

  @override
  State<_StakePanel> createState() => _StakePanelState();
}

class _StakePanelState extends State<_StakePanel> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.state.stake > 0 ? widget.state.stake.toStringAsFixed(0) : '',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final fixture = state.selectedFixture;
    double mult = 1.0;
    double potential = 0;
    if (fixture != null) {
      final isHome = state.pick == SelectionPick.home;
      final res = MMOddsCalculator.calculateBodyPayout(
        homeGoals: isHome ? 9 : 0,
        awayGoals: isHome ? 0 : 9,
        selectedTeam: isHome ? 'HOME' : 'AWAY',
        handicapLine: fixture.handicap,
      );
      mult = MMOddsCalculator.totalReturn(1.0, res.payoutFactor);
      potential = MMOddsCalculator.totalReturn(state.stake, res.payoutFactor);
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.edge),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('လောင်းကြေး (ကျပ်)', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: AppColors.text, fontSize: 20),
              decoration: InputDecoration(
                hintText: 'အနည်းဆုံး 1000',
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.edge),
                ),
              ),
              onChanged: (value) =>
                  widget.bloc.add(StakeChanged(value.isEmpty ? 0 : double.tryParse(value) ?? 0)),
            ),
            const SizedBox(height: 12),
            Text(
              'ရွေးထားသော ကြေး: ${mult.toStringAsFixed(2)}x   '
              'အနိုင်ရပါက ရမည့်ငွေ: ${formatUnits(potential)}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textDim),
            ),
            const SizedBox(height: 12),
            BetActionButton(
              label: 'လောင်းမည်',
              loading: state.isSubmitting,
              onPressed: () => widget.bloc.add(const SubmitBet()),
            ),
          ],
        ),
      ),
    );
  }
}