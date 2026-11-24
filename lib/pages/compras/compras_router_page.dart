import 'package:bakepro/pages/cadastros/cadastro_definitions.dart';
import 'package:bakepro/pages/cadastros/generic_cadastro_list_page.dart';
import 'package:bakepro/pages/compras/compra/compra_list_page.dart';
import 'package:bakepro/theme.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class ComprasRouterPage extends StatelessWidget {
  const ComprasRouterPage({super.key, this.entity});

  final String? entity;

  @override
  Widget build(BuildContext context) {
    final resolved = (entity ?? '').trim();
    if (resolved.isEmpty) return const _ComprasIndex();

    if (resolved == 'fornecedor') {
      final def = Cadastros.byKey('fornecedor');
      if (def == null) return const _UnknownCompras(entity: 'fornecedor');

      return GenericCadastroListPage(
        definition: def,
        backLocation: '/compras',
        createForcedValues: const {'status': 'A'},
        createHiddenColumns: const {'status'},
        createReadOnlyColumns: const {'status'},
      );
    }

    if (resolved == 'compra') {
      return const CompraListPage();
    }

    return _UnknownCompras(entity: resolved);
  }
}

class _ComprasIndex extends StatelessWidget {
  const _ComprasIndex();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: () => context.go('/'),
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Voltar para Home',
              ),
            ),
            Text('Compras', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Cadastros e rotinas de compras.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.35),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: 2,
                separatorBuilder: (context, index) => const SizedBox(height: AppSpacing.sm),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _ComprasCard(icon: Icons.local_shipping_rounded, title: 'Fornecedor', onTap: () => context.go('/compras/fornecedor'));
                  }
                  return _ComprasCard(icon: Icons.shopping_basket_rounded, title: 'Compra', onTap: () => context.go('/compras/compra'));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComprasCard extends StatelessWidget {
  const _ComprasCard({required this.icon, required this.title, required this.onTap});

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.md * 1.2, vertical: AppSpacing.xs * 2.4),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
                ),
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.xs * 2.4),
                  child: Icon(icon, color: cs.primary, size: 28),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnknownCompras extends StatelessWidget {
  const _UnknownCompras({required this.entity});
  final String entity;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: cs.outline.withValues(alpha: 0.18)),
          ),
          child: Padding(
            padding: AppSpacing.paddingLg,
            child: Text('Área desconhecida: $entity', style: Theme.of(context).textTheme.bodyLarge),
          ),
        ),
      ),
    );
  }
}
