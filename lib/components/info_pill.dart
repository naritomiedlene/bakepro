import 'package:bakepro/theme.dart';
import 'package:flutter/material.dart';

/// Card compacto "Rótulo: valor" (com ícone opcional) usado nas listas e telas
/// de edição para exibir dados em vez de texto corrido.
class InfoPill extends StatelessWidget {
  const InfoPill({
    super.key,
    this.icon,
    required this.label,
    required this.value,
    this.emphasize = false,
    this.backgroundColor,
    this.foregroundColor,
    this.calculated = false,
  });

  final IconData? icon;
  final String label;
  final String value;
  final bool emphasize;

  /// Valor calculado pelo app (custos, totais, preço calculado...): card verde
  /// padrão ([AppStatusColors.calculatedValueBackground]) com texto branco.
  final bool calculated;

  /// Cores opcionais (ex.: categoria/classificação em azul-ardósia). Sobrepõem o padrão.
  final Color? backgroundColor;
  final Color? foregroundColor;

  /// Azul-ardósia padrão dos cards de Categoria/Classificação.
  static Color get categoria => AppStatusColors.categoriaBackground;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (calculated) {
      return InfoPill(
        icon: icon,
        label: label,
        value: value,
        backgroundColor: AppStatusColors.calculatedValueBackground,
        foregroundColor: AppStatusColors.onCalculatedValue,
      );
    }
    final bg = backgroundColor ??
        (emphasize ? colorScheme.primary.withValues(alpha: 0.10) : colorScheme.surfaceContainerHighest.withValues(alpha: 0.55));
    final fg = foregroundColor ?? (emphasize ? colorScheme.primary : colorScheme.onSurfaceVariant);
    final labelColor = foregroundColor ?? colorScheme.onSurfaceVariant;
    final valueColor = foregroundColor ?? colorScheme.onSurface;
    // Padronização: todos os cards (marrons e verdes) com fonte de peso normal.
    // Antes w700 (rótulo) / w800 (valor), que ficavam carregados demais.
    const labelWeight = FontWeight.normal;
    const valueWeight = FontWeight.normal;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 8),
            ],
            Text(
              '$label: ',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: labelColor, fontWeight: labelWeight),
            ),
            // Sem Flexible: os cards também são usados dentro de FittedBox (largura ilimitada).
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: valueColor, fontWeight: valueWeight),
            ),
          ],
        ),
      ),
    );
  }
}
