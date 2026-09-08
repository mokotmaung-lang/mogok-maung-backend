import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/service_locator.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/mm_odds_calculator.dart';
import '../../domain/entities/fixture.dart';
import '../../domain/repositories/odds_repository.dart';
import '../bloc/mix_parlay_bloc.dart';
import '../widgets/fixture_card.dart';

/// Maung (mix parlay) screen: combine 2+ matches into one ticket.
/// Maung pays at most 2x the stake per the platform cap.
class MixParlayScreen extends StatelessWidget {
  const MixParlayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Maung Bet - မောင်')),
      body: BlocProvider(
        create: (_) => MixParlayBloc(sl<OddsRepository>())
          ..add(const LoadParlayFixtures()),
        child: const _MixParlayView(),
      ),
    );
  }
}

class _MixParlayView extends StatelessWidget {
  const _MixParlayView();

  @override
  Widget build(BuildContext context) {
    final bloc = context.watch<MixParlayBloc>();
    final state = bloc.state;

    return BlocListener<MixParlayBloc, MixParlayState>(
      listener: (context, state) {
        final placed = state.placed;
        if (placed != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Maung အောင်မြင်ပါသည် — bet #${placed.betId}, '
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
          onRefresh: () async => bloc.add(const LoadParlayFixtures()),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _TicketSummary(state: state, bloc: bloc),
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
              else
                for (final fixture in state.fixtures) _fixtureRow(bloc, state, fixture),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fixtureRow(MixParlayBloc bloc, MixParlayState state, FixtureTeam fixture) {
    final pick = state.selections[fixture.id];
    return FixtureCard(
      fixture: fixture,
      highlighted: pick != null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _miniPick(
            label: 'အိမ်',
            active: pick == SelectionPick.home,
            onTap: () => bloc.add(ToggleSelection(fixture, SelectionPick.home)),
          ),
          const SizedBox(width: 6),
          _miniPick(
            label: 'အဝေး',
            active: pick == SelectionPick.away,
            onTap: () => bloc.add(ToggleSelection(fixture, SelectionPick.away)),
          ),
        ],
      ),
    );
  }

  Widget _miniPick({required String label, required bool active, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.amber : AppColors.background,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? AppColors.amber : AppColors.edge,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: active ? const Color(0xFF1A1206) : AppColors.textDim,
          ),
        ),
      ),
    );
  }
}

class _TicketSummary extends StatefulWidget {
  final MixParlayState state;
  final MixParlayBloc bloc;

  const _TicketSummary({required this.state, required this.bloc});

  @override
  State<_TicketSummary> createState() => _TicketSummaryState();
}

class _TicketSummaryState extends State<_TicketSummary> {
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
    final count = state.selections.length;
    final results = <MMOddsResult>[];
    for (final f in state.fixtures) {
      final pick = state.selections[f.id];
      if (pick == null) continue;
      final isHome = pick == SelectionPick.home;
      results.add(MMOddsCalculator.calculateBodyPayout(
        homeGoals: isHome ? 9 : 0,
        awayGoals: isHome ? 0 : 9,
        selectedTeam: isHome ? 'HOME' : 'AWAY',
        handicapLine: f.handicap,
      ));
    }
    final combined = MMOddsCalculator.calculateMaungTotalPayout(results);
    final potential = state.stake * combined;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.amber),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Maung အကြောင်းအရာ',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: AppColors.amber),
            ),
            const SizedBox(height: 8),
            Text(
              'ရွေးထားသော: $count ပွဲ   ပေါင်းကြေး: ${combined.toStringAsFixed(2)}x',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textDim),
            ),
            const Text(
              'Maung ကန့်သတ်: အနိုင်ရပါက ပေါင်းကြေးအတိုင်း ရမည်',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: AppColors.text, fontSize: 20),
              decoration: InputDecoration(
                hintText: 'လောင်းကြေး',
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.edge),
                ),
              ),
              onChanged: (value) => widget.bloc
                  .add(ParlayStakeChanged(value.isEmpty ? 0 : double.tryParse(value) ?? 0)),
            ),
            const SizedBox(height: 8),
            Text(
              'ရနိုင်ငွေ: ${formatUnits(potential)}   '
              '(ပေါင်းကြေး ${combined.toStringAsFixed(2)}x)',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textDim),
            ),
            const SizedBox(height: 12),
            BetActionButton(
              label: 'Maung လောင်းမည်',
              loading: state.isSubmitting,
              onPressed: state.selections.length < 2
                  ? null
                  : () => widget.bloc.add(const SubmitParlay()),
            ),
            if (count > 0) ...[
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => widget.bloc.add(const ClearSelections()),
                child: const Text('ရှင်းလင်းရန်'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}