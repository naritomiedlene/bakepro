import 'package:bakepro/models/ingrediente.dart';
import 'package:bakepro/models/receita.dart';
import 'package:bakepro/services/ingrediente_service.dart';
import 'package:bakepro/services/receita_service.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:bakepro/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class RecipeDetailPage extends StatefulWidget {
  const RecipeDetailPage({super.key, required this.receitaId});
  final int receitaId;

  @override
  State<RecipeDetailPage> createState() => _RecipeDetailPageState();
}

class _RecipeDetailPageState extends State<RecipeDetailPage> {
  final ReceitaService _receitaService = ReceitaService();
  final IngredienteService _ingredienteService = IngredienteService();

  Future<_RecipeDetailData>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_RecipeDetailData> _load() async {
    final receita = await _receitaService.getById(widget.receitaId);
    final ingredientes = await _ingredienteService.listForReceita(widget.receitaId);

    // Keep detail UI resilient even when DB totals are missing (legacy rows / no trigger).
    final computedIng = _computeTotalIngredientes(ingredientes);
    final enrichedReceita = receita?.copyWith(
      custoTotalIngredientes: receita.custoTotalIngredientes ?? computedIng,
      custoReceita: receita.custoReceita ?? ((receita.custoTotalMateriais ?? 0) + computedIng),
    );

    return _RecipeDetailData(receita: enrichedReceita, ingredientes: ingredientes);
  }

  num _computeTotalIngredientes(List<Ingrediente> ingredientes) {
    num total = 0;
    for (final ing in ingredientes) {
      final qty = ing.quantidadeGrama;
      final custoUnit = ing.item?.custoUnitario;
      final custo = ing.custoIngrediente ?? (custoUnit == null ? null : custoUnit * qty);
      total += custo ?? 0;
    }
    return total;
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Detalhes', style: context.textStyles.titleLarge),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            onPressed: _refresh,
            icon: Icon(Icons.refresh, color: scheme.onSurface),
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
      body: FutureBuilder<_RecipeDetailData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator.adaptive());
          }
          if (snapshot.hasError) {
            debugPrint('RecipeDetail load error: ${snapshot.error}');
            return _DetailError(onRetry: _refresh);
          }

          final data = snapshot.data;
          final receita = data?.receita;
          if (receita == null) {
            return const Center(child: Text('Receita não encontrada.'));
          }

          return RefreshIndicator.adaptive(
            onRefresh: _refresh,
            child: ListView(
              padding: AppSpacing.paddingLg,
              children: [
                _HeaderCard(receita: receita),
                const SizedBox(height: AppSpacing.lg),
                Text('Ingredientes', style: context.textStyles.titleMedium?.semiBold),
                const SizedBox(height: AppSpacing.sm),
                ..._buildIngredientCards(context, data?.ingredientes ?? const <Ingrediente>[]),
                const SizedBox(height: AppSpacing.xxl),
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
          child: FilledButton.icon(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Em breve: gerar lista de compras.')),
              );
            },
            icon: Icon(Icons.shopping_cart, color: scheme.onPrimary),
            label: Text('Gerar lista de compras', style: context.textStyles.labelLarge?.withColor(scheme.onPrimary)),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildIngredientCards(BuildContext context, List<Ingrediente> ingredientes) {
    if (ingredientes.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.md),
          child: Text(
            'Nenhum ingrediente cadastrado para esta receita.',
            style: context.textStyles.bodyMedium?.withColor(Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      ];
    }
    return ingredientes
        .map((ing) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _IngredientCard(ingrediente: ing),
            ))
        .toList(growable: false);
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.receita});
  final Receita receita;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unidade = receita.unidadeLabel ?? 'un.';
    final rendimento = '${receita.qtdReceita} $unidade';
    final custoIng = receita.custoTotalIngredientes;
    final custoMat = receita.custoTotalMateriais;
    final custoTotal = receita.custoReceita ?? ((custoIng ?? 0) + (custoMat ?? 0));
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        gradient: LinearGradient(
          colors: [
            scheme.primaryContainer,
            scheme.primaryContainer.withValues(alpha: 0.55),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.12)),
      ),
      padding: AppSpacing.paddingLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(receita.nome, style: context.textStyles.headlineSmall?.semiBold?.withColor(scheme.onPrimaryContainer)),
          const SizedBox(height: AppSpacing.sm),
          if (receita.descricao?.trim().isNotEmpty == true)
            Text(
              receita.descricao!.trim(),
              style: context.textStyles.bodyMedium?.withColor(scheme.onPrimaryContainer.withValues(alpha: 0.85)),
            )
          else
            Text(
              'Rendimento: $rendimento',
              style: context.textStyles.bodyMedium?.withColor(scheme.onPrimaryContainer.withValues(alpha: 0.85)),
            ),
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _Pill(icon: Icons.straighten, label: rendimento),
              _Pill(icon: Icons.attach_money, label: 'Custo total: ${formatPtBrMoney(custoTotal)}'),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _RecipeCostsCard(custoIngredientes: custoIng, custoMateriais: custoMat, custoTotal: custoTotal),
        ],
      ),
    );
  }
}

class _RecipeCostsCard extends StatelessWidget {
  const _RecipeCostsCard({required this.custoIngredientes, required this.custoMateriais, required this.custoTotal});
  final num? custoIngredientes;
  final num? custoMateriais;
  final num custoTotal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.14)),
      ),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CostInlinePill(icon: Icons.spa, label: 'Ing', value: custoIngredientes == null ? '—' : formatPtBrMoney(custoIngredientes!)),
              const SizedBox(width: AppSpacing.sm),
              _CostInlinePill(icon: Icons.all_inbox_rounded, label: 'Mat', value: custoMateriais == null ? '—' : formatPtBrMoney(custoMateriais!)),
              const SizedBox(width: AppSpacing.sm),
              _CostInlinePill(icon: Icons.summarize, label: 'Total', value: formatPtBrMoney(custoTotal), emphasize: true),
            ],
          ),
        ),
      ),
    );
  }
}

class _CostInlinePill extends StatelessWidget {
  const _CostInlinePill({required this.icon, required this.label, required this.value, this.emphasize = false});
  final IconData icon;
  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = emphasize ? scheme.primary.withValues(alpha: 0.10) : scheme.surfaceContainerHighest.withValues(alpha: 0.55);
    final fg = emphasize ? scheme.primary : scheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: AppSpacing.sm),
          Text(
            '$label:',
            style: context.textStyles.labelLarge?.semiBold?.withColor(scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 6),
          Text(value, style: context.textStyles.labelLarge?.semiBold?.withColor(scheme.onSurface)),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: scheme.onSurface),
          const SizedBox(width: AppSpacing.sm),
          Text(label, style: context.textStyles.labelLarge?.withColor(scheme.onSurface)),
        ],
      ),
    );
  }
}

class _IngredientCard extends StatelessWidget {
  const _IngredientCard({required this.ingrediente});
  final Ingrediente ingrediente;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = ingrediente.item?.nome ?? 'Item #${ingrediente.itemId}';
    final qty = ingrediente.quantidadeGrama;
    final qtyText = '${qty.toDouble().toStringAsFixed(0)} g';
    final custoUnitario = ingrediente.item?.custoUnitario;
    final custoUnitarioText = custoUnitario == null ? '—' : formatPtBrMoney(custoUnitario, decimalDigits: 4);

    // Prefer the stored cost (ingrediente.custoingrediente). If it's missing,
    // compute it using item.custounitario * ingrediente.quantidadegrama.
    // This matches the business rule you asked to populate in the backend.
    final custo = ingrediente.custoIngrediente ?? (custoUnitario == null ? null : custoUnitario * qty);
    final custoText = custo == null ? '—' : formatPtBrMoney(custo);

    return Card(
      child: Padding(
        padding: AppSpacing.paddingMd,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(Icons.spa, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.textStyles.titleSmall?.semiBold),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Quantidade: $qtyText  •  Custo unitário - R\$: $custoUnitarioText',
                    style: context.textStyles.bodySmall?.withColor(scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Custo do ingrediente na receita - R\$: $custoText',
                    style: context.textStyles.bodySmall?.withColor(scheme.onSurfaceVariant),
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

class _DetailError extends StatelessWidget {
  const _DetailError({required this.onRetry});
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
            Icon(Icons.error_outline, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
            Text('Erro ao carregar', style: context.textStyles.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Se você usa RLS, confira se a policy permite select na receita/ingrediente/item.',
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

class _RecipeDetailData {
  const _RecipeDetailData({required this.receita, required this.ingredientes});
  final Receita? receita;
  final List<Ingrediente> ingredientes;
}
