import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/config/app_config.dart';
import '../../data/wallet_repository.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class WalletEvent {
  const WalletEvent();
}

class LoadWalletBalance extends WalletEvent {
  const LoadWalletBalance();
}

class RefreshWalletBalance extends WalletEvent {
  const RefreshWalletBalance();
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class WalletState {
  final WalletSnapshot? wallet;
  final bool isLoading;
  final Object? error;

  const WalletState({this.wallet, this.isLoading = false, this.error});

  WalletState copyWith({
    WalletSnapshot? wallet,
    bool clearWallet = false,
    bool? isLoading,
    Object? error,
    bool clearError = false,
  }) {
    return WalletState(
      wallet: clearWallet ? null : wallet ?? this.wallet,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
    );
  }
}

// ---------------------------------------------------------------------------
// Bloc
// ---------------------------------------------------------------------------

/// Live wallet feed driven by BLoC State Consumers.
///
/// Fetches the balance immediately on [LoadWalletBalance] and then keeps a
/// lightweight periodical ticker ([AppConfig.balanceRefreshInterval]) so
/// deposits, holds and settlements appear live on the dashboard without
/// manual refresh — the audit-mandated "Custom User Info Bar + BLoC State
/// Consumer" binding.
class WalletBloc extends Bloc<WalletEvent, WalletState> {
  final WalletRepository _repository;
  Timer? _ticker;

  WalletBloc(this._repository) : super(const WalletState()) {
    on<LoadWalletBalance>(_load);
    on<RefreshWalletBalance>(_load);
  }

  Future<void> _load(WalletEvent event, Emitter<WalletState> emit) async {
    final initial = event is LoadWalletBalance;
    if (initial) emit(state.copyWith(isLoading: true, clearError: true));
    try {
      final wallet = await _repository.fetchWallet();
      emit(state.copyWith(wallet: wallet, isLoading: false));
      _ensureTicker();
    } catch (e) {
      if (initial) emit(state.copyWith(isLoading: false, error: e));
    }
  }

  void _ensureTicker() {
    _ticker ??= Timer.periodic(AppConfig.balanceRefreshInterval, (_) {
      add(const RefreshWalletBalance());
    });
  }

  @override
  Future<void> close() {
    _ticker?.cancel();
    _ticker = null;
    return super.close();
  }
}