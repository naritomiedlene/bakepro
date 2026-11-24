import 'package:bakepro/theme.dart';
import 'package:flutter/material.dart';

/// Right-aligned, stacked list actions (Refresh + Create) with equal sizing.
///
/// By default it places actions **side-by-side** to avoid wasting vertical
/// space. On narrow layouts it gracefully falls back to a vertical stack.
class StackedListActions extends StatelessWidget {
  const StackedListActions({
    super.key,
    required this.isLoading,
    required this.onRefresh,
    this.onCreate,
    this.refreshLabel = 'Atualizar',
    this.createLabel = 'Novo',
  });

  final bool isLoading;
  final VoidCallback onRefresh;
  /// When null, the Create button is hidden.
  final VoidCallback? onCreate;
  final String refreshLabel;
  final String createLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final refreshButton = OutlinedButton.icon(
      onPressed: isLoading ? null : onRefresh,
      icon: Icon(Icons.refresh_rounded, color: cs.primary),
      label: Text(refreshLabel, style: TextStyle(color: cs.primary)),
    );
    final createCallback = onCreate;
    final createButton = createCallback == null
        ? null
        : FilledButton.icon(
            onPressed: isLoading ? null : createCallback,
            icon: Icon(Icons.add_rounded, color: cs.onPrimary),
            label: Text(createLabel, style: TextStyle(color: cs.onPrimary)),
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        // If there isn't enough room to keep both actions on the same row,
        // fall back to the previous vertical stacking.
        final useVertical = constraints.maxWidth < 280;

        if (useVertical) {
          return IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                refreshButton,
                if (createButton != null) ...[const SizedBox(height: AppSpacing.xs), createButton],
              ],
            ),
          );
        }

        return Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            ConstrainedBox(constraints: const BoxConstraints(minWidth: 140), child: refreshButton),
            if (createButton != null) ConstrainedBox(constraints: const BoxConstraints(minWidth: 140), child: createButton),
          ],
        );
      },
    );
  }
}
