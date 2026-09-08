import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/bet_history_repository.dart';
import '../../domain/bet_history_item.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class BetHistoryEvent {
  const BetHistoryEvent();
}

/// Initial load or explicit refresh (drop existing history, restart paging).
class LoadBetHistory extends BetHistoryEvent {
  const LoadBetHistory();
}

/// User pull-to-refresh; same semantics as [LoadBetHistory].
class RefreshBetHistory extends BetHistoryEvent {
  const RefreshBetHistory();
}

/// User scrolled to the end; append the next page when available.
class LoadMoreBetHistory extends BetHistoryEvent {
  const LoadMoreBetHistory();
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class BetHistoryState {
  final List<BetHistoryItem> items;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final Object? error;

  const BetHistoryState({
    this.items = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.error,
  });

  BetHistoryState copyWith({
    List<BetHistoryItem>? items,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    Object? error,
    bool clearError = false,
  }) {
    return BetHistoryState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : error ?? this.error,
    );
  }
}

// ---------------------------------------------------------------------------
// Bloc
// ---------------------------------------------------------------------------

/// Paged feed of the authenticated user's betting history.
class BetHistoryBloc extends Bloc<BetHistoryEvent, BetHistoryState> {
  static const int _pageSize = 20;

  final BetHistoryRepository _repository;
  int _nextOffset = 0;

  BetHistoryBloc(this._repository) : super(const BetHistoryState()) {
    on<LoadBetHistory>(_load);
    on<RefreshBetHistory>(_load);
    on<LoadMoreBetHistory>(_loadMore);
  }

  Future<void> _load(BetHistoryEvent event, Emitter<BetHistoryState> emit) async {
    emit(state.copyWith(isLoading: true, clearError: true));
    try {
      final items = await _repository.fetchBetHistory(
        limit: _pageSize,
        offset: 0,
      );
      _nextOffset = items.length;
      emit(state.copyWith(
        items: items,
        isLoading: false,
        hasMore: items.length == _pageSize,
      ));
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: e));
    }
  }

  Future<void> _loadMore(BetHistoryEvent event, Emitter<BetHistoryState> emit) async {
    if (state.isLoading || state.isLoadingMore || !state.hasMore) return;

    emit(state.copyWith(isLoadingMore: true, clearError: true));
    try {
      final more = await _repository.fetchBetHistory(
        limit: _pageSize,
        offset: _nextOffset,
      );
      _nextOffset += more.length;
      emit(state.copyWith(
        items: [...state.items, ...more],
        isLoadingMore: false,
        hasMore: more.length == _pageSize,
      ));
    } catch (_) {
      // A failed page load should not wipe already-visible history; the user
      // triggers a retry by scrolling again or pull-to-refreshing.
      emit(state.copyWith(isLoadingMore: false));
    }
  }
}