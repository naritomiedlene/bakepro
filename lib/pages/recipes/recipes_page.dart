import 'package:bakepro/components/recipe_card.dart';
import 'package:bakepro/models/receita.dart';
import 'package:bakepro/nav.dart';
import 'package:bakepro/services/receita_service.dart';
import 'package:bakepro/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class RecipesPage extends StatefulWidget {
  const RecipesPage({super.key});

  @override
  State<RecipesPage> createState() => _RecipesPageState();
}

class _RecipesPageState extends State<RecipesPage> {
  final ReceitaService _receitaService = ReceitaService();
  final TextEditingController _searchController = TextEditingController();

  Future<List<Receita>>? _future;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = _loadWithCosts();
    _searchController.addListener(() {
      final next = _searchController.text.trim().toLowerCase();
      if (next == _query) return;
      setState(() => _query = next);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<Receita>> _loadWithCosts() => _receitaService.listWithComputedCosts(limit: 100);

  Future<void> _refresh() async {
    setState(() => _future = _loadWithCosts());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Receitas', style: context.textStyles.titleLarge),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            onPressed: _refresh,
            icon: Icon(Icons.refresh, color: scheme.onSurface),
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
      body: Padding(
        padding: AppSpacing.horizontalMd,
        child: Column(
          children: [
            const SizedBox(height: AppSpacing.sm),
            _SearchField(controller: _searchController),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: FutureBuilder<List<Receita>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const _LoadingList();
                  }
                  if (snapshot.hasError) {
                    debugPrint('RecipesPage load error: ${snapshot.error}');
                    return _ErrorState(onRetry: _refresh);
                  }

                  final all = snapshot.data ?? const <Receita>[];
                  final filtered = _query.isEmpty
                      ? all
                      : all
                          .where((r) => r.nome.toLowerCase().contains(_query))
                          .toList(growable: false);

                  return RefreshIndicator.adaptive(
                    onRefresh: _refresh,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: filtered.isEmpty
                          ? _EmptyState(query: _query)
                          : ListView.separated(
                              key: ValueKey('list_${filtered.length}_$_query'),
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                              itemBuilder: (context, index) {
                                final receita = filtered[index];
                                return RecipeCard(
                                  receita: receita,
                                  onTap: () => context.push(
                                    AppRoutes.recipeDetails(receita.receitaId),
                                  ),
                                );
                              },
                              separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                              itemCount: filtered.length,
                            ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Em breve: adicionar receita.')),
          );
        },
        backgroundColor: scheme.primary,
        child: Icon(Icons.add, color: scheme.onPrimary),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Buscar receita…',
        prefixIcon: Icon(Icons.search, color: scheme.onSurfaceVariant),
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.2)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.18)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.7), width: 1.2),
        ),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return IconButton(
              tooltip: 'Limpar',
              onPressed: controller.clear,
              icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
            );
          },
        ),
      ),
    );
  }
}

class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      itemBuilder: (_, __) => Container(
        height: 78,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
      itemCount: 8,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = query.isEmpty ? 'Nenhuma receita ainda' : 'Nada encontrado';
    final subtitle = query.isEmpty
        ? 'Quando existir registros na tabela receita, eles aparecem aqui.'
        : 'Tente outro termo de busca.';
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: AppSpacing.xxl),
        Icon(Icons.menu_book, size: 48, color: scheme.onSurfaceVariant),
        const SizedBox(height: AppSpacing.md),
        Text(title, textAlign: TextAlign.center, style: context.textStyles.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        Padding(
          padding: AppSpacing.horizontalLg,
          child: Text(
            subtitle,
            textAlign: TextAlign.center,
            style: context.textStyles.bodyMedium?.withColor(scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
            Text('Falha ao carregar', style: context.textStyles.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Verifique sua conexão e as permissões/RLS das tabelas no Supabase.',
              textAlign: TextAlign.center,
              style: context.textStyles.bodyMedium?.withColor(scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh, color: scheme.onPrimary),
              label: Text('Tentar novamente', style: context.textStyles.labelLarge?.withColor(scheme.onPrimary)),
            ),
          ],
        ),
      ),
    );
  }
}
