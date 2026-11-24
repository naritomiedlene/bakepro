import 'package:bakepro/nav.dart';
import 'package:bakepro/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class ListasPage extends StatelessWidget {
  const ListasPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    // IMPORTANT: This page is rendered inside AppShell (ShellRoute).
    // So we avoid adding another Scaffold/AppBar here, otherwise we lose
    // the drawer/menu and can break hit-testing on web.
    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: () => context.go(AppRoutes.home),
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Voltar para Home',
              ),
            ),
            Text('Listas', style: theme.textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Selecione uma lista para visualizar informações.',
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.35),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _ListasMenuCard(
                    title: 'Itens',
                    subtitle: 'Tabela completa de itens (por empresa)',
                    icon: Icons.inventory_2_outlined,
                    onTap: () {
                      // Diagnostics: helps confirm which route is being opened.
                      debugPrint('ListasPage: opening route -> ${AppRoutes.listasItens}');
                      context.push(AppRoutes.listasItens);
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _ListasMenuCard(
                    title: 'Precificação de produtos',
                    subtitle: 'Simulação de preço de venda com base nos custos',
                    icon: Icons.sell_outlined,
                    onTap: () => context.push(AppRoutes.listasPrecificacaoProdutos),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Dica: clique no ID ou nome de um item para editar.',
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListasMenuCard extends StatelessWidget {
  const _ListasMenuCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        splashFactory: NoSplash.splashFactory,
        highlightColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
