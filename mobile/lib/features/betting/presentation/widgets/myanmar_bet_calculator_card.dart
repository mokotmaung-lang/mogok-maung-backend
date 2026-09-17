import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_theme.dart';
import 'fixture_card.dart' show BetActionButton;

/// Myanmar odds line selectable in the bet-slip exposure calculator.
///
/// The exposure factor is stored as absolute integer hundredths so the
/// Max-Loss preview never touches floating-point money math:
///   'အရှုံးမရှိ' → loss exposure 1.00 × stake
///   '၁-၅၀'      → loss exposure 1.50 × stake
///
/// Mirror of the hold policy in `pkg/worker/formula.go` (Go) so every layer
/// exposes the same maximum-loss figure.
enum MyanmarBetLine {
  noLoss('အရှုံးမရှိ', 100),
  oneFifty('၁-၅၀', 150);

  const MyanmarBetLine(this.label, this.factorHundredths);

  /// Burmese dropdown label.
  final String label;

  /// Max-loss exposure factor scaled by 100 (100 = 1.00x, 150 = 1.50x).
  final int factorHundredths;

  /// Human-readable factor, e.g. "1.50".
  String get factorText =>
      '${factorHundredths ~/ 100}.${(factorHundredths % 100).toString().padLeft(2, '0')}';
}

/// Payload raised when the calculator confirms a stake.
class MyanmarBetSubmission {
  const MyanmarBetSubmission({required this.stakeCents, required this.line});

  /// Verified stake in cent-units (kyat × 100) — exact integer, no float math.
  final int stakeCents;

  final MyanmarBetLine line;

  /// Whole kyat of the stake (truncated from the cent-units value).
  int get kyat => stakeCents ~/ 100;
}

int? _parseFixedCents(String input) {
  final t = input.trim();
  if (t.isEmpty) return null;
  if (!RegExp(r'^\d{1,12}(\.\d{1,2})?$').hasMatch(t)) return null;
  final parts = t.split('.');
  final kyat = int.parse(parts[0]);
  final frac = parts.length == 2 ? parts[1].padRight(2, '0') : '00';
  return kyat * 100 + int.parse(frac);
}

int? _doubleToCents(double value) {
  if (value.isNaN || value.isInfinite || value < 0) return null;
  return _parseFixedCents(value.toStringAsFixed(2));
}

String _formatCents(int cents) {
  final sign = cents < 0 ? '-' : '';
  final abs = cents.abs();
  final kyat = abs ~/ 100;
  final paise = abs % 100;
  final digits = kyat.toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  final whole = buf.toString();
  if (paise == 0) return '$sign$whole';
  return '$sign$whole.${paise.toString().padLeft(2, '0')}';
}

/// Accepts only a plain decimal with up to two fraction digits.
class _StakeTextFormatter extends TextInputFormatter {
  static final _pattern = RegExp(r'^\d{0,12}(\.\d{0,2})?$');

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return _pattern.hasMatch(newValue.text) ? newValue : oldValue;
  }
}

/// Burmese bet-slip calculator card.
///
/// Live per-keystroke preview of the estimated maximum loss for the selected
/// Myanmar odds line. When the maximum loss exceeds the spendable wallet
/// balance the submit action is disabled and a warning is shown.
class MyanmarBetCalculatorCard extends StatefulWidget {
  const MyanmarBetCalculatorCard({
    super.key,
    required this.availableBalance,
    this.onSubmit,
    this.submitting = false,
  });

  /// Current spendable wallet balance in kyat (API scan boundary value).
  final double availableBalance;

  /// Invoked with an exact fixed-point submission when the user confirms.
  final ValueChanged<MyanmarBetSubmission>? onSubmit;

  /// Disables confirm while a real placement request is in flight.
  final bool submitting;

  @override
  State<MyanmarBetCalculatorCard> createState() =>
      _MyanmarBetCalculatorCardState();
}

class _MyanmarBetCalculatorCardState extends State<MyanmarBetCalculatorCard> {
  final TextEditingController _controller = TextEditingController();
  MyanmarBetLine _line = MyanmarBetLine.noLoss;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? get _stakeCents => _parseFixedCents(_controller.text);

  int? get _maxLossCents {
    final stake = _stakeCents;
    if (stake == null) return null;
    return stake * _line.factorHundredths ~/ 100;
  }

  int? get _balanceCents => _doubleToCents(widget.availableBalance);

  bool get _overBudget {
    final loss = _maxLossCents;
    final balance = _balanceCents;
    if (loss == null || balance == null) return false;
    return loss > balance;
  }

  bool get _canSubmit =>
      !widget.submitting && !_overBudget && (_stakeCents ?? 0) > 0;

  void _confirm() {
    final onSubmit = widget.onSubmit;
    final stake = _stakeCents;
    if (onSubmit == null || stake == null || !_canSubmit) return;
    onSubmit(MyanmarBetSubmission(stakeCents: stake, line: _line));
  }

  @override
  Widget build(BuildContext context) {
    final maxLoss = _maxLossCents;
    final balance = _balanceCents;
    final lossText = maxLoss == null ? '—' : '${_formatCents(maxLoss)} ကျပ်';
    final overBudget = _overBudget;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: overBudget ? AppColors.error : AppColors.edge,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ကြေးတွက်စက်',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: AppColors.amber, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Text('လောင်းကြေး ပမာဏ',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [_StakeTextFormatter()],
            style: const TextStyle(color: AppColors.text, fontSize: 20),
            decoration: InputDecoration(
              hintText: '0.00',
              hintStyle: const TextStyle(color: AppColors.textDim),
              filled: true,
              fillColor: AppColors.background,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.edge),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<MyanmarBetLine>(
            initialValue: _line,
            isExpanded: true,
            dropdownColor: AppColors.background,
            items: [
              for (final line in MyanmarBetLine.values)
                DropdownMenuItem(
                  value: line,
                  child: Text(
                    '${line.label} (×${line.factorText})',
                    style: const TextStyle(color: AppColors.text),
                  ),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _line = value);
            },
            decoration: InputDecoration(
              labelText: 'ကြေး ရွေးချယ်မှု',
              labelStyle: const TextStyle(color: AppColors.textDim),
              filled: true,
              fillColor: AppColors.background,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.edge),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text('အများဆုံး ဆုံးရှုံးမှု',
                    style: Theme.of(context).textTheme.bodyMedium),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _line == MyanmarBetLine.oneFifty
                      ? AppColors.amber.withValues(alpha: 0.18)
                      : AppColors.edge.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '×${_line.factorText}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: _line == MyanmarBetLine.oneFifty
                        ? AppColors.amber
                        : AppColors.textDim,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            lossText,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: overBudget ? AppColors.error : AppColors.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'လက်ကျန်: ${balance == null ? '—' : '${_formatCents(balance)} ကျပ်'}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textDim),
          ),
          if (overBudget) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.error),
              ),
              child: const Text(
                'လောင်းကြေးထပ်ရန် ယူနစ် မလုံလောက်ပါ',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          BetActionButton(
            label: 'လောင်းမည်',
            loading: widget.submitting,
            onPressed: _canSubmit ? _confirm : null,
          ),
        ],
      ),
    );
  }
}