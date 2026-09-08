import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/fixture.dart';
import '../../domain/repositories/odds_repository.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class MixParlayEvent {
  const MixParlayEvent();
}

class LoadParlayFixtures extends MixParlayEvent {
  const LoadParlayFixtures();
}

class ToggleSelection extends MixParlayEvent {
  final FixtureTeam fixture;
  final SelectionPick pick;
  const ToggleSelection(this.fixture, this.pick);
}

class ParlayStakeChanged extends MixParlayEvent {
  final double stake;
  const ParlayStakeChanged(this.stake);
}

class ClearSelections extends MixParlayEvent {
  const ClearSelections();
}

class SubmitParlay extends MixParlayEvent {
  const SubmitParlay();
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class MixParlayState {
  final List<FixtureTeam> fixtures;
  final Map<int, SelectionPick> selections; // fixtureId -> pick
  final double stake;
  final bool isLoading;
  final bool isSubmitting;
  final String? error;
  final BetPlacement? placed;

  const MixParlayState({
    this.fixtures = const [],
    this.selections = const {},
    this.stake = 0,
    this.isLoading = false,
    this.isSubmitting = false,
    this.error,
    this.placed,
  });

  List<SelectionInput> get selectionInputs => selections.entries
      .map((e) => SelectionInput(
            matchId: e.key,
            pick: e.value,
            bodyOddsType: _handicapFor(e.key),
          ))
      .toList();

  String? _handicapFor(int fixtureId) {
    for (final f in fixtures) {
      if (f.id == fixtureId) return f.handicap;
    }
    return null;
  }

  MixParlayState copyWith({
    List<FixtureTeam>? fixtures,
    Map<int, SelectionPick>? selections,
    double? stake,
    bool? isLoading,
    bool? isSubmitting,
    String? error,
    bool clearError = false,
    BetPlacement? placed,
  }) {
    return MixParlayState(
      fixtures: fixtures ?? this.fixtures,
      selections: selections ?? this.selections,
      stake: stake ?? this.stake,
      isLoading: isLoading ?? this.isLoading,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : error ?? this.error,
      placed: placed ?? this.placed,
    );
  }
}

// ---------------------------------------------------------------------------
// Bloc
// ---------------------------------------------------------------------------

class MixParlayBloc extends Bloc<MixParlayEvent, MixParlayState> {
  final OddsRepository _repository;

  MixParlayBloc(this._repository) : super(const MixParlayState()) {
    on<LoadParlayFixtures>(_loadFixtures);
    on<ToggleSelection>(_toggle);
    on<ParlayStakeChanged>(
        (event, emit) => emit(state.copyWith(stake: event.stake)));
    on<ClearSelections>(
        (event, emit) => emit(state.copyWith(selections: const {}, clearError: true)));
    on<SubmitParlay>(_submit);
  }

  Future<void> _loadFixtures(
    LoadParlayFixtures event,
    Emitter<MixParlayState> emit,
  ) async {
    if (state.isLoading && state.fixtures.isEmpty) return;
    emit(state.copyWith(isLoading: true, clearError: true));
    try {
      final fixtures = await _repository.fetchEnabledFixtures();
      emit(state.copyWith(isLoading: false, fixtures: fixtures));
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Matches loaded: $e'));
    }
  }

  void _toggle(ToggleSelection event, Emitter<MixParlayState> emit) {
    final current = state.selections;
    final next = Map<int, SelectionPick>.from(current);
    final existing = next[event.fixture.id];
    if (existing == event.pick) {
      next.remove(event.fixture.id);
    } else {
      next[event.fixture.id] = event.pick;
    }
    emit(state.copyWith(selections: Map.unmodifiable(next), clearError: true));
  }

  Future<void> _submit(
    SubmitParlay event,
    Emitter<MixParlayState> emit,
  ) async {
    if (state.selections.length < 2) {
      emit(state.copyWith(error: 'အနည်းဆုံး နှစ်ပွဲရွေးပါ'));
      return;
    }
    if (state.stake < 1000) {
      emit(state.copyWith(error: 'အနည်းဆုံး ၁,၀၀၀ ကျပ်ထည့်ပါ'));
      return;
    }
    emit(state.copyWith(isSubmitting: true, clearError: true));
    try {
      final placed = await _repository.placeMaungBet(
        selections: state.selectionInputs,
        stake: state.stake,
      );
      emit(state.copyWith(
        isSubmitting: false,
        placed: placed,
        stake: 0,
        selections: const {},
      ));
    } catch (e) {
      emit(state.copyWith(isSubmitting: false, error: e.toString()));
    }
  }
}