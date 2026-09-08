import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/session_provider.dart';
import '../../../wallet/presentation/providers/wallet_provider.dart';

/// Mandatory first-login screen. Shown when the backend reports an account
/// still using the agent-provisioned default password. Betting stays blocked
/// (backend guard: PASSWORD_CHANGE_REQUIRED) until the password is rotated.
class ForcePasswordChangeScreen extends ConsumerStatefulWidget {
  const ForcePasswordChangeScreen({super.key});

  @override
  ConsumerState<ForcePasswordChangeScreen> createState() =>
      _ForcePasswordChangeScreenState();
}

class _ForcePasswordChangeScreenState
    extends ConsumerState<ForcePasswordChangeScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _submitting) return;

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final client = ref.read(apiClientProvider);
      Map<String, dynamic> body = {
        'current_password': _current.text,
        'new_password': _next.text,
      };
      await client.post('/api/v1/user/password', body: body);

      final session = ref.read(sessionProvider);
      if (session != null) {
        ref.read(sessionProvider.notifier).state = session.copyWith(
              mustChangePassword: false,
            );
        ref.invalidate(userBalanceProvider);
      }
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_reset, size: 56, color: Colors.amber),
                  const SizedBox(height: 16),
                  Text(
                    'လုံခြုံရေးအတွက် လျှို့ဝှက်နံပါတ် ပြောင်းပါ',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'သင့်အကောင့်တွင် မူလ (Default) လျှို့ဝှက်နံပါတ် အသုံးပြုဆဲဖြစ်ပါသည်။ '
                    'လောင်းကြေးထပ်ရန် လျှို့ဝှက်နံပါတ်အသစ် ပြောင်းလဲရပါမည်။',
                    style: TextStyle(color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _current,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'လက်ရှိ လျှို့ဝှက်နံပါတ်',
                      prefixIcon: Icon(Icons.key_outlined),
                    ),
                    validator: (v) => (v == null || v.isEmpty)
                        ? 'လက်ရှိ လျှို့ဝှက်နံပါတ် ထည့်ပါ'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _next,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'လျှို့ဝှက်နံပါတ် အသစ်',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                    validator: (v) => (v == null || v.length < 8)
                        ? 'အနည်းဆုံး ၈ လုံး ထည့်ပါ'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _confirm,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'လျှို့ဝှက်နံပါတ် အသစ် (အတည်ပြု)',
                      prefixIcon: Icon(Icons.lock),
                    ),
                    validator: (v) => (v != _next.text)
                        ? 'လျှို့ဝှက်နံပါတ် နှစ်ခု မတူပါ'
                        : null,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 50,
                    child: FilledButton(
                      onPressed: _submitting ? null : _submit,
                      child: _submitting
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('ပြောင်းလဲရန်'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}