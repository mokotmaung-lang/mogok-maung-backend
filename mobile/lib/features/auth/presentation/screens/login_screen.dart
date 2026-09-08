import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/providers/session_provider.dart';
import '../../../wallet/presentation/providers/wallet_provider.dart';

/// Entry authentication screen. On success it seeds the session (token, role,
/// and the must_change_password gate) which the AuthGate in main.dart uses to
/// route straight to the mandatory password change screen when required.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final String u = _username.text.trim();
    final String p = _password.text;
    if (u.isEmpty || p.isEmpty || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = ApiClient(baseUrl: AppConfig.apiBaseUrl);
      final json = await client.post('/api/v1/auth/login', body: {
        'username': u,
        'password': p,
      });

      final session = Session(
        token: json['access_token'] as String,
        username: u,
        role: (json['role'] as String?) ?? 'USER',
        mustChangePassword: (json['must_change_password'] as bool?) ?? false,
      );
      ref.read(sessionProvider.notifier).state = session;
      ref.invalidate(userBalanceProvider);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'ချိတ်ဆက်၍မရပါ (network error)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.sports_soccer,
                  size: 64,
                  color: Colors.greenAccent,
                ),
                const SizedBox(height: 8),
                Text(
                  'SPORTS BETTING PLATFORM',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _username,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  onSubmitted: (_) => _login(),
                  decoration: const InputDecoration(
                    labelText: 'လျှို့ဝှက်နံပါတ်',
                    prefixIcon: Icon(Icons.key_outlined),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  height: 50,
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _login,
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('အကောင့်ဝင်ရန် (Login)'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}