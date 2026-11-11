import 'package:flutter/material.dart';

import '../theme/exa_theme.dart';
import 'exa_orb.dart';

/// Consistent, warm empty state used across the feature tabs. Either a
/// soft accent icon medallion or the Exa orb, a title, a calm message,
/// and an optional call to action.
class ExaEmptyState extends StatelessWidget {
  const ExaEmptyState({
    super.key,
    this.icon,
    this.useOrb = false,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData? icon;
  final bool useOrb;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (useOrb)
              const ExaOrb(size: 64)
            else
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: ExaColors.accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: ExaColors.accent.withValues(alpha: 0.30)),
                ),
                child: Icon(icon ?? Icons.auto_awesome,
                    size: 34, color: ExaColors.spark),
              ),
            const SizedBox(height: 22),
            Text(title,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: ExaColors.textSecondary, height: 1.4),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
