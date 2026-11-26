import 'package:bakepro/theme.dart';
import 'package:flutter/material.dart';

/// Card padrão para contadores de lista ("22 itens", "5 itens filtrados") e
/// indicadores de posição ("1/5", "1–10 de 22").
///
/// Fundo abóbora (terracota da marca, [AppBrandColors.terracotta]) com texto
/// branco em fonte leve. Use sempre este widget em vez de Text solto.
class CountBadge extends StatelessWidget {
  const CountBadge(this.text, {super.key, this.dense = false});

  final String text;

  /// Versão menor (ex.: dentro do cabeçalho de um card).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppBrandColors.terracotta,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 4 : 6),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: (dense ? t.labelSmall : t.labelMedium)?.copyWith(
            color: AppBrandColors.onTerracotta,
            fontWeight: FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
