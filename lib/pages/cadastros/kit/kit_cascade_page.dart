import 'package:bakepro/pages/cadastros/cadastro_definitions.dart';
import 'package:bakepro/pages/cadastros/generic_cadastro_form_sheet.dart';
import 'package:bakepro/components/confirm_delete_sheet.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/theme.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:bakepro/services/state/app_session_controller.dart';

/// Editor em cascata do Kit:
/// Kit -> (KitProduto + KitEmbalagem)
class KitCascadePage extends StatefulWidget {
  const KitCascadePage({super.key, required this.kitId});

  final int? kitId;

  @override
  State<KitCascadePage> createState() => _KitCascadePageState();
}

class _KitCascadePageState extends State<KitCascadePage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _kit;
  List<Map<String, dynamic>> _kitProdutos = const [];
  List<Map<String, dynamic>> _kitEmbalagens = const [];
  num? _taxaAdmEmbalagemPct;

  // Métricas por produto do kit.
  // Key = produtoId (kitproduto.produtoid)
  final Map<int, double?> _categoriaPercentualLucroByProdutoId = {};
  final Map<int, double?> _lucroAtualPercentByProdutoId = {};

  // Performance: caches para evitar repetir queries/cálculos pesados
  // (principalmente custo de produção e soma mensal de despesas).
  final Map<int, _ProdutoMetrics> _produtoMetricsCache = {};
  final Map<int, double?> _categoriaLucroCacheByCategoriaId = {};
  final Map<String, double> _somaMensalDespesasCacheByTable = {};
  final Map<int, double> _custoProducaoCacheByProdutoId = {};

  num? _calcTotalProdutosNoKit() {
    if (_kitProdutos.isEmpty) return null;
    num total = 0;
    var any = false;
    for (final row in _kitProdutos) {
      final produto = row['produto'] is Map ? row['produto'] as Map : null;
      final unit = parsePtBrNumber(produto?['valorvenda']);
      final qty = parsePtBrNumber(row['quantidade']);
      if (unit == null || qty == null) continue;
      total += unit * qty;
      any = true;
    }
    return any ? total : null;
  }

  num? _calcTotalEmbalagensNoKit() {
    if (_kitEmbalagens.isEmpty) return null;
    num total = 0;
    var any = false;
    for (final row in _kitEmbalagens) {
      final item = row['item'] is Map ? row['item'] as Map : null;
      final rawUnit = item?['custounitario'];
      final unit = parsePtBrNumber(rawUnit);
      final qty = parsePtBrNumber(row['quantidade']);
      if (unit == null || qty == null) continue;
      total += unit * qty;
      any = true;
    }
    return any ? total : null;
  }

  String _formatPercent(double? v) => v == null ? '—' : '${formatPtBrMoney(v, decimalDigits: 2)}%';

  String _formatSignedPercent(double? v) =>
      v == null ? '—' : '${v >= 0 ? '+' : '-'}${formatPtBrMoney(v.abs(), decimalDigits: 2)}%';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final kitId = widget.kitId;
    if (kitId == null) {
      setState(() {
        _loading = false;
        _error = 'Kit inválido (sem id).';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final empresaId = context.read<AppSessionController>().empresaId;
      final kit = await SupabaseService.selectSingle('kit', filters: {'kitid': kitId});
      final kps = await SupabaseService.select(
        'kitproduto',
        // Trazemos também categoriaid e qtdproduzida para evitar uma query por produto.
        select: 'kitprodutoid,kitid,produtoid,quantidade, produto:produtoid(nome,valorvenda,categoriaid,qtdproduzida)',
        filters: {'kitid': kitId},
        orderBy: 'kitprodutoid',
        ascending: true,
        limit: 500,
      );

      num? taxaAdmPct;
      if (empresaId != null) {
        try {
          final setup = await SupabaseService.selectSingle('empresasetup', filters: {'empresaid': empresaId});
          // Campo esperado pelo usuário: taxaadm (percentual).
          taxaAdmPct = parsePtBrNumber(setup?['taxaadm']);
        } catch (e) {
          // Não falhar o carregamento do Kit por causa do setup.
          debugPrint('Load empresasetup (taxaadm) failed: $e');
          taxaAdmPct = null;
        }
      }
      final kes = await SupabaseService.select(
        'kitembalagem',
        select: 'kitembalagemid,kitid,itemid,quantidade, item:itemid(nome,custounitario)',
        filters: {'kitid': kitId},
        orderBy: 'kitembalagemid',
        ascending: true,
        limit: 500,
      );

      kps.sort((a, b) {
        final ap = a['produto'];
        final bp = b['produto'];
        final an = (ap is Map ? (ap['nome']?.toString() ?? '') : '').toLowerCase();
        final bn = (bp is Map ? (bp['nome']?.toString() ?? '') : '').toLowerCase();
        return an.compareTo(bn);
      });
      kes.sort((a, b) {
        final ai = a['item'];
        final bi = b['item'];
        final an = (ai is Map ? (ai['nome']?.toString() ?? '') : '').toLowerCase();
        final bn = (bi is Map ? (bi['nome']?.toString() ?? '') : '').toLowerCase();
        return an.compareTo(bn);
      });

      // Métricas de margem/lucro (usando um produto de referência do kit).
      final Map<int, double?> categoriaByProduto = {};
      final Map<int, double?> lucroByProduto = {};
      if (empresaId != null) {
        final produtoIds = <int>{
          for (final row in kps)
            if (row['produtoid'] is num) (row['produtoid'] as num).toInt(),
        }.toList();

        try {
          // Pré-carrega soma mensal de despesas (fixa/variável) uma única vez.
          await _primeDespesasCacheIfNeeded(empresaId: empresaId);

          final futures = produtoIds.map((pid) {
            final cached = _produtoMetricsCache[pid];
            if (cached != null) return Future.value(cached);

            // Reaproveita o join já carregado em kitproduto -> produto
            final row = kps.cast<Map>().firstWhere(
              (e) => (e['produtoid'] is num) && (e['produtoid'] as num).toInt() == pid,
              orElse: () => const {},
            );
            final produto = row['produto'] is Map ? (row['produto'] as Map).cast<String, dynamic>() : null;
            return _loadProdutoMetrics(produtoId: pid, empresaId: empresaId, produtoFromKitJoin: produto);
          });

          final results = await Future.wait(futures);
          for (final r in results) {
            _produtoMetricsCache[r.produtoId] = r;
            categoriaByProduto[r.produtoId] = r.categoriaPercentualLucro;
            lucroByProduto[r.produtoId] = r.lucroAtualPercent;
          }
        } catch (e) {
          debugPrint('Load Kit metrics by produto failed: $e');
        }
      }

      if (!mounted) return;
      setState(() {
        _kit = kit;
        _kitProdutos = kps;
        _kitEmbalagens = kes;
        _taxaAdmEmbalagemPct = taxaAdmPct;
        _categoriaPercentualLucroByProdutoId
          ..clear()
          ..addAll(categoriaByProduto);
        _lucroAtualPercentByProdutoId
          ..clear()
          ..addAll(lucroByProduto);
      });
    } catch (e) {
      debugPrint('Load Kit cascade failed: $e');
      if (!mounted) return;
      setState(() => _error = 'Não foi possível carregar o kit.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<_ProdutoMetrics> _loadProdutoMetrics({required int produtoId, required dynamic empresaId, Map<String, dynamic>? produtoFromKitJoin}) async {
    try {
      final produto = produtoFromKitJoin ??
          (await SupabaseService.selectSingle(
            'produto',
            select: 'produtoid,categoriaid,valorvenda,qtdproduzida',
            filters: {'produtoid': produtoId},
          ));
      final categoriaId = (produto?['categoriaid'] is num) ? (produto?['categoriaid'] as num).toInt() : null;
      final valorVendaDefinido = parsePtBrNumber(produto?['valorvenda']);
      final qtdProduzida = parsePtBrNumber(produto?['qtdproduzida']) ?? 0.0;

      if (categoriaId == null) return _ProdutoMetrics(produtoId: produtoId, categoriaPercentualLucro: null, lucroAtualPercent: null, precoVendaCalculado: null);

      final categoriaLucroCached = _categoriaLucroCacheByCategoriaId[categoriaId];
      final Map<String, dynamic>? categoria = (categoriaLucroCached != null || _categoriaLucroCacheByCategoriaId.containsKey(categoriaId))
          ? null
          : await SupabaseService.selectSingle(
              'categoria',
              select: 'categoriaid,percentuallucro,percentualrateiodespesa,quantidadeproducaomes',
              filters: {'categoriaid': categoriaId},
            );
      final categoriaLucro = categoriaLucroCached ?? parsePtBrNumber(categoria?['percentuallucro']);
      _categoriaLucroCacheByCategoriaId[categoriaId] = categoriaLucro;

      // Para o rateio/despesa por unidade, precisamos dos campos da categoria.
      // Se não buscamos a categoria agora, buscamos somente os campos necessários.
      final categoriaForRateio = categoria ??
          await SupabaseService.selectSingle(
            'categoria',
            select: 'categoriaid,percentualrateiodespesa,quantidadeproducaomes',
            filters: {'categoriaid': categoriaId},
          );

      final custoProducao = _custoProducaoCacheByProdutoId[produtoId] ?? await _computeCustoProducaoSingle(produtoId);
      _custoProducaoCacheByProdutoId[produtoId] = custoProducao;
      final custoUnitario = (qtdProduzida > 0) ? (custoProducao / qtdProduzida) : 0.0;

      final somaFixa = _somaMensalDespesasCacheByTable['despesafixa'] ?? 0.0;
      final somaVariavel = _somaMensalDespesasCacheByTable['despesavariavel'] ?? 0.0;
      final despesaFixaUn = _computeDespesaUnidadeFromSoma(somaMensal: somaFixa, categoria: categoriaForRateio);
      final despesaVariavelUn = _computeDespesaUnidadeFromSoma(somaMensal: somaVariavel, categoria: categoriaForRateio);

      final baseVenda = custoUnitario + despesaFixaUn + despesaVariavelUn;
      final lucroAtual = (valorVendaDefinido == null || baseVenda == 0) ? null : ((valorVendaDefinido / baseVenda) - 1.0) * 100.0;
      final precoVendaCalculado = (categoriaLucro == null || baseVenda == 0) ? null : baseVenda * ((categoriaLucro / 100.0) + 1.0);

      return _ProdutoMetrics(produtoId: produtoId, categoriaPercentualLucro: categoriaLucro, lucroAtualPercent: lucroAtual, precoVendaCalculado: precoVendaCalculado);
    } catch (e) {
      debugPrint('Kit: load produto metrics failed (produtoId=$produtoId): $e');
      return _ProdutoMetrics(produtoId: produtoId, categoriaPercentualLucro: null, lucroAtualPercent: null, precoVendaCalculado: null);
    }
  }

  Future<void> _primeDespesasCacheIfNeeded({required dynamic empresaId}) async {
    try {
      if (_somaMensalDespesasCacheByTable.containsKey('despesafixa') && _somaMensalDespesasCacheByTable.containsKey('despesavariavel')) return;
      final results = await Future.wait([
        _loadSomaMensalDespesas(table: 'despesafixa', empresaId: empresaId),
        _loadSomaMensalDespesas(table: 'despesavariavel', empresaId: empresaId),
      ]);
      _somaMensalDespesasCacheByTable['despesafixa'] = results[0];
      _somaMensalDespesasCacheByTable['despesavariavel'] = results[1];
    } catch (e) {
      debugPrint('Kit: prime despesas cache failed: $e');
    }
  }

  Future<double> _loadSomaMensalDespesas({required String table, required dynamic empresaId}) async {
    try {
      var query = SupabaseConfig.client.from(table).select('valormensal').eq('empresaid', empresaId);
      // Despesas fixas e variáveis: somente as ativas entram no total.
      query = query.eq('status', 'A');
      final dynamic despesasRaw = await query.limit(5000);
      var somaMensal = 0.0;
      if (despesasRaw is List) {
        for (final d in despesasRaw) {
          if (d is! Map) continue;
          somaMensal += parsePtBrNumber(d['valormensal']) ?? 0.0;
        }
      }
      return somaMensal;
    } catch (e) {
      debugPrint('Kit: load soma mensal despesas failed (table=$table): $e');
      return 0.0;
    }
  }

  Future<double> _computeCustoProducaoSingle(int produtoId) async {
    try {
      final dynamic prs = await SupabaseConfig.client
          .from('produtoreceita')
          .select('produtoid,quantidadereceita, receita:receitaid(custoreceita,qtdreceita)')
          .eq('produtoid', produtoId)
          .limit(5000);

      var total = 0.0;
      if (prs is List) {
        for (final pr in prs) {
          if (pr is! Map) continue;
          final qtd = parsePtBrNumber(pr['quantidadereceita']) ?? 0.0;
          final receita = pr['receita'] is Map ? pr['receita'] as Map : null;
          final custoReceita = parsePtBrNumber(receita?['custoreceita']) ?? 0.0;
          final qtdReceita = parsePtBrNumber(receita?['qtdreceita']) ?? 0.0;
          if (qtd <= 0 || custoReceita <= 0 || qtdReceita <= 0) continue;
          total += (custoReceita / qtdReceita) * qtd;
        }
      }
      return total;
    } catch (e) {
      debugPrint('Kit: compute custo producao failed: $e');
      return 0.0;
    }
  }

  double _computeDespesaUnidadeFromSoma({required double somaMensal, required Map<String, dynamic>? categoria}) {
    final percentual = parsePtBrNumber(categoria?['percentualrateiodespesa']) ?? 0.0;
    final qtdProducaoMes = parsePtBrNumber(categoria?['quantidadeproducaomes']) ?? 0.0;
    if (percentual <= 0 || qtdProducaoMes <= 0 || somaMensal <= 0) return 0.0;
    return somaMensal * (percentual / 100.0) / qtdProducaoMes;
  }

  Future<void> _editKit() async {
    final def = Cadastros.byKey('kit');
    final row = _kit;
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

  Future<void> _addKitProduto() async {
    final def = Cadastros.byKey('kitproduto');
    final kitId = widget.kitId;
    if (def == null || kitId == null) return;

    final res = await showModalBottomSheet<dynamic>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(
        definition: def,
        forcedValues: {'kitid': kitId},
        hiddenColumns: const {'kitid'},
        readOnlyColumns: const {'kitid'},
      ),
    );
    if (res != null) await _load();
  }

  Future<void> _editKitProduto(Map<String, dynamic> row) async {
    final def = Cadastros.byKey('kitproduto');
    final kitId = widget.kitId;
    if (def == null || kitId == null) return;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(
        definition: def,
        initialRow: row,
        forcedValues: {'kitid': kitId},
        hiddenColumns: const {'kitid'},
        readOnlyColumns: const {'kitid'},
      ),
    );
    if (ok == true) await _load();
  }

  Future<void> _deleteKitProduto(Map<String, dynamic> row) async {
    final cs = Theme.of(context).colorScheme;
    final id = row['kitprodutoid'];
    if (id is! num) return;

    final produtoNome = ((row['produto'] as Map?)?['nome'] ?? '').toString().trim();
    final identifier = produtoNome.isNotEmpty ? produtoNome : '#${id.toInt()}';

    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ConfirmDeleteSheet(
        title: 'Excluir produto do kit?',
        recordIdentifier: identifier,
        message: 'Esta ação não poderá ser desfeita.',
        confirmLabel: 'Excluir',
        confirmColor: cs.error,
      ),
    );
    if (ok != true) return;

    try {
      await SupabaseService.delete('kitproduto', filters: {'kitprodutoid': id});
      if (!mounted) return;
      await _load();
    } catch (e) {
      debugPrint('Delete kitproduto failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível excluir.')));
    }
  }

  Future<void> _addKitEmbalagem() async {
    final def = Cadastros.byKey('kitembalagem');
    final kitId = widget.kitId;
    if (def == null || kitId == null) return;

    final res = await showModalBottomSheet<dynamic>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(
        definition: def,
        forcedValues: {'kitid': kitId},
        hiddenColumns: const {'kitid'},
        readOnlyColumns: const {'kitid'},
      ),
    );
    if (res != null) await _load();
  }

  Future<void> _editKitEmbalagem(Map<String, dynamic> row) async {
    final def = Cadastros.byKey('kitembalagem');
    final kitId = widget.kitId;
    if (def == null || kitId == null) return;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(
        definition: def,
        initialRow: row,
        forcedValues: {'kitid': kitId},
        hiddenColumns: const {'kitid'},
        readOnlyColumns: const {'kitid'},
      ),
    );
    if (ok == true) await _load();
  }

  Future<void> _deleteKitEmbalagem(Map<String, dynamic> row) async {
    final cs = Theme.of(context).colorScheme;
    final id = row['kitembalagemid'];
    if (id is! num) return;

    final embalagemNome = ((row['item'] as Map?)?['nome'] ?? '').toString().trim();
    final identifier = embalagemNome.isNotEmpty ? embalagemNome : '#${id.toInt()}';

    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ConfirmDeleteSheet(
        title: 'Excluir embalagem do kit?',
        recordIdentifier: identifier,
        message: 'Esta ação não poderá ser desfeita.',
        confirmLabel: 'Excluir',
        confirmColor: cs.error,
      ),
    );
    if (ok != true) return;

    try {
      await SupabaseService.delete('kitembalagem', filters: {'kitembalagemid': id});
      if (!mounted) return;
      await _load();
    } catch (e) {
      debugPrint('Delete kitembalagem failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível excluir.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final totalProdutosNoKit = _calcTotalProdutosNoKit();
    final totalEmbalagensNoKit = _calcTotalEmbalagensNoKit();
    final taxaAdmPct = _taxaAdmEmbalagemPct;
    final totalEmbalagensComTaxa = totalEmbalagensNoKit == null
        ? null
        : totalEmbalagensNoKit * (1 + ((taxaAdmPct ?? 0) / 100));
    final totalKit = (totalProdutosNoKit == null && totalEmbalagensNoKit == null)
        ? null
        : (totalProdutosNoKit ?? 0) + (totalEmbalagensComTaxa ?? 0);
    final produtosSubtitle = '';
    final embalagensSubtitle = '';

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
                Expanded(child: Text('Kit', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
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
                             _KitHeaderCard(
                               kit: _kit ?? const {},
                               onEdit: _editKit,
                               totalProdutos: totalProdutosNoKit,
                               totalEmbalagens: totalEmbalagensNoKit,
                               taxaAdmPct: taxaAdmPct,
                               totalEmbalagensComTaxa: totalEmbalagensComTaxa,
                               totalKit: totalKit,
                             ),
                            const SizedBox(height: AppSpacing.lg),
                            _SectionHeader(
                              title: 'Produtos do Kit',
                              subtitle: produtosSubtitle,
                              titleTrailing: totalProdutosNoKit == null
                                  ? null
                                  : _InlineValuePill(
                                      icon: Icons.payments_rounded,
                                      label: 'Valor dos produtos',
                                      value: formatPtBrCurrency(totalProdutosNoKit),
                                    ),
                              primaryActionLabel: 'Adicionar',
                              primaryActionIcon: Icons.add_rounded,
                              onPrimaryAction: _addKitProduto,
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            if (_kitProdutos.isEmpty)
                              _EmptyInlineCard(message: 'Nenhum produto adicionado a este kit.')
                            else
                              ..._kitProdutos.map((row) => Padding(
                                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                                    child: _KitChildCard(
                                      icon: Icons.local_offer_rounded,
                                      title: ((row['produto'] as Map?)?['nome'] ?? row['produtoid'] ?? 'Produto').toString(),
                                      titleTrailing: () {
                                        final pid = row['produtoid'];
                                        final produtoId = pid is num ? pid.toInt() : null;
                                        if (produtoId == null) return const <Widget>[];

                                        final precoCalc = _produtoMetricsCache[produtoId]?.precoVendaCalculado;
                                        final value = precoCalc == null ? '—' : '${formatPtBrCurrency(precoCalc)}/un';
                                        return <Widget>[
                                          _InlineMetricPill(icon: Icons.calculate_rounded, label: 'Preço venda calc.', value: value),
                                        ];
                                      }(),
                                      secondaryLine: _formatValorVendaUnitario(row['produto']),
                                      quantity: row['quantidade'],
                                      unitValue: parsePtBrNumber((row['produto'] as Map?)?['valorvenda']),
                                      oneLineMetrics: true,
                                      extraOneLineMetrics: () {
                                        final pid = row['produtoid'];
                                        final produtoId = pid is num ? pid.toInt() : null;
                                        if (produtoId == null) return const <Widget>[];
                                        final catPct = _categoriaPercentualLucroByProdutoId[produtoId];
                                        final lucroPct = _lucroAtualPercentByProdutoId[produtoId];
                                        final categoriaLucroValue = _formatPercent(catPct);
                                        final lucroAtualValue = _formatSignedPercent(lucroPct);

                                        final cs = Theme.of(context).colorScheme;
                                        final isBelowCategoria = (catPct != null && lucroPct != null) ? (lucroPct < catPct) : false;
                                        return <Widget>[
                                          _InlineMetricPill(icon: Icons.percent_rounded, label: 'Margem cat.', value: categoriaLucroValue),
                                          _InlineMetricPill(
                                            icon: isBelowCategoria ? Icons.trending_down_rounded : Icons.trending_up_rounded,
                                            label: 'Lucro atual',
                                            value: lucroAtualValue,
                                            iconColor: isBelowCategoria ? cs.error : null,
                                            valueColor: isBelowCategoria ? cs.error : null,
                                            backgroundColor: isBelowCategoria ? cs.errorContainer.withValues(alpha: 0.35) : null,
                                            borderColor: isBelowCategoria ? cs.error.withValues(alpha: 0.22) : null,
                                          ),
                                        ];
                                      }(),
                                      onEdit: () => _editKitProduto(row),
                                      onDelete: () => _deleteKitProduto(row),
                                    ),
                                  )),
                            const SizedBox(height: AppSpacing.lg),
                            _SectionHeader(
                              title: 'Embalagens do Kit',
                              subtitle: embalagensSubtitle,
                              titleTrailing: totalEmbalagensNoKit == null
                                  ? null
                                  : _InlineValuePill(
                                      icon: Icons.payments_rounded,
                                      label: 'Valor das embalagens',
                                      value: formatPtBrCurrency(totalEmbalagensNoKit),
                                    ),
                              primaryActionLabel: 'Adicionar',
                              primaryActionIcon: Icons.add_rounded,
                              onPrimaryAction: _addKitEmbalagem,
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            if (_kitEmbalagens.isEmpty)
                              _EmptyInlineCard(message: 'Nenhuma embalagem adicionada a este kit.')
                            else
                              ..._kitEmbalagens.map((row) => Padding(
                                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                                    child: _KitChildCard(
                                      icon: Icons.inventory_2_rounded,
                                      title: ((row['item'] as Map?)?['nome'] ?? row['itemid'] ?? 'Item').toString(),
                                      secondaryLine: _formatCustoUnitario(row['item']),
                                      quantity: row['quantidade'],
                                      unitValue: _parseCustoUnitario(row['item']),
                                      oneLineMetrics: true,
                                      onEdit: () => _editKitEmbalagem(row),
                                      onDelete: () => _deleteKitEmbalagem(row),
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

String? _formatCustoUnitario(Object? itemRaw) {
  final item = itemRaw is Map ? itemRaw : null;
  final v = _parseCustoUnitario(item);
  if (v == null) return null;
  return 'Custo unitário: ${formatPtBrCurrency(v)}/un';
}

num? _parseCustoUnitario(Object? itemRaw) {
  final item = itemRaw is Map ? itemRaw : null;
  final raw = item?['custounitario'];
  return parsePtBrNumber(raw);
}

class _KitHeaderCard extends StatelessWidget {
  const _KitHeaderCard({
    required this.kit,
    required this.onEdit,
    required this.totalProdutos,
    required this.totalEmbalagens,
    required this.taxaAdmPct,
    required this.totalEmbalagensComTaxa,
    required this.totalKit,
  });

  final Map<String, dynamic> kit;
  final VoidCallback onEdit;
  final num? totalProdutos;
  final num? totalEmbalagens;
  final num? taxaAdmPct;
  final num? totalEmbalagensComTaxa;
  final num? totalKit;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final nome = (kit['nome'] ?? 'Kit').toString();
    final descricao = (kit['descricao'] ?? kit['descricaokit'] ?? '').toString().trim();
    final statusRaw = (kit['status'] ?? '').toString().trim();
    final statusUpper = statusRaw.toUpperCase();
    final isInactive = statusUpper == 'I' || statusUpper == 'INATIVO';

    final taxaPillValue = taxaAdmPct == null ? '—' : '${formatPtBrMoney(taxaAdmPct!, decimalDigits: 2)}%';
    final totalEmbalagensComTaxaComputed = (totalEmbalagens == null)
        ? null
        : totalEmbalagens! * (1 + ((taxaAdmPct ?? 0) / 100));
    final totalEmbalagensComTaxaValue = totalEmbalagensComTaxa ?? totalEmbalagensComTaxaComputed;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
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
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              nome,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.2, height: 1.05),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Flexible(
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              alignment: WrapAlignment.end,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (isInactive) Padding(padding: const EdgeInsets.only(top: 2), child: _KitPill(text: 'Inativo')),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (descricao.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        // Descrição completa (mantém as quebras de linha digitadas).
                        Text(
                          descricao,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.25),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: 6,
                        children: [
                          _InlineValuePill(icon: Icons.local_offer_rounded, label: 'Produtos', value: totalProdutos == null ? '—' : formatPtBrCurrency(totalProdutos!)),
                          _InlineValuePill(icon: Icons.inventory_2_rounded, label: 'Embalagens', value: totalEmbalagens == null ? '—' : formatPtBrCurrency(totalEmbalagens!)),
                          _InlineValuePill(icon: Icons.percent_rounded, label: 'Taxa adm embalagem', value: taxaPillValue),
                          _InlineValuePill(
                            icon: Icons.payments_rounded,
                            label: 'Valor total embalagem - R\$',
                            value: totalEmbalagensComTaxaValue == null ? '—' : formatPtBrCurrency(totalEmbalagensComTaxaValue),
                          ),
                          _InlineValuePill(
                            icon: Icons.account_balance_wallet_rounded,
                            label: 'Valor total do kit - R\$',
                            value: totalKit == null ? '—' : formatPtBrCurrency(totalKit!),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: onEdit,
                  style: FilledButton.styleFrom(backgroundColor: AppBrandColors.terracotta),
                  icon: const Icon(Icons.edit_rounded, color: AppBrandColors.onTerracotta),
                  label: const Text('Editar dados', style: TextStyle(color: AppBrandColors.onTerracotta)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String? _formatValorVendaUnitario(Object? produtoRaw) {
  final p = produtoRaw is Map ? produtoRaw : null;
  final valor = parsePtBrNumber(p?['valorvenda']);
  if (valor == null) return null;
  return 'Preço de venda: ${formatPtBrCurrency(valor)}/un';
}

class _KitPill extends StatelessWidget {
  const _KitPill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isInactive = text.trim().toLowerCase() == 'inativo';
    // Active status should be visually softer than inactive.
    final bg = isInactive ? cs.errorContainer : cs.primaryContainer.withValues(alpha: 0.55);
    final fg = isInactive ? cs.onErrorContainer : cs.onPrimaryContainer;
    final border = isInactive ? cs.error.withValues(alpha: 0.22) : cs.primary.withValues(alpha: 0.22);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
      ),
    );
  }
}

class _InfoMetricCard extends StatelessWidget {
  const _InfoMetricCard({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: cs.tertiary),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
                const SizedBox(height: 2),
                Text(value, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w800)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyValueText {
  const _KeyValueText(this.key, this.value);
  final String key;
  final String value;

  static _KeyValueText? tryParse(String? raw) {
    if (raw == null) return null;
    final parts = raw.split(':');
    if (parts.length < 2) return null;
    final key = parts.first.trim();
    final value = parts.sublist(1).join(':').trim();
    if (key.isEmpty || value.isEmpty) return null;
    return _KeyValueText(key, value);
  }
}

class _ProdutoMetrics {
  const _ProdutoMetrics({required this.produtoId, required this.categoriaPercentualLucro, required this.lucroAtualPercent, required this.precoVendaCalculado});
  final int produtoId;
  final double? categoriaPercentualLucro;
  final double? lucroAtualPercent;
  final double? precoVendaCalculado;
}

class _KitChildCard extends StatelessWidget {
  const _KitChildCard({
    required this.icon,
    required this.title,
    required this.quantity,
    required this.onEdit,
    required this.onDelete,
    this.secondaryLine,
    this.unitValue,
    this.oneLineMetrics = false,
    this.extraOneLineMetrics = const <Widget>[],
    this.titleTrailing = const <Widget>[],
  });

  final IconData icon;
  final String title;
  final Object? quantity;
  final String? secondaryLine;
  /// Optional unit price used to compute total value inside the kit.
  /// When provided, the card will show an extra metric: "Valor no kit".
  final num? unitValue;
  final bool oneLineMetrics;
  /// Extra metric pills to append when [oneLineMetrics] is true.
  /// Useful to show derived KPIs for the specific child item.
  final List<Widget> extraOneLineMetrics;
  /// Optional trailing widgets shown inline with the title (same row).
  /// Useful for quick KPIs like "Preço venda calculado".
  final List<Widget> titleTrailing;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final qty = (quantity ?? '').toString();
    final qtyNumber = parsePtBrNumber(quantity);
    final parsedSecondary = _KeyValueText.tryParse(secondaryLine);
    final totalValue = (unitValue != null && qtyNumber != null) ? unitValue! * qtyNumber : null;
    final iconBtnStyle = IconButton.styleFrom(
      padding: const EdgeInsets.all(10),
      minimumSize: const Size(40, 40),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      splashFactory: NoSplash.splashFactory,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
    );

    final metrics = oneLineMetrics
        ? _OneLineMetricsRow(
            children: [
              _InlineMetricPill(icon: Icons.numbers_rounded, label: 'Qtde', value: qty),
              if (secondaryLine != null)
                _InlineMetricPill(
                  icon: Icons.sell_rounded,
                  label: parsedSecondary?.key ?? 'Unit',
                  value: parsedSecondary?.value ?? secondaryLine!,
                ),
              ...extraOneLineMetrics,
              if (totalValue != null) _InlineMetricPill(icon: Icons.payments_rounded, label: 'Total', value: formatPtBrCurrency(totalValue)),
            ],
          )
        : Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              _InfoMetricCard(icon: Icons.numbers_rounded, label: 'Quantidade', value: qty),
              if (secondaryLine != null)
                _InfoMetricCard(
                  icon: Icons.sell_rounded,
                  label: parsedSecondary?.key ?? 'Valor de venda unitário',
                  value: parsedSecondary?.value ?? secondaryLine!,
                ),
              if (totalValue != null) _InfoMetricCard(icon: Icons.payments_rounded, label: 'Valor no kit', value: formatPtBrCurrency(totalValue)),
            ],
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
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
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: cs.secondary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: cs.secondary.withValues(alpha: 0.18)),
                  ),
                  child: Padding(
                    padding: AppSpacing.paddingMd,
                    child: Icon(icon, color: cs.secondary),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
                          if (titleTrailing.isNotEmpty) ...[
                            const SizedBox(width: AppSpacing.sm),
                            Flexible(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  alignment: WrapAlignment.end,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: titleTrailing,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(width: AppSpacing.sm),
                          IconButton(
                            onPressed: onEdit,
                            style: iconBtnStyle.copyWith(backgroundColor: WidgetStatePropertyAll(cs.primaryContainer.withValues(alpha: 0.55))),
                            icon: Icon(Icons.edit_rounded, color: cs.primary),
                            tooltip: 'Editar',
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            onPressed: onDelete,
                            style: iconBtnStyle.copyWith(backgroundColor: WidgetStatePropertyAll(cs.errorContainer.withValues(alpha: 0.65))),
                            icon: Icon(Icons.delete_outline_rounded, color: cs.error),
                            tooltip: 'Excluir',
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      metrics,
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle, required this.primaryActionLabel, required this.primaryActionIcon, required this.onPrimaryAction, this.titleTrailing});

  final String title;
  final String subtitle;
  final String primaryActionLabel;
  final IconData primaryActionIcon;
  final VoidCallback onPrimaryAction;
  final Widget? titleTrailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final subtitleTrim = subtitle.trim();
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis)),
                  if (titleTrailing != null) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Flexible(child: Align(alignment: Alignment.centerLeft, child: titleTrailing!)),
                  ],
                ],
              ),
              if (subtitleTrim.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitleTrim, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.3)),
              ],
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        FilledButton.icon(
          onPressed: onPrimaryAction,
          icon: Icon(primaryActionIcon, color: cs.onPrimary),
          label: Text(primaryActionLabel, style: TextStyle(color: cs.onPrimary)),
        ),
      ],
    );
  }
}

class _InlineValuePill extends StatelessWidget {
  const _InlineValuePill({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: cs.tertiary),
            const SizedBox(width: 8),
            Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            Text(value, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}

class _InlineMetricPill extends StatelessWidget {
  const _InlineMetricPill({
    required this.icon,
    required this.label,
    required this.value,
    this.iconColor,
    this.valueColor,
    this.backgroundColor,
    this.borderColor,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color? iconColor;
  final Color? valueColor;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor ?? cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor ?? cs.outline.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: iconColor ?? cs.tertiary),
            const SizedBox(width: 6),
            Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w800, letterSpacing: 0.2)),
            const SizedBox(width: 6),
            Text(value, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: valueColor ?? cs.onSurface, fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}

class _OneLineMetricsRow extends StatelessWidget {
  const _OneLineMetricsRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // Keep everything in a single line by scaling down when needed.
    return Align(
      alignment: Alignment.centerLeft,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(mainAxisSize: MainAxisSize.min, children: _withGaps(children, const SizedBox(width: AppSpacing.sm))),
      ),
    );
  }

  static List<Widget> _withGaps(List<Widget> items, Widget gap) {
    if (items.isEmpty) return const [];
    final out = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      out.add(items[i]);
      if (i != items.length - 1) out.add(gap);
    }
    return out;
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
          border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
        ),
        child: Padding(
          padding: AppSpacing.paddingLg,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: AppSpacing.md),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: Icon(Icons.refresh_rounded, color: cs.primary),
                label: Text('Tentar novamente', style: TextStyle(color: cs.primary)),
              ),
            ],
          ),
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
        child: Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.35)),
      ),
    );
  }
}

