import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/di/service_locator.dart';
import '../../../../core/network/api_client.dart';
import '../../data/unit_request_repository.dart';

/// Kind of unit ticket the shared form opens.
enum UnitRequestKind { deposit, withdraw }

/// ငွေသွင်းရန် (Deposit) screen — opens a DEPOSIT ticket for admin approval.
class DepositRequestScreen extends StatelessWidget {
  const DepositRequestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const UnitRequestScreen(kind: UnitRequestKind.deposit);
  }
}

/// ငွေထုတ်ရန် (Withdraw) screen — opens a WITHDRAW ticket for admin approval.
class WithdrawRequestScreen extends StatelessWidget {
  const WithdrawRequestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const UnitRequestScreen(kind: UnitRequestKind.withdraw);
  }
}

/// Shared deposit/withdraw request form. Submits via
/// POST /api/v1/units/request and reports the PENDING ticket state.
class UnitRequestScreen extends StatefulWidget {
  final UnitRequestKind kind;

  const UnitRequestScreen({super.key, required this.kind});

  @override
  State<UnitRequestScreen> createState() => _UnitRequestScreenState();
}

class _UnitRequestScreenState extends State<UnitRequestScreen> {
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _note = TextEditingController();

  bool _busy = false;
  String? _error;

  bool get _isDeposit => widget.kind == UnitRequestKind.deposit;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;

    final double? amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'ပမာဏ (Amount) ၀ ထက်ကြီးသော ကိန်းဂဏန်း ရိုက်ထည့်ပါ');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final repo = sl<UnitRequestRepository>();
      final ack = await repo.create(
        type: _isDeposit ? 'DEPOSIT' : 'WITHDRAW',
        amount: amount,
        note: _note.text,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(_isDeposit ? 'ငွေသွင်း တောင်းဆိုမှု' : 'ငွေထုတ် တောင်းဆိုမှု'),
          content: Text(
            'တောင်းဆိုချက် #${ack.requestId} ကို ${ack.status} အဆင့်တွင် ထားရှိပြီးပါပြီ။\n'
            'Admin မှ အတည်ပြုသည်အထိ စောင့်ဆိုင်းပေးပါ။',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('ရှင်းပါ'),
            ),
          ],
        ),
      );
      _amount.clear();
      _note.clear();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on NetworkException catch (e) {
      if (mounted) setState(() => _error = 'အင်တာနက် ချိတ်ဆက်မှု ရယူ၍မရပါ (${e.message})');
    } catch (_) {
      if (mounted) setState(() => _error = 'တောင်းဆိုမှု မအောင်မြင်ပါ။ ထပ်စမ်းကြည့်ပါ။');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isDeposit ? 'ငွေသွင်းရန် (Deposit)' : 'ငွေထုတ်ရန် (Withdraw)'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _isDeposit
                      ? 'ငွေသွင်း တောင်းဆိုမှုကို Admin မှ အတည်ပြုပြီးမှ လက်ကျန်ငွေတွင် ထည့်သွင်းပေးပါမည်။'
                      : 'ငွေထုတ် တောင်းဆိုမှုကို Admin မှ အတည်ပြုပြီးမှ ငွေလွှဲပေးပါမည်။',
                  style: const TextStyle(fontSize: 13, color: Colors.black87),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(
                labelText: 'ပမာဏ (Amount)',
                prefixIcon: Icon(Icons.payments_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'မှတ်ချက် (Note, မလိုအပ်ပါက ချန်ထားနိုင်သည်)',
                prefixIcon: Icon(Icons.notes_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 24),
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                onPressed: _busy ? null : _submit,
                icon: _busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_isDeposit
                        ? Icons.add_circle_outline
                        : Icons.remove_circle_outline),
                label: Text(_isDeposit ? 'ငွေသွင်းရန် လျှောက်ထားမည်' : 'ငွေထုတ်ရန် လျှောက်ထားမည်'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}