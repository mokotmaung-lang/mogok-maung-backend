import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Authenticated session, populated after a successful login.
@immutable
class Session {
  final String token;
  final String username;
  final String role;
  final bool mustChangePassword;

  const Session({
    required this.token,
    required this.username,
    required this.role,
    this.mustChangePassword = false,
  });

  Session copyWith({bool? mustChangePassword}) => Session(
        token: token,
        username: username,
        role: role,
        mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      );
}

/// Null until login completes; drives the top-level auth routing in main.dart.
final sessionProvider = StateProvider<Session?>((ref) => null);