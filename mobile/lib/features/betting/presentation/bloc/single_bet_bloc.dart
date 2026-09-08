import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/fixture.dart';
import '../../domain/repositories/odds_repository.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class SingleBetEvent {
  const SingleBetEvent();
}

class LoadFixtures extends SingleBetEvent {
  const LoadFixtures();
}

class SelectFixture extends SingleBetEvent {
  final FixtureTeam fixture;
  const SelectFixture(this.fixture);
}

class SelectPick extends SingleBetEvent {
  final SelectionPick pick;
  const SelectPick(this.pick);
}

class StakeChanged extends SingleBetEvent {
  final double stake;
  const StakeChanged(this.stake);
}

class SubmitBet extends SingleBetEvent {
  const SubmitBet();
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class SingleBetState {
  final List<FixtureTeam> fixtures;
  final FixtureTeam? selectedFixture;
  final SelectionPick pick;
  final double stake;
  final bool isLoading;
  final bool isSubmitting;
  final String? error;
  final BetPlacement? placed;

  const SingleBetState({
    this.fixtures = const [],
    this.selectedFixture,
    this.pick = SelectionPick.home,
    this.stake = 0,
    this.isLoading = false,
    this.isSubmitting = false,
    this.error,
    this.placed,
  });

  SingleBetState copyWith({
    List<FixtureTeam>? fixtures,
    FixtureTeam? selectedFixture,
    bool clearSelection = false,
    SelectionPick? pick,
    double? stake,
    bool? isLoading,
    bool? isSubmitting,
    String? error,
    bool clearError = false,
    BetPlacement? placed,
  }) {
    return SingleBetState(
      fixtures: fixtures ?? this.fixtures,
      selectedFixture: clearSelection ? null : selectedFixture ?? this.selectedFixture,
      pick: pick ?? this.pick,
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

class SingleBetBloc extends Bloc<SingleBetEvent, SingleBetState> {
  final OddsRepository _repository;

  SingleBetBloc(this._repository) : super(const SingleBetState()) {
    on<LoadFixtures>(_loadFixtures);
    on<SelectFixture>((event, emit) =>
        emit(state.copyWith(selectedFixture: event.fixture, clearError: true)));
    on<SelectPick>((event, emit) =>
        emit(state.copyWith(pick: event.pick, clearError: true)));
    on<StakeChanged>(
        (event, emit) => emit(state.copyWith(stake: event.stake)));
    on<SubmitBet>(_submit);
  }

  Future<void> _loadFixtures(
    LoadFixtures event,
    Emitter<SingleBetState> emit,
  ) async {
    if (!state.isLoading && state.fixtures.isNotEmpty) return;
    emit(state.copyWith(isLoading: true, clearError: true));
    try {
      final fixtures = await _repository.fetchEnabledFixtures();
      emit(state.copyWith(isLoading: false, fixtures: fixtures));
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        clearError: false,
        error: 'Matches loaded: ${e.toString()}',
      ));
    }
  }

  Future<void> _submit(SubmitBet event, Emitter<SingleBetState> emit) async {
    final fixture = state.selectedFixture;
    if (fixture == null) {
      emit(state.copyWith(error: 'ပွဲတစ်ပွဲရွေးပါ'));
      return;
    }
    if (state.stake < 1000) {
      emit(state.copyWith(error: 'အနည်းဆုံး ၁,၀၀၀ ကျပ်ထည့်ပါ'));
      return;
    }
    emit(state.copyWith(isSubmitting: true, clearError: true));
    try {
      final placed = await _repository.placeBodyBet(
        fixtureId: fixture.id,
        pick: state.pick,
        stake: state.stake,
        handicap: fixture.handicap,
      );
      emit(state.copyWith(
        isSubmitting: false,
        placed: placed,
        stake: 0,
        clearSelection: true,
      ));
    } catch (e) {
      emit(state.copyWith(isSubmitting: false, error: e.toString()));
    }
  }
}