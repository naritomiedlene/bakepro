import 'package:bakepro/pages/cadastros/cadastro_definitions.dart';
import 'package:bakepro/pages/cadastros/generic_cadastro_form_sheet.dart';
import 'package:bakepro/components/confirm_delete_sheet.dart';
import 'package:bakepro/components/info_pill.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/theme.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Editor em cascata do Produto:
/// Produto -> ProdutoReceita -> Receita -> (Ingredientes + Materiais)
class ProdutoCascadePage extends StatefulWidget {
  const ProdutoCascadePage({super.key, required this.produtoId});

  final int? produtoId;

  @override
  State<ProdutoCascadePage> createState() => _ProdutoCascadePageState();
}

class _ProdutoCascadePageState extends State<ProdutoCascadePage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _produto;
  List<Map<String, dynamic>> _produtoReceitas = const [];

  double _calcCustoProducao(List<Map<String, dynamic>> prs) {
    var total = 0.0;
    for (final pr in prs) {
      final receita = pr['receita'] as Map?;
      final qtdUsada = parsePtBrNumber(pr['quantidadereceita']) ?? 0.0;
      final custoReceita = parsePtBrNumber(receita?['custoreceita']) ?? 0.0;
      final qtdReceitaTotal = parsePtBrNumber(receita?['qtdreceita']);
      if (qtdUsada <= 0) continue;
      if (qtdReceitaTotal == null || qtdReceitaTotal <= 0) continue;
      total += (custoReceita / qtdReceitaTotal) * qtdUsada;
    }
    return total;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final produtoId = widget.produtoId;
    if (produtoId == null) {
      setState(() {
        _loading = false;
        _error = 'Produto inválido (sem id).';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final produto = await SupabaseService.selectSingle(
        'produto',
        select: '*, categoria:categoriaid(nome)',
        filters: {'produtoid': produtoId},
      );
      final prs = await SupabaseService.select(
        'produtoreceita',
        select: 'produtoreceitaid,produtoid,receitaid,quantidadereceita, receita:receitaid(nome, custoreceita, qtdreceita, unidade:unidadeid(unidade))',
        filters: {'produtoid': produtoId},
        orderBy: 'produtoreceitaid',
        ascending: true,
        limit: 500,
      );

      prs.sort((a, b) {
        final ar = a['receita'];
        final br = b['receita'];
        final an = (ar is Map ? (ar['nome']?.toString() ?? '') : '').toLowerCase();
        final bn = (br is Map ? (br['nome']?.toString() ?? '') : '').toLowerCase();
        return an.compareTo(bn);
      });

      if (!mounted) return;
      setState(() {
        _produto = produto;
        _produtoReceitas = prs;
      });
    } catch (e) {
      debugPrint('Load Produto cascade failed: $e');
      if (!mounted) return;
      setState(() => _error = 'Não foi possível carregar o produto.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editProduto() async {
    final def = Cadastros.byKey('produto');
    final row = _produto;
    if (def == null || row == null) return;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(definition: def, initialRow: row),
    );
    if (ok == true) await _load();
  }

  Future<void> _addProdutoReceita() async {
    final def = Cadastros.byKey('produtoreceita');
    final produtoId = widget.produtoId;
    if (def == null || produtoId == null) return;

    final ok = await showModalBottomSheet<dynamic>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(
        definition: def,
        forcedValues: {'produtoid': produtoId},
        hiddenColumns: const {'produtoid'},
        readOnlyColumns: const {'produtoid'},
      ),
    );
    if (ok != null) await _load();
  }

  Future<void> _editProdutoReceita(Map<String, dynamic> prRow) async {
    final def = Cadastros.byKey('produtoreceita');
    final produtoId = widget.produtoId;
    if (def == null || produtoId == null) return;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(
        definition: def,
        initialRow: prRow,
        forcedValues: {'produtoid': produtoId},
        hiddenColumns: const {'produtoid'},
        readOnlyColumns: const {'produtoid'},
      ),
    );
    if (ok == true) await _load();
  }

  Future<void> _deleteProdutoReceita(Map<String, dynamic> prRow) async {
    final cs = Theme.of(context).colorScheme;
    final id = prRow['produtoreceitaid'];
    if (id is! num) return;

    final receita = prRow['receita'] as Map?;
    final receitaName = (receita?['nome'] ?? prRow['receitaid'] ?? 'Receita').toString();

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ConfirmDeleteSheet(
        title: 'Excluir receita do produto?',
        recordIdentifier: receitaName,
        message: 'Você está prestes a remover esta receita deste produto.\n\nEsta ação não poderá ser desfeita.',
        confirmLabel: 'Excluir',
        confirmColor: cs.error,
      ),
    );
    if (ok != true) return;

    try {
      await SupabaseService.delete('produtoreceita', filters: {'produtoreceitaid': id});
      if (!mounted) return;
      await _load();
    } catch (e) {
      debugPrint('Delete produtoreceita failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível excluir.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final produtoNome = (_produto?['nome'] ?? 'Produto').toString();
    final custoProducao = _calcCustoProducao(_produtoReceitas);

    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => context.pop(),
                  icon: Icon(Icons.arrow_back_rounded, color: cs.onSurface),
                  tooltip: 'Voltar',
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(produtoNome, style: Theme.of(context).textTheme.headlineSmall)),
                const SizedBox(width: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _load,
                  icon: Icon(Icons.refresh_rounded, color: cs.primary),
                  label: Text('Atualizar', style: TextStyle(color: cs.primary)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            const SizedBox(height: AppSpacing.lg),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? _ErrorPanel(message: _error!, onRetry: _load)
                  : ListView(
                      children: [
                        _ProdutoHeaderCard(
                          produto: _produto ?? const {},
                           custoProducao: custoProducao,
                          onEdit: _editProduto,
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        _SectionHeader(
                          title: 'Produto Receitas',
                          subtitle: 'Componentes e sub-receitas do produto',
                          primaryActionLabel: 'Adicionar',
                          primaryActionIcon: Icons.add_rounded,
                          onPrimaryAction: _addProdutoReceita,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        if (_produtoReceitas.isEmpty)
                          _EmptyInlineCard(message: 'Nenhum Produto Receita cadastrado para este produto.')
                        else
                          ..._produtoReceitas.map((pr) => Padding(
                                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                                child: ProdutoReceitaCard(
                                  prRow: pr,
                                   onEdit: () => _editProdutoReceita(pr),
                                  onDelete: () => _deleteProdutoReceita(pr),
                                ),
                              )),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class ProdutoReceitaCard extends StatefulWidget {
  const ProdutoReceitaCard({super.key, required this.prRow, required this.onDelete, this.onEdit});

  final Map<String, dynamic> prRow;
  final VoidCallback? onEdit;
  final VoidCallback onDelete;

  @override
  State<ProdutoReceitaCard> createState() => _ProdutoReceitaCardState();
}

class _ProdutoReceitaCardState extends State<ProdutoReceitaCard> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final receita = widget.prRow['receita'] as Map?;
    final receitaName = (receita?['nome'] ?? widget.prRow['receitaid'] ?? 'Receita').toString();

    final unidade = (receita?['unidade'] as Map?)?['unidade']?.toString();

    final custoReceita = parsePtBrNumber(receita?['custoreceita']);
    final qtdTotalReceita = parsePtBrNumber(receita?['qtdreceita']);

    final qtd = parsePtBrNumber(widget.prRow['quantidadereceita']);
    final qtdText = qtd == null ? (widget.prRow['quantidadereceita']?.toString() ?? '-') : formatPtBrMoney(qtd, decimalDigits: 4);

    final unidadeText = (unidade == null || unidade.trim().isEmpty) ? null : unidade.trim();
    String comUnidade(String v) => unidadeText == null ? v : '$v ($unidadeText)';

    // Custo total da receita no produto (rateio pela quantidade total da receita)
    // Fórmula: produtoreceita.quantidadereceita * receita.custoreceita / receita.qtdreceita
    final custoNoProduto = (qtd != null && custoReceita != null && qtdTotalReceita != null && qtdTotalReceita != 0)
        ? (qtd * custoReceita) / qtdTotalReceita
        : null;
    final qtdTotalText = qtdTotalReceita == null
        ? null
        : (qtdTotalReceita % 1 == 0 ? qtdTotalReceita.toStringAsFixed(0) : formatPtBrMoney(qtdTotalReceita, decimalDigits: 4));

    final pills = <Widget>[
      InfoPill(icon: Icons.scale_rounded, label: 'Qtd no produto', value: comUnidade(qtdText)),
      if (custoReceita != null)
        InfoPill(icon: Icons.receipt_long_rounded, label: 'Custo total da receita', value: formatPtBrCurrency(custoReceita)),
      if (qtdTotalText != null) InfoPill(icon: Icons.inventory_rounded, label: 'Qtd total da receita', value: comUnidade(qtdTotalText)),
      if (custoNoProduto != null)
        InfoPill(
          icon: Icons.request_quote_rounded,
          label: 'Custo no produto',
          value: formatPtBrCurrency(custoNoProduto),
          emphasize: true,
        ),
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: cs.outline.withValues(alpha: 0.16)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        child: Padding(
          padding: AppSpacing.paddingLg,
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
                ),
                child: Padding(
                  padding: AppSpacing.paddingMd,
                  child: Icon(Icons.receipt_long_rounded, color: cs.primary),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(receitaName, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Wrap(spacing: AppSpacing.sm, runSpacing: 6, children: pills),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton(
                tooltip: 'Editar',
                onPressed: widget.onEdit,
                icon: Icon(Icons.edit_rounded, color: cs.primary),
              ),
              IconButton(
                tooltip: 'Excluir',
                onPressed: widget.onDelete,
                icon: Icon(Icons.delete_outline_rounded, color: cs.error),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ReceitaCascadePanel extends StatefulWidget {
  const ReceitaCascadePanel({super.key, required this.receitaId});

  final int receitaId;

  @override
  State<ReceitaCascadePanel> createState() => _ReceitaCascadePanelState();
}

class _ReceitaCascadePanelState extends State<ReceitaCascadePanel> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _ingredientes = const [];
  List<Map<String, dynamic>> _materiais = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final ing = await SupabaseService.select(
        'ingrediente',
        select: 'ingredienteid,receitaid,itemid,quantidadegrama,custoingrediente, item:itemid(nome)',
        filters: {'receitaid': widget.receitaId},
        orderBy: 'ingredienteid',
        ascending: true,
        limit: 500,
      );
      final mat = await SupabaseService.select(
        'material',
        select: 'materialid,receitaid,itemid,quantidade, item:itemid(nome)',
        filters: {'receitaid': widget.receitaId},
        orderBy: 'materialid',
        ascending: true,
        limit: 500,
      );

      ing.sort((a, b) {
        final ai = a['item'];
        final bi = b['item'];
        final an = (ai is Map ? (ai['nome']?.toString() ?? '') : '').toLowerCase();
        final bn = (bi is Map ? (bi['nome']?.toString() ?? '') : '').toLowerCase();
        return an.compareTo(bn);
      });
      mat.sort((a, b) {
        final ai = a['item'];
        final bi = b['item'];
        final an = (ai is Map ? (ai['nome']?.toString() ?? '') : '').toLowerCase();
        final bn = (bi is Map ? (bi['nome']?.toString() ?? '') : '').toLowerCase();
        return an.compareTo(bn);
      });

      if (!mounted) return;
      setState(() {
        _ingredientes = ing;
        _materiais = mat;
      });
    } catch (e) {
      debugPrint('Load receita cascade failed (receitaid=${widget.receitaId}): $e');
      if (!mounted) return;
      setState(() => _error = 'Não foi possível carregar ingredientes/materiais.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addIngrediente() async {
    final def = Cadastros.byKey('ingrediente');
    if (def == null) return;
    final res = await showModalBottomSheet<dynamic>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(
        definition: def,
        forcedValues: {'receitaid': widget.receitaId},
        hiddenColumns: const {'receitaid'},
        readOnlyColumns: const {'receitaid'},
      ),
    );
    if (res != null) await _load();
  }

  Future<void> _editIngrediente(Map<String, dynamic> row) async {
    final def = Cadastros.byKey('ingrediente');
    if (def == null) return;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(
        definition: def,
        initialRow: row,
        forcedValues: {'receitaid': widget.receitaId},
        hiddenColumns: const {'receitaid'},
        readOnlyColumns: const {'receitaid'},
      ),
    );
    if (ok == true) await _load();
  }

  Future<void> _deleteIngrediente(Map<String, dynamic> row) async {
    final cs = Theme.of(context).colorScheme;
    final id = row['ingredienteid'];
    if (id is! num) return;

    final itemNome = ((row['item'] as Map?)?['nome'] ?? '').toString().trim();
    final identifier = itemNome.isNotEmpty ? itemNome : '#${id.toInt()}';
    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ConfirmDeleteSheet(
        title: 'Excluir ingrediente?',
        recordIdentifier: identifier,
        message: 'Esta ação não poderá ser desfeita.',
        confirmLabel: 'Excluir',
        confirmColor: cs.error,
      ),
    );
    if (ok != true) return;

    try {
      await SupabaseService.delete('ingrediente', filters: {'ingredienteid': id});
      if (!mounted) return;
      await _load();
    } catch (e) {
      debugPrint('Delete ingrediente failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível excluir.')));
    }
  }

  Future<void> _addMaterial() async {
    final def = Cadastros.byKey('material');
    if (def == null) return;
    final res = await showModalBottomSheet<dynamic>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(
        definition: def,
        forcedValues: {'receitaid': widget.receitaId},
        hiddenColumns: const {'receitaid'},
        readOnlyColumns: const {'receitaid'},
      ),
    );
    if (res != null) await _load();
  }

  Future<void> _editMaterial(Map<String, dynamic> row) async {
    final def = Cadastros.byKey('material');
    if (def == null) return;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(
        definition: def,
        initialRow: row,
        forcedValues: {'receitaid': widget.receitaId},
        hiddenColumns: const {'receitaid'},
        readOnlyColumns: const {'receitaid'},
      ),
    );
    if (ok == true) await _load();
  }

  Future<void> _deleteMaterial(Map<String, dynamic> row) async {
    final cs = Theme.of(context).colorScheme;
    final id = row['materialid'];
    if (id is! num) return;

    final itemNome = ((row['item'] as Map?)?['nome'] ?? '').toString().trim();
    final identifier = itemNome.isNotEmpty ? itemNome : '#${id.toInt()}';
    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ConfirmDeleteSheet(
        title: 'Excluir material?',
        recordIdentifier: identifier,
        message: 'Esta ação não poderá ser desfeita.',
        confirmLabel: 'Excluir',
        confirmColor: cs.error,
      ),
    );
    if (ok != true) return;

    try {
      await SupabaseService.delete('material', filters: {'materialid': id});
      if (!mounted) return;
      await _load();
    } catch (e) {
      debugPrint('Delete material failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível excluir.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_loading) return const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()));
    if (_error != null) {
      return _InlineError(message: _error!, onRetry: _load);
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Receita', style: Theme.of(context).textTheme.titleMedium)),
                IconButton(onPressed: _load, icon: Icon(Icons.refresh_rounded, color: cs.primary)),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _SubsectionHeader(title: 'Ingredientes', onAdd: null),
            const SizedBox(height: AppSpacing.sm),
            if (_ingredientes.isEmpty)
              _EmptyInlineCard(message: 'Nenhum ingrediente.')
            else
              ..._ingredientes.map((r) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _MiniRowCard(
                      title: ((r['item'] as Map?)?['nome'] ?? r['itemid'] ?? 'Item').toString(),
                      subtitle: () {
                        final qty = r['quantidadegrama'];
                        final custo = r['custoingrediente'];
                        final qtyText = qty == null ? 'Qtd (g): —' : 'Qtd (g): $qty';
                        final custoNum = parsePtBrNumber(custo);
                        final custoText = custoNum == null ? 'Custo na receita (R\$): —' : 'Custo na receita (R\$): ${formatPtBrMoney(custoNum)}';
                        return '$qtyText • $custoText';
                      }(),
                      onEdit: null,
                      onDelete: null,
                    ),
                  )),
            const SizedBox(height: AppSpacing.md),
            _SubsectionHeader(title: 'Materiais/Embalagens', onAdd: null),
            const SizedBox(height: AppSpacing.sm),
            if (_materiais.isEmpty)
              _EmptyInlineCard(message: 'Nenhum material.')
            else
              ..._materiais.map((r) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _MiniRowCard(
                      title: ((r['item'] as Map?)?['nome'] ?? r['itemid'] ?? 'Item').toString(),
                      subtitle: r['quantidade'] == null ? 'Qtd: —' : 'Qtd: ${r['quantidade']}',
                      onEdit: null,
                      onDelete: null,
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}

class _ProdutoHeaderCard extends StatelessWidget {
  const _ProdutoHeaderCard({required this.produto, required this.custoProducao, required this.onEdit});

  final Map<String, dynamic> produto;
  final double custoProducao;
  final VoidCallback onEdit;

  String? _formatPtBrCompactNumber(Object? value) {
    if (value == null) return null;
    final n = value is num ? value : num.tryParse(value.toString().trim());
    if (n == null) return value.toString();
    final decimals = n % 1 == 0 ? 0 : 2;
    return n.toStringAsFixed(decimals).replaceAll('.', ',');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final nome = (produto['nome'] ?? 'Produto').toString();
    final codigo = (produto['codigo'] ?? '').toString();

    final categoriaNome = ((produto['categoria'] as Map?)?['nome'] ?? '').toString().trim();
    final custoTotalReceitasRaw =
        produto['custototalreceita'] ?? produto['custototalreceitas'] ?? produto['custototaldasreceitas'];
    final custoTotalReceitasNum = parsePtBrNumber(custoTotalReceitasRaw);
    final qtdProduzidaText = _formatPtBrCompactNumber(produto['qtdproduzida']);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: cs.outline.withValues(alpha: 0.16)),
      ),
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(nome, style: Theme.of(context).textTheme.titleLarge)),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: onEdit,
                  icon: Icon(Icons.edit_rounded, color: cs.onPrimary),
                  label: Text('Editar dados', style: TextStyle(color: cs.onPrimary)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: 6,
              children: [
                if (codigo.trim().isNotEmpty) InfoPill(icon: Icons.tag_rounded, label: 'Código', value: codigo.trim()),
                if (categoriaNome.isNotEmpty)
                  InfoPill(
                    icon: Icons.category_rounded,
                    label: 'Categoria',
                    value: categoriaNome,
                    backgroundColor: InfoPill.verde,
                    foregroundColor: Colors.white,
                  ),
                InfoPill(icon: Icons.request_quote_rounded, label: 'Custo de produção', value: formatPtBrCurrency(custoProducao)),
                if (qtdProduzidaText != null && qtdProduzidaText.trim().isNotEmpty)
                  InfoPill(icon: Icons.inventory_rounded, label: 'Qtd produzida', value: qtdProduzidaText),
                if (custoTotalReceitasNum != null)
                  InfoPill(icon: Icons.receipt_long_rounded, label: 'Custo total das receitas', value: formatPtBrCurrency(custoTotalReceitasNum)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.primaryActionLabel,
    required this.primaryActionIcon,
    required this.onPrimaryAction,
  });

  final String title;
  final String subtitle;
  final String primaryActionLabel;
  final IconData primaryActionIcon;
  final VoidCallback onPrimaryAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.35)),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        FilledButton.icon(
          onPressed: onPrimaryAction,
          icon: Icon(primaryActionIcon, color: cs.onPrimary),
          label: Text(primaryActionLabel, style: TextStyle(color: cs.onPrimary)),
        ),
      ],
    );
  }
}

class _SubsectionHeader extends StatelessWidget {
  const _SubsectionHeader({required this.title, required this.onAdd});
  final String title;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
        if (onAdd != null)
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: Icon(Icons.add_rounded, color: cs.primary),
            label: Text('Adicionar', style: TextStyle(color: cs.primary)),
          ),
      ],
    );
  }
}

class _MiniRowCard extends StatelessWidget {
  const _MiniRowCard({required this.title, required this.subtitle, required this.onEdit, required this.onDelete});

  final String title;
  final String subtitle;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            if (onEdit != null) IconButton(onPressed: onEdit, icon: Icon(Icons.edit_rounded, color: cs.primary), tooltip: 'Editar'),
            if (onDelete != null)
              IconButton(onPressed: onDelete, icon: Icon(Icons.delete_outline_rounded, color: cs.error), tooltip: 'Excluir'),
          ],
        ),
      ),
    );
  }
}

class _EmptyInlineCard extends StatelessWidget {
  const _EmptyInlineCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
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
            children: [
              Icon(Icons.error_outline_rounded, color: cs.error),
              const SizedBox(height: AppSpacing.sm),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.md),
              FilledButton(onPressed: onRetry, child: const Text('Tentar novamente')),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: cs.outline.withValues(alpha: 0.16)),
      ),
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: cs.error),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(message, style: Theme.of(context).textTheme.bodyMedium)),
            const SizedBox(width: AppSpacing.sm),
            OutlinedButton(onPressed: onRetry, child: const Text('Recarregar')),
          ],
        ),
      ),
    );
  }
}

