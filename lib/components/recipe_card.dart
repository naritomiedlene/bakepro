import 'package:bakepro/models/receita.dart';
import 'package:bakepro/theme.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:flutter/material.dart';

/// A modern, minimal card for a recipe row.
class RecipeCard extends StatelessWidget {
  const RecipeCard({
    super.key,
    required this.receita,
    required this.onTap,
  });

  final Receita receita;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unidade = receita.unidadeLabel ?? 'un.';
    final rendimento = '${receita.qtdReceita} $unidade';

    final ing = receita.custoTotalIngredientes;
    final mat = receita.custoTotalMateriais;
    final total = receita.custoReceita;

    final hasCosts = ing != null || mat != null || total != null;

    return Card(
      child: InkWell(
        // No splash.
        splashFactory: NoSplash.splashFactory,
        highlightColor: scheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Padding(
          padding: AppSpacing.paddingMd,
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  gradient: LinearGradient(
                    colors: [
                      scheme.primaryContainer,
                      scheme.primaryContainer.withValues(alpha: 0.6),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Icon(Icons.restaurant_menu, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            receita.nome,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.textStyles.titleMedium?.semiBold,
                          ),
                          if (receita.descricao?.trim().isNotEmpty == true) ...[
                            const SizedBox(height: 2),
                            Text(
                              receita.descricao!.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.textStyles.bodySmall?.withColor(scheme.onSurfaceVariant),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _RecipeInlineMetrics(
                      rendimento: rendimento,
                      showCosts: hasCosts,
                      ing: ing,
                      mat: mat,
                      total: total,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecipeInlineMetrics extends StatelessWidget {
  const _RecipeInlineMetrics({
    required this.rendimento,
    required this.showCosts,
    required this.ing,
    required this.mat,
    required this.total,
  });

  final String rendimento;
  final bool showCosts;
  final num? ing;
  final num? mat;
  final num? total;

  String _fmt(num? value) => value == null ? '—' : formatPtBrCurrency(value, decimalDigits: 2);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final pills = <Widget>[];
    if (!showCosts) {
      pills.add(
        _InlinePill(
          icon: Icons.scale,
          text: rendimento,
          background: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          foreground: scheme.onSurfaceVariant,
        ),
      );
    } else {
      pills.addAll([
        _InlinePill(
          icon: Icons.shopping_basket_outlined,
          text: 'Ing ${_fmt(ing)}',
          background: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          foreground: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppSpacing.xs),
        _InlinePill(
          icon: Icons.inventory_2_outlined,
          text: 'Mat ${_fmt(mat)}',
          background: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          foreground: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppSpacing.xs),
        _InlinePill(
          icon: Icons.calculate_outlined,
          text: 'Tot ${_fmt(total)}',
          background: scheme.primary.withValues(alpha: 0.12),
          foreground: scheme.primary,
          emphasize: true,
        ),
      ]);
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Row(mainAxisSize: MainAxisSize.min, children: pills),
      ),
    );
  }
}

class _InlinePill extends StatelessWidget {
  const _InlinePill({
    required this.icon,
    required this.text,
    required this.background,
    required this.foreground,
    this.emphasize = false,
  });

  final IconData icon;
  final String text;
  final Color background;
  final Color foreground;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final style = emphasize ? context.textStyles.labelMedium?.semiBold : context.textStyles.labelMedium;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 6),
          Text(text, style: style?.withColor(foreground)),
        ],
      ),
    );
  }
}
