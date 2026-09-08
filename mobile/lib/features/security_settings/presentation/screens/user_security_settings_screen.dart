import 'package:flutter/material.dart';

import '../../../../core/di/service_locator.dart';
import '../../../../core/l10n/myanmar_locale.dart';
import '../../data/security_settings_repository.dart';

/// User security settings screen — rotating the account password, Burmese UI.
///
/// Production behaviour vs. the design mock:
///   - validation mirrors the backend contract (>= 8 characters, current
///     password verified server-side, not client-side),
///   - the submit button blocks while the request is in flight,
///   - wrong current password / server errors surface as a red SnackBar
///     instead of a silent success,
///   - on success all three fields are cleared and the user is notified.
class UserSecuritySettingsScreen extends StatefulWidget {
  const UserSecuritySettingsScreen({super.key});

  @override
  State<UserSecuritySettingsScreen> createState() =>
      _UserSecuritySettingsScreenState();
}

class _UserSecuritySettingsScreenState extends State<UserSecuritySettingsScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _oldPasswordController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  bool _isLoading = false;

  late final SecuritySettingsRepository _repository =
      sl<SecuritySettingsRepository>();

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _updatePassword() async {
    if (_isLoading) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() => _isLoading = true);

    try {
      await _repository.changePassword(
        currentPassword: _oldPasswordController.text,
        newPassword: _newPasswordController.text,
      );

      if (!mounted) return;
      _oldPasswordController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(MyanmarLocale.t('passwordUpdated')),
          backgroundColor: Colors.green,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(MyanmarLocale.t('passwordUpdateFailed')),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          MyanmarLocale.t('securityTitle'),
          style: const TextStyle(fontFamily: 'Pyidaungsu'),
        ),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                MyanmarLocale.t('changePasswordHeading'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.indigo,
                ),
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: _oldPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: MyanmarLocale.t('oldPasswordLabel'),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.lock_outline),
                ),
                validator: (value) => (value == null || value.isEmpty)
                    ? MyanmarLocale.t('oldPasswordRequired')
                    : null,
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: _newPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: MyanmarLocale.t('newPasswordLabel'),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.lock_reset_outlined),
                ),
                validator: (value) =>
                    (value == null || value.length < 8)
                        ? MyanmarLocale.t('passwordTooShort')
                        : null,
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: _confirmPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: MyanmarLocale.t('confirmPasswordLabel'),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.gpp_good_outlined),
                ),
                validator: (value) => (value != _newPasswordController.text)
                    ? MyanmarLocale.t('passwordMismatch')
                    : null,
              ),
              const SizedBox(height: 25),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _updatePassword,
                  style:
                      ElevatedButton.styleFrom(backgroundColor: Colors.indigo),
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Text(
                          MyanmarLocale.t('savePasswordButton'),
                          style:
                              const TextStyle(fontSize: 16, color: Colors.white),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}