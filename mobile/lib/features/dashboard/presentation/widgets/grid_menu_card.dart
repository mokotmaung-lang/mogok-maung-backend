import 'package:flutter/material.dart';

/// Reusable tappable card used by the 8-grid navigation dashboard.
///
/// Grid cells share a fixed childAspectRatio, so the inner content must not
/// assume a minimum size. `FittedBox(scaleDown)` shrinks title/icon together
/// when a given device aspect ratio produces a very short cell (or when a
/// Burmese label wraps to two lines), preventing RenderFlex overflows of any
/// magnitude — the tooltip labels stay readable in the default size.
class GridMenuCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const GridMenuCard({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.05),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 26, color: color),
                const SizedBox(height: 4),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
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