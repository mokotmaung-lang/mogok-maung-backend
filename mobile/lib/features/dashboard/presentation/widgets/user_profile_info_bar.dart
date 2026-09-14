import 'package:flutter/material.dart';

/// Card showing the logged-in user's identity and live balance.
///
/// The left identity block and the right balance block are both wrapped in
/// [Expanded]/[Flexible]/[FittedBox] so a long username or a large balance
/// never pushes the row past the screen width (horizontal RenderFlex
/// overflow) on narrow devices or with system text scaling.
class UserProfileInfoBar extends StatelessWidget {
  final String username;
  final String balance;

  const UserProfileInfoBar({
    super.key,
    required this.username,
    required this.balance,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.blueAccent.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Colors.blueAccent,
                  child: Icon(Icons.person, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const Text(
                        'Active Status',
                        style: TextStyle(color: Colors.greenAccent, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'လက်ကျန် Unit',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    balance,
                    style: const TextStyle(
                      color: Colors.amberAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}