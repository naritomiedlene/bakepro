import 'dart:math' as math;

import 'package:bakepro/components/pdf_preview_dialog.dart';
import 'package:bakepro/nav.dart';
import 'package:bakepro/services/relatorios/precificacao_pdf_report.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/theme.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

class PrecificacaoProdutosPage extends StatefulWidget {
  const PrecificacaoProdutosPage({super.key});

  @override
  State<PrecificacaoProdutosPage> createState() => _PrecificacaoProdutosPageState();
}

class _PrecificacaoProdutosPageState extends State<PrecificacaoProdutosPage> {
  // null = TODOS (todas as categorias).
  int? _categoriaId;
  bool _loadingCategorias = true;
  bool _loadingList = true;
  String? _error;
  List<_CategoriaOption> _categorias = const [];
  List<_ProdutoPrecificacaoRow> _rows = const [];

  final PageController _pageController = PageController();
  int _pageIndex = 0;

  DateTime? _lastWheelNavAt;
  double _wheelAccumulator = 0;

  final TextEditingController _nomeFilterController = TextEditingController();
  String _nomeFilter = '';

  @override
  void dispose() {
    _nomeFilterController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _resetToFirstProduct() {
    if (_pageIndex == 0) return;
    _pageIndex = 0;
    if (_pageController.hasClients) {
      // Animating keeps it feeling consistent with the “page” affordance.
      _pageController.animateToPage(0, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
  }

  int _clampIndex(int index, int length) {
    if (length <= 0) return 0;
    return index.clamp(0, length - 1);
  }

  Future<void> _animateToIndex(int index, int length) async {
    final target = _clampIndex(index, length);
    if (!_pageController.hasClients) {
      setState(() => _pageIndex = target);
      return;
    }
    setState(() => _pageIndex = target);
    await _pageController.animateToPage(target, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
  }

  Future<void> _prev(int length) => _animateToIndex(_pageIndex - 1, length);
  Future<void> _next(int length) => _animateToIndex(_pageIndex + 1, length);

  void _handleMouseWheel(PointerScrollEvent e, int length) {
    if (length <= 1) return;
    final now = DateTime.now();
    // Trackpads can send many tiny deltas; mouse wheels can send large deltas.
    // We convert both into a predictable "1 product per step" navigation.
    final dy = e.scrollDelta.dy;
    if (dy == 0) return;

    // Debounce a bit to avoid accidental multi-step jumps.
    if (_lastWheelNavAt != null && now.difference(_lastWheelNavAt!) < const Duration(milliseconds: 140)) return;

    _wheelAccumulator += dy;
    const threshold = 18.0; // tuned for web/desktop; prevents needing to scroll a lot on trackpad
    if (_wheelAccumulator.abs() < threshold) return;

    _lastWheelNavAt = now;
    final goNext = _wheelAccumulator > 0;
    _wheelAccumulator = 0;
    if (goNext) {
      _next(length);
    } else {
      _prev(length);
    }
  }

  int _safePageIndex(int length) {
    if (length <= 0) return 0;
    return _pageIndex.clamp(0, length - 1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Carregar apenas uma vez quando entrar na tela.
    if (_loadingCategorias || _loadingList) _load();
  }

  Future<void> _load() async {
    final empresaId = context.read<AppSessionController>().empresaId;
    if (empresaId == null) {
      setState(() {
        _loadingCategorias = false;
        _loadingList = false;
        _error = 'Empresa não identificada. Faça login novamente.';
      });
      return;
    }

    setState(() {
      _loadingCategorias = _categorias.isEmpty;
      _loadingList = true;
      _error = null;
    });

    try {
      // 1) Categorias (para o combobox)
      List<_CategoriaOption> categorias = _categorias;
      if (_categorias.isEmpty) {
        final dynamic categoriasRaw = await SupabaseConfig.client
            .from('categoria')
            .select('categoriaid,nome')
            .eq('empresaid', empresaId)
            .order('nome');

        final parsed = <_CategoriaOption>[];
        if (categoriasRaw is List) {
          for (final r in categoriasRaw) {
            if (r is! Map) continue;
            final id = r['categoriaid'];
            final nome = (r['nome'] ?? '').toString().trim();
            if (id is num && nome.isNotEmpty) parsed.add(_CategoriaOption(id: id.toInt(), nome: nome));
          }
        }
        categorias = parsed;
        if (mounted) {
          setState(() {
            _categorias = categorias;
            _loadingCategorias = false;
          });
        }
      } else {
        if (mounted) setState(() => _loadingCategorias = false);
      }

      // 2) Produtos base (sem cálculo)
      final dynamic produtosRaw = await SupabaseConfig.client
          .from('produto')
          .select(
            'produtoid,codigo,nome,descricao,categoriaid,qtdproduzida,valorvenda,dataatualizacaovalorvenda, categoria:categoriaid(nome,percentualrateiodespesa,percentuallucro,quantidadeproducaomes)',
          )
          .eq('empresaid', empresaId)
          .eq('status', 'A')
          .order('nome')
          .limit(5000);

      final produtos = <Map<String, dynamic>>[];
      final produtoIds = <int>[];
      final categoriaIds = <int>{};
      if (produtosRaw is List) {
        for (final r in produtosRaw) {
          if (r is! Map) continue;
          final id = r['produtoid'];
          if (id is num) {
            final mid = <String, dynamic>{};
            r.forEach((k, v) => mid[k.toString()] = v);
            produtos.add(mid);
            produtoIds.add(id.toInt());

            final catIdRaw = r['categoriaid'];
            if (catIdRaw is num) categoriaIds.add(catIdRaw.toInt());
          }
        }
      }

      // 3) Custo de produção por produto (batch)
      final custosProducao = await _computeCustoProducao(produtoIds);

      // 3.1) Despesa fixa por unidade (por categoria)
      final despesaFixaPorUnidade = await _computeDespesaFixaPorUnidade(
        empresaId: empresaId,
        categoriaIds: categoriaIds.toList(growable: false),
      );

      // 3.2) Despesa variável por unidade (por categoria)
      final despesaVariavelPorUnidade = await _computeDespesaVariavelPorUnidade(
        empresaId: empresaId,
        categoriaIds: categoriaIds.toList(growable: false),
      );

      // 4) Montar rows para render
      final rows = <_ProdutoPrecificacaoRow>[];
      for (final p in produtos) {
        final idRaw = p['produtoid'];
        if (idRaw is! num) continue;
        final produtoId = idRaw.toInt();
        final categoriaId = (p['categoriaid'] is num) ? (p['categoriaid'] as num).toInt() : null;
        final categoria = (p['categoria'] as Map?);
        final categoriaNome = (categoria?['nome'] ?? '').toString().trim();
        final percentualRateioDespesa = parsePtBrNumber(categoria?['percentualrateiodespesa']) ?? 0.0;
        final percentualLucro = parsePtBrNumber(categoria?['percentuallucro']) ?? 0.0;
        final quantidadeProducaoMes = parsePtBrNumber(categoria?['quantidadeproducaomes']);
        final valorVendaDefinido = parsePtBrNumber(p['valorvenda']);
        final dataAtualizacaoValorVenda = _parseLooseDateTime(p['dataatualizacaovalorvenda']);

        final custoProducao = custosProducao[produtoId] ?? 0.0;
        final qtdProduzida = parsePtBrNumber(p['qtdproduzida']) ?? 0.0;
        final custoUnitario = (qtdProduzida > 0) ? (custoProducao / qtdProduzida) : 0.0;
        final despesaFixaUnidade = categoriaId == null ? 0.0 : (despesaFixaPorUnidade[categoriaId] ?? 0.0);
        final despesaVariavelUnidade = categoriaId == null ? 0.0 : (despesaVariavelPorUnidade[categoriaId] ?? 0.0);

        rows.add(
          _ProdutoPrecificacaoRow(
            produtoId: produtoId,
            codigo: (p['codigo'] ?? '').toString().trim(),
            nome: (p['nome'] ?? '').toString().trim(),
            descricao: (p['descricao'] ?? '').toString().trim(),
            categoriaId: categoriaId,
            categoriaNome: categoriaNome,
            quantidadeProducaoMes: quantidadeProducaoMes,
            percentualRateioDespesa: percentualRateioDespesa,
            percentualLucro: percentualLucro,
            custoProducao: custoProducao,
            qtdProduzida: qtdProduzida,
            custoUnitario: custoUnitario,
            despesaFixaPorUnidade: despesaFixaUnidade,
            despesaVariavelPorUnidade: despesaVariavelUnidade,
            valorVendaDefinido: valorVendaDefinido,
            dataAtualizacaoValorVenda: dataAtualizacaoValorVenda,
          ),
        );
      }

      setState(() {
        _rows = rows;
        _loadingList = false;
      });
    } catch (e) {
      setState(() {
        _loadingCategorias = false;
        _loadingList = false;
        _error = 'Falha ao carregar precificação: $e';
      });
    }
  }

  /// Gera o PDF com os produtos visíveis (filtros de categoria e nome aplicados).
  Future<void> _openPdf(List<_ProdutoPrecificacaoRow> rows) async {
    final session = context.read<AppSessionController>();
    final categoriaId = _categoriaId;
    final filtroCategoria = categoriaId == null
        ? 'TODOS'
        : (_categorias.where((c) => c.id == categoriaId).map((c) => c.nome).firstOrNull ?? '#$categoriaId');
    final filtroNome = _nomeFilter.trim();
    final empresa = session.empresaLabel;
    final linhas = [
      for (final r in rows)
        () {
          final base = r.custoUnitario + r.despesaFixaPorUnidade + r.despesaVariavelPorUnidade;
          return PrecificacaoPdfLinha(
            codigo: (r.codigo.isNotEmpty ? r.codigo : '#${r.produtoId}').toUpperCase(),
            nome: r.nome,
            categoria: r.categoriaNome,
            producaoMensalPrevista: r.quantidadeProducaoMes,
            rateioDespesaPct: r.percentualRateioDespesa,
            margemLucroPct: r.percentualLucro,
            custoProducao: r.custoProducao,
            qtdProduzida: r.qtdProduzida,
            custoUnitario: r.custoUnitario,
            despesaFixaUn: r.despesaFixaPorUnidade,
            despesaVariavelUn: r.despesaVariavelPorUnidade,
            precoCalculado: base * ((r.percentualLucro / 100.0) + 1.0),
            precoDefinido: r.valorVendaDefinido,
            lucroAtualPct: (r.valorVendaDefinido == null || base == 0) ? null : ((r.valorVendaDefinido! / base) - 1.0) * 100.0,
            precoAtualizadoEm: r.dataAtualizacaoValorVenda,
          );
        }(),
    ];
    await showPdfPreviewDialog(
      context,
      titulo: 'Relatório de precificação',
      arquivo: 'precificacao',
      build: (format) => PrecificacaoPdfReport.build(
        format: format,
        empresa: empresa,
        filtroCategoria: filtroCategoria,
        filtroNome: filtroNome,
        linhas: linhas,
      ),
    );
  }

  Future<Map<int, double>> _computeCustoProducao(List<int> produtoIds) async {
    if (produtoIds.isEmpty) return const {};
    try {
      // Fórmula (por receita no produto): (receita.custoreceita / receita.qtdreceita) * produtoreceita.quantidadereceita.
      final dynamic prs = await SupabaseConfig.client
          .from('produtoreceita')
          .select('produtoid,quantidadereceita, receita:receitaid(custoreceita,qtdreceita)')
          .inFilter('produtoid', produtoIds)
          .limit(5000);

      final totals = <int, double>{};
      if (prs is List) {
        for (final pr in prs) {
          if (pr is! Map) continue;
          final produtoIdRaw = pr['produtoid'];
          if (produtoIdRaw is! num) continue;
          final produtoId = produtoIdRaw.toInt();

          final receita = pr['receita'] as Map?;
          final qtdUsada = parsePtBrNumber(pr['quantidadereceita']) ?? 0.0;
          final custoReceita = parsePtBrNumber(receita?['custoreceita']) ?? 0.0;
          final qtdReceitaTotal = parsePtBrNumber(receita?['qtdreceita']);
          if (qtdUsada <= 0) continue;
          if (qtdReceitaTotal == null || qtdReceitaTotal <= 0) continue;

          final inc = (custoReceita / qtdReceitaTotal) * qtdUsada;
          totals[produtoId] = (totals[produtoId] ?? 0.0) + inc;
        }
      }
      return totals;
    } catch (e) {
      debugPrint('PrecificacaoProdutos: compute custo producao failed: $e');
      return const {};
    }
  }

  Future<Map<int, double>> _computeDespesaFixaPorUnidade({required dynamic empresaId, required List<int> categoriaIds}) async {
    if (categoriaIds.isEmpty) return const {};
    try {
      // 1) Soma das despesas fixas mensais da empresa.
      final dynamic despesasRaw = await SupabaseConfig.client
          .from('despesafixa')
          .select('valormensal')
          .eq('empresaid', empresaId)
          .limit(5000);

      var somaDespesaFixaMensal = 0.0;
      if (despesasRaw is List) {
        for (final d in despesasRaw) {
          if (d is! Map) continue;
          somaDespesaFixaMensal += parsePtBrNumber(d['valormensal']) ?? 0.0;
        }
      }

      // 2) Buscar percentual de rateio e produção mensal por categoria.
      final dynamic catsRaw = await SupabaseConfig.client
          .from('categoria')
          .select('categoriaid,percentualrateiodespesa,quantidadeproducaomes')
          .inFilter('categoriaid', categoriaIds)
          .limit(5000);

      final result = <int, double>{};
      if (catsRaw is List) {
        for (final c in catsRaw) {
          if (c is! Map) continue;
          final idRaw = c['categoriaid'];
          if (idRaw is! num) continue;
          final categoriaId = idRaw.toInt();

          final percentual = parsePtBrNumber(c['percentualrateiodespesa']) ?? 0.0;
          final qtdProducaoMes = parsePtBrNumber(c['quantidadeproducaomes']) ?? 0.0;
          if (percentual <= 0 || qtdProducaoMes <= 0 || somaDespesaFixaMensal <= 0) {
            result[categoriaId] = 0.0;
            continue;
          }

          // Fórmula: soma(valormensal) * (percentualRateio/100) / quantidadeProducaoMes
          result[categoriaId] = somaDespesaFixaMensal * (percentual / 100.0) / qtdProducaoMes;
        }
      }

      return result;
    } catch (e) {
      debugPrint('PrecificacaoProdutos: compute despesa fixa unidade failed: $e');
      return const {};
    }
  }

  Future<Map<int, double>> _computeDespesaVariavelPorUnidade({required dynamic empresaId, required List<int> categoriaIds}) async {
    if (categoriaIds.isEmpty) return const {};
    try {
      // 1) Soma das despesas variáveis mensais da empresa.
      final dynamic despesasRaw = await SupabaseConfig.client
          .from('despesavariavel')
          .select('valormensal')
          .eq('empresaid', empresaId)
          .limit(5000);

      var somaDespesaVariavelMensal = 0.0;
      if (despesasRaw is List) {
        for (final d in despesasRaw) {
          if (d is! Map) continue;
          somaDespesaVariavelMensal += parsePtBrNumber(d['valormensal']) ?? 0.0;
        }
      }

      // 2) Buscar percentual de rateio e produção mensal por categoria.
      final dynamic catsRaw = await SupabaseConfig.client
          .from('categoria')
          .select('categoriaid,percentualrateiodespesa,quantidadeproducaomes')
          .inFilter('categoriaid', categoriaIds)
          .limit(5000);

      final result = <int, double>{};
      if (catsRaw is List) {
        for (final c in catsRaw) {
          if (c is! Map) continue;
          final idRaw = c['categoriaid'];
          if (idRaw is! num) continue;
          final categoriaId = idRaw.toInt();

          final percentual = parsePtBrNumber(c['percentualrateiodespesa']) ?? 0.0;
          final qtdProducaoMes = parsePtBrNumber(c['quantidadeproducaomes']) ?? 0.0;
          if (percentual <= 0 || qtdProducaoMes <= 0 || somaDespesaVariavelMensal <= 0) {
            result[categoriaId] = 0.0;
            continue;
          }

          // Fórmula: soma(valormensal) * (percentualRateio/100) / quantidadeProducaoMes
          result[categoriaId] = somaDespesaVariavelMensal * (percentual / 100.0) / qtdProducaoMes;
        }
      }

      return result;
    } catch (e) {
      debugPrint('PrecificacaoProdutos: compute despesa variavel unidade failed: $e');
      return const {};
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final media = MediaQuery.of(context);
    final isHandheldPlatform = !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
    // If the web app is opened on a narrow screen, we still prefer horizontal swipe.
    final isNarrowScreen = media.size.width < 650;
    final preferHorizontalPaging = isHandheldPlatform || isNarrowScreen;

    final String nomeFilter = _nomeFilter.trim().toLowerCase();
    final visibleRows = _rows
        .where((r) {
          if (_categoriaId != null && r.categoriaId != _categoriaId) return false;
          if (nomeFilter.isEmpty) return true;
          return r.nome.toLowerCase().contains(nomeFilter);
        })
        .toList(growable: false);
    final countLabel = _loadingList
        ? null
        : visibleRows.length == 1
            ? '1 item filtrado'
            : '${visibleRows.length} itens filtrados';

    // IMPORTANT: This page is rendered inside AppShell (ShellRoute).
    // So we avoid adding another Scaffold/AppBar here.
    // Also IMPORTANT: we avoid a parent vertical scroll view wrapping the PageView,
    // because that creates gesture conflicts where the "product header" appears to
    // disappear (the whole page scrolls instead of snapping to the next product).
    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          children: [
            // Top controls: allow them to scroll ONLY if the viewport is extremely short.
            Flexible(
              fit: FlexFit.loose,
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => context.go(AppRoutes.listas),
                          icon: const Icon(Icons.arrow_back_rounded),
                          tooltip: 'Voltar para Listas',
                        ),
                        const Spacer(),
                        OutlinedButton.icon(
                          onPressed: (_loadingCategorias || _loadingList || _error != null) ? null : () => _openPdf(visibleRows),
                          icon: Icon(Icons.picture_as_pdf_rounded, color: cs.primary),
                          label: Text('PDF', style: TextStyle(color: cs.primary)),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        IconButton(
                          onPressed: (_loadingCategorias || _loadingList) ? null : _load,
                          icon: const Icon(Icons.refresh_rounded),
                          tooltip: 'Atualizar',
                        ),
                      ],
                    ),
                    Text('Precificação de produtos', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: AppSpacing.sm),
                    _CategoriaFilter(
                      categorias: _categorias,
                      value: _categoriaId,
                      loading: _loadingCategorias,
                      onChanged: (v) {
                        setState(() {
                          _categoriaId = v;
                          _pageIndex = 0;
                        });
                        if (_pageController.hasClients) {
                          _pageController.jumpToPage(0);
                        }
                      },
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: _nomeFilterController,
                      onChanged: (v) {
                        setState(() => _nomeFilter = v);
                        _resetToFirstProduct();
                      },
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        labelText: 'Filtrar por produto',
                        hintText: 'Digite o nome do produto…',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _nomeFilter.trim().isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Limpar filtro',
                                onPressed: () {
                                  _nomeFilterController.clear();
                                  setState(() {
                                    _nomeFilter = '';
                                    _pageIndex = 0;
                                  });
                                  if (_pageController.hasClients) {
                                    _pageController.jumpToPage(0);
                                  }
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                      ),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: countLabel == null
                          ? const SizedBox.shrink()
                          : Padding(
                              key: ValueKey<String>(countLabel),
                              padding: const EdgeInsets.only(top: AppSpacing.xs),
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  countLabel,
                                  style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: _loadingList
                    ? const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
                    : _error != null
                        ? _ErrorState(message: _error!, onRetry: _load)
                        : visibleRows.isEmpty
                                ? const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 32, horizontal: 16),
                                    child: _EmptyState(
                                      icon: Icons.inventory_2_outlined,
                                      title: 'Nenhum produto encontrado',
                                      message: 'Não há produtos ativos para o filtro selecionado.',
                                    ),
                                  )
                                : LayoutBuilder(
                                    builder: (context, constraints) {
                                      final int safeIndex = _safePageIndex(visibleRows.length);
                                      final row = visibleRows[safeIndex];

                                       final isShortViewport = media.size.height < 740;
                                      final sellingPriceDefinedColor = theme.brightness == Brightness.dark
                                          ? AppStatusColors.sellingPriceDefinedDark
                                          : AppStatusColors.sellingPriceDefinedLight;

                                      Future<void> onEditProduto(_ProdutoPrecificacaoRow r) async {
                                        await context.push('${AppRoutes.cadastros}/produto/${r.produtoId}');
                                      }

                                      Future<void> onEditPrecoVenda(_ProdutoPrecificacaoRow r) async {
                                        final didSave = await context.push<bool>(
                                          '${AppRoutes.listasPrecificacaoProdutos}/${r.produtoId}/preco-venda',
                                          extra: {
                                            'produtoId': r.produtoId,
                                            'nome': r.nome,
                                            'percentualLucro': r.percentualLucro,
                                            'custoProdUn': r.custoUnitario,
                                            'despesaFixaUn': r.despesaFixaPorUnidade,
                                            'despesaVarUn': r.despesaVariavelPorUnidade,
                                            'valorVendaInicial': r.valorVendaDefinido,
                                          },
                                        );
                                        if (didSave == true && mounted) await _load();
                                      }

                                      return Padding(
                                        padding: EdgeInsets.symmetric(horizontal: 14, vertical: isShortViewport ? 9 : 11),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            // Option B: Sticky header (always visible while paging through products)
                                            _StickyHeaderSwitcher(
                                              key: ValueKey<int>(row.produtoId),
                                              child: _ProdutoPrecificacaoHeader(
                                                row: row,
                                                code: (row.codigo.isNotEmpty ? row.codigo : '#${row.produtoId}').toUpperCase(),
                                                descricao: row.descricao,
                                                positionText: visibleRows.length <= 0 ? '' : '${safeIndex + 1}/${visibleRows.length}',
                                                pillBackground: cs.tertiaryContainer,
                                                pillForeground: cs.onTertiaryContainer,
                                                producaoLabel: 'Produção mensal prevista ${_formatPtBrQty(row.quantidadeProducaoMes)}',
                                                rateioLabel: '% Rateio de despesa ${formatPtBrMoney(row.percentualRateioDespesa)}%',
                                                lucroLabel: 'Margem de lucro ${formatPtBrMoney(row.percentualLucro)}%',
                                                hasCategoria: row.categoriaNome.isNotEmpty,
                                                onEditProduto: () => onEditProduto(row),
                                                onEditPrecoVenda: () => onEditPrecoVenda(row),
                                              ),
                                            ),
                                            SizedBox(height: isShortViewport ? 6 : 8),
                                            Expanded(
                                              child: Listener(
                                                behavior: HitTestBehavior.translucent,
                                                onPointerSignal: (event) {
                                                   if (!preferHorizontalPaging && event is PointerScrollEvent) {
                                                     _handleMouseWheel(event, visibleRows.length);
                                                   }
                                                },
                                                 child: preferHorizontalPaging
                                                     ? PageView.builder(
                                                         controller: _pageController,
                                                         scrollDirection: Axis.horizontal,
                                                         physics: const PageScrollPhysics(),
                                                         onPageChanged: (i) => setState(() => _pageIndex = i),
                                                         itemCount: visibleRows.length,
                                                         itemBuilder: (context, index) {
                                                           final r = visibleRows[index];
                                                           return Align(
                                                             alignment: Alignment.topCenter,
                                                             child: LayoutBuilder(
                                                               builder: (context, c) {
                                                                 final baseVenda = r.custoUnitario + r.despesaFixaPorUnidade + r.despesaVariavelPorUnidade;
                                                                 final precoVendaCalculado = baseVenda * ((r.percentualLucro / 100.0) + 1.0);
                                                                 final double? lucroAtualPercent = (r.valorVendaDefinido == null || baseVenda == 0)
                                                                     ? null
                                                                     : ((r.valorVendaDefinido! / baseVenda) - 1.0) * 100.0;
                                                                 final String lucroAtualText = lucroAtualPercent == null
                                                                     ? '—'
                                                                     : '${lucroAtualPercent >= 0 ? '+' : '-'}${formatPtBrMoney(lucroAtualPercent.abs())}%';
                                                                 final Color? lucroAtualColor = lucroAtualPercent == null ? null : sellingPriceDefinedColor;
                                                                 final FontWeight? lucroAtualWeight = lucroAtualPercent == null ? null : FontWeight.w800;

                                                                 return _ProdutoPrecificacaoMetrics(
                                                                   availableHeight: c.maxHeight,
                                                                   row: r,
                                                                   qtd: r.qtdProduzida,
                                                                   precoVendaCalculado: precoVendaCalculado,
                                                                   sellingPriceDefinedColor: sellingPriceDefinedColor,
                                                                   lucroAtualText: lucroAtualText,
                                                                   lucroAtualColor: lucroAtualColor,
                                                                   lucroAtualWeight: lucroAtualWeight,
                                                                   isShortViewport: isShortViewport,
                                                                 );
                                                               },
                                                             ),
                                                           );
                                                         },
                                                       )
                                                     : GestureDetector(
                                                         behavior: HitTestBehavior.opaque,
                                                         onVerticalDragEnd: (d) {
                                                           // Keep it "marcado": one product per gesture.
                                                           final v = d.primaryVelocity ?? 0.0;
                                                           if (v.abs() < 220) return;
                                                           if (v < 0) {
                                                             _next(visibleRows.length);
                                                           } else {
                                                             _prev(visibleRows.length);
                                                           }
                                                         },
                                                         child: PageView.builder(
                                                           controller: _pageController,
                                                           scrollDirection: Axis.vertical,
                                                           // We control navigation to avoid "sometimes jumps many" on mouse wheel / trackpad.
                                                           physics: const NeverScrollableScrollPhysics(),
                                                           onPageChanged: (i) => setState(() => _pageIndex = i),
                                                           itemCount: visibleRows.length,
                                                           itemBuilder: (context, index) {
                                                             final r = visibleRows[index];
                                                             return Align(
                                                               alignment: Alignment.topCenter,
                                                               child: LayoutBuilder(
                                                                 builder: (context, c) {
                                                                   final baseVenda = r.custoUnitario + r.despesaFixaPorUnidade + r.despesaVariavelPorUnidade;
                                                                   final precoVendaCalculado = baseVenda * ((r.percentualLucro / 100.0) + 1.0);
                                                                   final double? lucroAtualPercent = (r.valorVendaDefinido == null || baseVenda == 0)
                                                                       ? null
                                                                       : ((r.valorVendaDefinido! / baseVenda) - 1.0) * 100.0;
                                                                   final String lucroAtualText = lucroAtualPercent == null
                                                                       ? '—'
                                                                       : '${lucroAtualPercent >= 0 ? '+' : '-'}${formatPtBrMoney(lucroAtualPercent.abs())}%';
                                                                   final Color? lucroAtualColor = lucroAtualPercent == null ? null : sellingPriceDefinedColor;
                                                                   final FontWeight? lucroAtualWeight = lucroAtualPercent == null ? null : FontWeight.w800;

                                                                   return _ProdutoPrecificacaoMetrics(
                                                                     availableHeight: c.maxHeight,
                                                                     row: r,
                                                                     qtd: r.qtdProduzida,
                                                                     precoVendaCalculado: precoVendaCalculado,
                                                                     sellingPriceDefinedColor: sellingPriceDefinedColor,
                                                                     lucroAtualText: lucroAtualText,
                                                                     lucroAtualColor: lucroAtualColor,
                                                                     lucroAtualWeight: lucroAtualWeight,
                                                                     isShortViewport: isShortViewport,
                                                                   );
                                                                 },
                                                               ),
                                                             );
                                                           },
                                                         ),
                                                       ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StickyHeaderSwitcher extends StatelessWidget {
  const _StickyHeaderSwitcher({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        final offsetTween = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero);
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(position: anim.drive(offsetTween), child: child),
        );
      },
      child: child,
    );
  }
}

class _CategoriaFilter extends StatelessWidget {
  const _CategoriaFilter({required this.categorias, required this.value, required this.loading, required this.onChanged});
  final List<_CategoriaOption> categorias;
  final int? value;
  final bool loading;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int?>(
      value: value,
      onChanged: loading ? null : onChanged,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Categoria do produto',
        prefixIcon: Icon(Icons.filter_alt_outlined),
      ),
      items: [
        if (loading) const DropdownMenuItem<int?>(value: null, enabled: false, child: Text('Carregando categorias...')),
        // TODOS = todas as categorias (padrão).
        if (!loading) const DropdownMenuItem<int?>(value: null, child: Text('TODOS')),
        if (!loading) ...categorias.map((c) => DropdownMenuItem<int?>(value: c.id, child: Text(c.nome))),
      ],
    );
  }
}

class _ProdutoPrecificacaoTile extends StatelessWidget {
  const _ProdutoPrecificacaoTile({required this.row, required this.index, required this.total, required this.onEditPrecoVenda});
  final _ProdutoPrecificacaoRow row;
  final int index;
  final int total;
  final VoidCallback onEditPrecoVenda;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final code = (row.codigo.isNotEmpty ? row.codigo : '#${row.produtoId}').toUpperCase();
    final descricao = row.descricao;
    final qtd = row.qtdProduzida;

    final isShortViewport = MediaQuery.sizeOf(context).height < 740;

    final sellingPriceDefinedColor = theme.brightness == Brightness.dark
        ? AppStatusColors.sellingPriceDefinedDark
        : AppStatusColors.sellingPriceDefinedLight;

    final baseVenda = row.custoUnitario + row.despesaFixaPorUnidade + row.despesaVariavelPorUnidade;
    final precoVendaCalculado = baseVenda * ((row.percentualLucro / 100.0) + 1.0);

    // Lucro atual (%): baseado no preço de venda definido versus a base unitária (custo + despesas unitárias).
    // Fórmula: ((preço_venda_definido) / (custo_un + desp_fixa_un + desp_var_un) - 1) * 100
    final double? lucroAtualPercent = (row.valorVendaDefinido == null || baseVenda == 0)
        ? null
        : ((row.valorVendaDefinido! / baseVenda) - 1.0) * 100.0;

    final String lucroAtualText = lucroAtualPercent == null
        ? '—'
        : '${lucroAtualPercent >= 0 ? '+' : '-'}${formatPtBrMoney(lucroAtualPercent.abs())}%';

    // Keep the same visual language as "Preço venda definido" (user request):
    // the percentage may be positive/negative, but we keep the same accent color.
    final Color? lucroAtualColor = lucroAtualPercent == null ? null : sellingPriceDefinedColor;
    final FontWeight? lucroAtualWeight = lucroAtualPercent == null ? null : FontWeight.w800;

    final hasCategoria = row.categoriaNome.isNotEmpty;
    final producaoLabel = 'Produção mensal prevista ${_formatPtBrQty(row.quantidadeProducaoMes)}';
    final rateioLabel = '% Rateio de despesa ${formatPtBrMoney(row.percentualRateioDespesa)}%';
    final lucroLabel = 'Margem de lucro ${formatPtBrMoney(row.percentualLucro)}%';

    // User request: make ALL pills in the first line match the Categoria pill colors.
    final pillBackground = cs.tertiaryContainer;
    final pillForeground = cs.onTertiaryContainer;

    final positionText = total <= 0 ? '' : '${index + 1}/$total';

    Future<void> onEditProduto() async {
      // Editar o cadastro do produto (padronização com outras telas)
      await context.push('${AppRoutes.cadastros}/produto/${row.produtoId}');
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: isShortViewport ? 9 : 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ProdutoPrecificacaoHeader(
            row: row,
            code: code,
            descricao: descricao,
            positionText: positionText,
            pillBackground: pillBackground,
            pillForeground: pillForeground,
            producaoLabel: producaoLabel,
            rateioLabel: rateioLabel,
            lucroLabel: lucroLabel,
            hasCategoria: hasCategoria,
            onEditProduto: onEditProduto,
            onEditPrecoVenda: onEditPrecoVenda,
          ),
          SizedBox(height: isShortViewport ? 6 : 8),
          // IMPORTANT: avoid vertical scrolling inside the page.
          // Vertical scroll gestures should always move to the next/previous product (PageView).
          // So we keep the header compact and make the metrics fit in the remaining height.
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => _ProdutoPrecificacaoMetrics(
                availableHeight: c.maxHeight,
                row: row,
                qtd: qtd,
                precoVendaCalculado: precoVendaCalculado,
                sellingPriceDefinedColor: sellingPriceDefinedColor,
                lucroAtualText: lucroAtualText,
                lucroAtualColor: lucroAtualColor,
                lucroAtualWeight: lucroAtualWeight,
                isShortViewport: isShortViewport,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProdutoPrecificacaoHeader extends StatelessWidget {
  const _ProdutoPrecificacaoHeader({
    required this.row,
    required this.code,
    required this.descricao,
    required this.positionText,
    required this.pillBackground,
    required this.pillForeground,
    required this.producaoLabel,
    required this.rateioLabel,
    required this.lucroLabel,
    required this.hasCategoria,
    required this.onEditProduto,
    required this.onEditPrecoVenda,
  });

  final _ProdutoPrecificacaoRow row;
  final String code;
  final String descricao;
  final String positionText;
  final Color pillBackground;
  final Color pillForeground;
  final String producaoLabel;
  final String rateioLabel;
  final String lucroLabel;
  final bool hasCategoria;
  final Future<void> Function() onEditProduto;
  final VoidCallback onEditPrecoVenda;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isShortViewport = MediaQuery.sizeOf(context).height < 740;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        InkWell(
                          onTap: onEditPrecoVenda,
                          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                          child: Text(
                            row.nome,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w900,
                              height: 1.1,
                              color: cs.primary,
                              decoration: TextDecoration.underline,
                              decorationColor: cs.primary.withValues(alpha: 0.35),
                            ),
                          ),
                        ),
                        // Card "Categoria" em verde (mesmo padrão da classificação na lista de kits).
                        if (hasCategoria)
                          _Pill(
                            text: 'Categoria: ${row.categoriaNome}',
                            background: Colors.green.shade700,
                            foreground: Colors.white,
                            dense: true,
                          ),
                      ],
                    ),
                  ),
                  if (positionText.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    _Pill(text: positionText, background: cs.secondaryContainer, foreground: cs.onSecondaryContainer, dense: true),
                  ],
                  const SizedBox(width: 10),
                  _HorizontalScrollRow(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => onEditProduto(),
                        icon: const Icon(Icons.edit_rounded, size: 18),
                        label: const Text('Editar'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: onEditPrecoVenda,
                        icon: const Icon(Icons.price_change_outlined, size: 18),
                        label: const Text('Editar preço de venda'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (descricao.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(descricao, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.35)),
              ],
              SizedBox(height: isShortViewport ? 6 : 8),
              _HorizontalScrollRow(
                spacing: 8,
                children: [
                  _Pill(text: code, background: pillBackground, foreground: pillForeground, dense: true),
                  if (hasCategoria) _Pill(text: producaoLabel, background: pillBackground, foreground: pillForeground, dense: true),
                  if (hasCategoria) _Pill(text: rateioLabel, background: pillBackground, foreground: pillForeground, dense: true),
                  if (hasCategoria) _Pill(text: lucroLabel, background: pillBackground, foreground: pillForeground, dense: true),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HorizontalScrollRow extends StatelessWidget {
  const _HorizontalScrollRow({required this.children, this.spacing = 8});
  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      child: Row(
        children: [
          for (final c in children) ...[c, SizedBox(width: spacing)],
        ]..removeLast(),
      ),
    );
  }
}

class _ProdutoPrecificacaoMetrics extends StatelessWidget {
  const _ProdutoPrecificacaoMetrics({
    required this.availableHeight,
    required this.row,
    required this.qtd,
    required this.precoVendaCalculado,
    required this.sellingPriceDefinedColor,
    required this.lucroAtualText,
    required this.lucroAtualColor,
    required this.lucroAtualWeight,
    required this.isShortViewport,
  });

  final double availableHeight;
  final _ProdutoPrecificacaoRow row;
  final double qtd;
  final double precoVendaCalculado;
  final Color sellingPriceDefinedColor;
  final String lucroAtualText;
  final Color? lucroAtualColor;
  final FontWeight? lucroAtualWeight;
  final bool isShortViewport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 720;
        final rowGap = isShortViewport ? 4.0 : 6.0;
        // A tiny rounding difference (font metrics, devicePixelRatio, etc.) can trigger
        // RenderFlex overflow by a few pixels even when the math seems exact.
        // We keep a small safety margin to guarantee both metric rows fit.
        final safetyPx = isShortViewport ? 10.0 : 8.0;
        // Keep both metric lines fully visible without requiring vertical scroll.
        // We split the available height across the 2 lines.
        // IMPORTANT: perRowHeight must NEVER exceed the real per-row space.
        // Otherwise even a few pixels can trigger the yellow overflow bar.
        final rawPerRow = (availableHeight - rowGap - safetyPx) / 2;
        final perRowHeight = (rawPerRow.isFinite ? rawPerRow : 72.0).clamp(0.0, 92.0);
        final firstLine = [
          _Metric(height: perRowHeight, label: 'Custo de produção', value: formatPtBrCurrency(row.custoProducao), dense: true),
          _Metric(
            height: perRowHeight,
            label: 'Qtd produzida',
            value: qtd % 1 == 0 ? qtd.toStringAsFixed(0) : formatPtBrMoney(qtd),
            dense: true,
          ),
          _Metric(height: perRowHeight, label: 'Custo produção / un.', value: formatPtBrCurrency(row.custoUnitario), dense: true),
          _Metric(height: perRowHeight, label: 'Despesa fixa / un.', value: formatPtBrCurrency(row.despesaFixaPorUnidade), dense: true),
          _Metric(height: perRowHeight, label: 'Despesa variável / un.', value: formatPtBrCurrency(row.despesaVariavelPorUnidade), dense: true),
        ];

        final secondLine = [
          _Metric(height: perRowHeight, label: 'Preço venda calculado R\$/un.', value: formatPtBrCurrency(precoVendaCalculado), dense: true),
          _Metric(
            height: perRowHeight,
            label: 'Preço venda definido R\$/un.',
            value: row.valorVendaDefinido == null ? '—' : formatPtBrCurrency(row.valorVendaDefinido!),
            labelColor: cs.onSurfaceVariant,
            valueColor: sellingPriceDefinedColor,
            dense: true,
          ),
          _Metric(
            height: perRowHeight,
            label: 'Lucro atual - %',
            value: lucroAtualText,
            labelColor: cs.onSurfaceVariant,
            valueColor: lucroAtualColor,
            valueWeight: lucroAtualWeight,
            dense: true,
          ),
          _Metric(
            height: perRowHeight,
            label: 'Preço venda atualizado em',
            value: row.dataAtualizacaoValorVenda == null ? '—' : _formatPtBrDateTime(row.dataAtualizacaoValorVenda!),
            dense: true,
          ),
        ];

        if (isNarrow) {
          return Column(
            children: [
              SizedBox(height: perRowHeight, child: _MetricHorizontalRow(children: firstLine, dense: true)),
              SizedBox(height: rowGap),
              SizedBox(height: perRowHeight, child: _MetricHorizontalRow(children: secondLine, dense: true)),
            ],
          );
        }

        return Column(
          children: [
            Row(
              children: [
                for (final c in firstLine) ...[Expanded(child: c), const SizedBox(width: 10)],
              ]..removeLast(),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final c in secondLine) ...[Expanded(child: c), const SizedBox(width: 10)],
              ]..removeLast(),
            ),
          ],
        );
      },
    );
  }
}

/// In narrow layouts (phones), keep a stable 2-row height by making each row
/// horizontally scrollable instead of stacking every metric vertically.
class _MetricHorizontalRow extends StatelessWidget {
  const _MetricHorizontalRow({required this.children, this.dense = false});
  final List<Widget> children;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth * (dense ? 0.58 : 0.62)).clamp(164.0, 240.0);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final c in children) ...[SizedBox(width: itemWidth, child: c), const SizedBox(width: 10)],
            ]..removeLast(),
          ),
        );
      },
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.height, this.labelColor, this.valueColor, this.valueWeight, this.dense = false});
  final String label;
  final String value;
  final double? height;
  final Color? labelColor;
  final Color? valueColor;
  final FontWeight? valueWeight;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final h = height ?? 72.0;
    // Important: this widget is used inside a fixed-height row.
    // Even tiny rounding differences in font metrics can trigger overflows by 1-2px.
    // So we keep padding + font sizes slightly conservative.
    final vPad = math.max(2.0, math.min(dense ? 5.0 : 7.0, h * 0.10));
    final hPad = dense ? 10.0 : 12.0;
    final labelFont = math.min(dense ? 10.0 : 11.5, math.max(8.5, h * 0.20));
    final valueFont = math.min(dense ? 13.5 : 15.0, math.max(11.0, h * 0.30));
    final gap = math.max(1.0, math.min(4.0, h * 0.035));

    return SizedBox(
      height: height,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: labelColor ?? cs.onSurfaceVariant,
                    height: 1.0,
                    fontSize: labelFont,
                  ),
                ),
              ),
              SizedBox(height: gap),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (dense ? theme.textTheme.titleSmall : theme.textTheme.titleMedium)?.copyWith(
                    fontWeight: valueWeight ?? FontWeight.w800,
                    color: valueColor ?? cs.onSurface,
                    height: 1.0,
                    fontSize: valueFont,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

DateTime? _parseLooseDateTime(dynamic raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  if (raw is String) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    try {
      return DateTime.parse(s);
    } catch (_) {
      return null;
    }
  }
  return null;
}

String _formatPtBrDateTime(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
}

String _formatPtBrQty(double? v) {
  if (v == null || v <= 0) return '—';
  return v % 1 == 0 ? v.toStringAsFixed(0) : formatPtBrMoney(v);
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.background, required this.foreground, this.dense = false});
  final String text;
  final Color background;
  final Color foreground;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 9 : 10, vertical: dense ? 5 : 6),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(999)),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground, fontWeight: FontWeight.w700, height: 1.15),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, color: cs.error, size: 28),
            const SizedBox(height: 10),
            Text('Não foi possível carregar', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(message, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.35), textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('Tentar novamente')),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.message});
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: cs.onSurfaceVariant, size: 28),
            const SizedBox(height: 10),
            Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800), textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(message, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.35), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _CategoriaOption {
  const _CategoriaOption({required this.id, required this.nome});
  final int id;
  final String nome;
}

class _ProdutoPrecificacaoRow {
  const _ProdutoPrecificacaoRow({
    required this.produtoId,
    required this.codigo,
    required this.nome,
    required this.descricao,
    required this.categoriaId,
    required this.categoriaNome,
    required this.quantidadeProducaoMes,
    required this.percentualRateioDespesa,
    required this.percentualLucro,
    required this.custoProducao,
    required this.qtdProduzida,
    required this.custoUnitario,
    required this.despesaFixaPorUnidade,
    required this.despesaVariavelPorUnidade,
    required this.valorVendaDefinido,
    required this.dataAtualizacaoValorVenda,
  });

  final int produtoId;
  final String codigo;
  final String nome;
  final String descricao;
  final int? categoriaId;
  final String categoriaNome;
  final double? quantidadeProducaoMes;
  final double percentualRateioDespesa;
  final double percentualLucro;
  final double custoProducao;
  final double qtdProduzida;
  final double custoUnitario;
  final double despesaFixaPorUnidade;
  final double despesaVariavelPorUnidade;
  final double? valorVendaDefinido;
  final DateTime? dataAtualizacaoValorVenda;
}
