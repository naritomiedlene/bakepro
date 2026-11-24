import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:bakepro/theme.dart';

/// Bottom sheet padrão para confirmar exclusão.
///
/// Regras de UX:
/// - Exibe um identificador do registro (nome/código) quando disponível.
/// - Botão **Cancelar** é o default (visual e foco), para reduzir exclusões acidentais.
class ConfirmDeleteSheet extends StatelessWidget {
  const ConfirmDeleteSheet({
    super.key,
    required this.title,
    required this.message,
    this.recordIdentifier,
    this.confirmLabel = 'Excluir',
    this.confirmColor,
    this.cancelLabel = 'Cancelar',
    this.maxHeightFactor = 0.92,
  });

  final String title;
  final String message;

  /// Identificador humano do registro (ex.: nome, código, etc.).
  /// Se for nulo/vazio, não será exibido.
  final String? recordIdentifier;

  final String confirmLabel;
  final Color? confirmColor;
  final String cancelLabel;

  /// Limite máximo de altura do sheet em relação ao espaço disponível.
  ///
  /// Use valores mais altos (ex.: 0.95) quando quiser reduzir a necessidade de rolagem.
  final double maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final destructive = confirmColor ?? cs.error;
    final identifier = (recordIdentifier ?? '').trim();

    // Evita overflow em telas baixas (web/desktop com zoom) e garante que os botões
    // fiquem acessíveis mesmo quando o conteúdo for maior.
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.md,
          right: AppSpacing.md,
          top: AppSpacing.md,
          bottom: AppSpacing.md + MediaQuery.paddingOf(context).bottom,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxHeight = constraints.maxHeight.isFinite ? constraints.maxHeight : MediaQuery.sizeOf(context).height;
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight * maxHeightFactor),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                  border: Border.all(color: cs.outline.withValues(alpha: 0.16)),
                ),
                child: Padding(
                  padding: AppSpacing.paddingLg,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: Theme.of(context).textTheme.titleLarge),
                              if (identifier.isNotEmpty) ...[
                                const SizedBox(height: AppSpacing.xs),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
                                    borderRadius: BorderRadius.circular(AppRadius.lg),
                                    border: Border.all(color: cs.outline.withValues(alpha: 0.12)),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                                    child: Row(
                                      children: [
                                        Icon(Icons.label_rounded, size: 18, color: cs.onSurfaceVariant),
                                        const SizedBox(width: AppSpacing.sm),
                                        Expanded(
                                          child: Text(
                                            identifier,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurface),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: AppSpacing.sm),
                              Text(
                                message,
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.4),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              autofocus: true,
                              onPressed: () => context.pop(false),
                              child: Text(cancelLabel, style: TextStyle(color: cs.onPrimary)),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => context.pop(true),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: destructive,
                                side: BorderSide(color: destructive.withValues(alpha: 0.65)),
                              ),
                              child: Text(confirmLabel, style: TextStyle(color: destructive)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
