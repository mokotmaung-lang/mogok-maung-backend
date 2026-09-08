import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/fixture.dart';

/// Shared visual cards for the betting screens.
class FixtureCard extends StatelessWidget {
  final FixtureTeam fixture;
  final Widget? trailing;
  final bool highlighted;
  final VoidCallback? onTap;

  const FixtureCard({
    super.key,
    required this.fixture,
    this.trailing,
    this.highlighted = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: highlighted
          ? AppColors.panel.withValues(alpha: 0.8)
          : AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: highlighted ? AppColors.amber : AppColors.edge,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      fixture.leagueName,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: AppColors.amber,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    fixture.isEnabled ? 'OPEN' : 'CLOSED',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: fixture.isEnabled ? Colors.green : AppColors.error,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${fixture.homeTeam}  vs  ${fixture.awayTeam}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.text,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'ကြေး: ${fixture.handicap}   အိမ် ${fixture.homeBodyPayout.toStringAsFixed(2)} / အဝေး ${fixture.awayBodyPayout.toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textDim,
                    ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'မှတ်တမ်း: ${_fmt(fixture.matchTime)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.textDim,
                        ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $h:$m';
  }
}

/// Formats a hold/hold-balance amount.
String formatUnits(double units) => units.toStringAsFixed(0);

/// Gold accent button used across betting actions.
class BetActionButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool loading;
  final String label;

  const BetActionButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.amber,
          foregroundColor: const Color(0xFF1A1206),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: loading ? null : onPressed,
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }
}