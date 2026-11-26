import 'package:bakepro/pages/cadastros/cadastro_definitions.dart';
import 'package:bakepro/pages/cadastros/generic_cadastro_form_sheet.dart';
import 'package:bakepro/services/receita_service.dart';
import 'package:bakepro/services/kit_service.dart';
import 'package:bakepro/services/relatorios/item_pdf_report.dart';
import 'package:bakepro/services/relatorios/kit_pdf_report.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:bakepro/components/info_pill.dart';
import 'package:bakepro/components/pdf_preview_dialog.dart';
import 'package:bakepro/services/totaldespesas_service.dart';
import 'package:bakepro/services/fk_delete_guard.dart';
import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/theme.dart';
import 'package:bakepro/components/stacked_list_actions.dart';
import 'package:bakepro/components/confirm_delete_sheet.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:bakepro/utils/text_normalization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:bakepro/route_observer.dart';
import 'package:provider/provider.dart';

class GenericCadastroListPage extends StatefulWidget {
  const GenericCadastroListPage({
    super.key,
    required this.definition,
    this.openCreateOnLoad = false,
    this.backLocation,
    this.extraFilters,
    this.createForcedValues,
    this.createHiddenColumns = const <String>{},
    this.createReadOnlyColumns = const <String>{},
  });

  final CadastroDefinition definition;
  final bool openCreateOnLoad;

  /// Optional override for where the back arrow should go.
  /// Example: when opened from Compras, it should return to '/compras'.
  final String? backLocation;

  /// Optional additional filters, useful for nested lists.
  /// Example: {'receitaid': 123}
  final Map<String, dynamic>? extraFilters;

  /// Values to force on create (and prefill if possible).
  final Map<String, dynamic>? createForcedValues;

  final Set<String> createHiddenColumns;
  final Set<String> createReadOnlyColumns;

  @override
  State<GenericCadastroListPage> createState() => _GenericCadastroListPageState();
}

class _GenericCadastroListPageState extends State<GenericCadastroListPage> with RouteAware {
  bool _isLoading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = const [];
  List<Map<String, dynamic>> _filteredRows = const [];
  List<Map<String, dynamic>> _produtoFilteredRows = const [];
  List<Map<String, dynamic>> _itemFilteredRows = const [];
  bool _openedInitialCreate = false;
  int? _contextReceitaId;
  String? _contextReceitaNome;

  num? _empresaSetupImpostoPct;
  num? _empresaSetupTaxaMotoboyPct;
  // Kit: deliveries ativos (empresadelivery.status = 'A') da empresa logada.
  List<_KitDelivery> _kitDeliveries = const [];
  // Controlador compartilhado entre o Scrollbar e a lista (no navegador o Scrollbar
  // não encontra a lista sozinho e gera erros no console).
  final ScrollController _listScrollController = ScrollController();
  // Kit: classificações da empresa logada (filtro da lista) e filtro selecionado (null = TODOS).
  List<Map<String, dynamic>> _kitClassificacoes = const [];
  int? _kitClassificacaoFiltroId;

  final TextEditingController _receitaSearchController = TextEditingController();
  String _receitaSearchQuery = '';

  final TextEditingController _produtoSearchController = TextEditingController();
  String _produtoSearchQuery = '';

  final TextEditingController _itemSearchController = TextEditingController();
  String _itemSearchQuery = '';
  // Item: tipos (tabela tipoitem) para o filtro e tipo selecionado (null = TODOS).
  List<Map<String, dynamic>> _itemTipos = const [];
  int? _itemTipoFiltroId;

  // Produto list: computed from produtoreceita + receita (same formula used in ProdutoCascadePage).
  // Stored directly in each row as "_custo_producao".

  // Used to debounce auto refresh when this page regains focus.
  DateTime? _lastAutoRefresh;

  num? _totalDespesaVariavel;
  num? _totalDespesaFixa;
  num? _totalCategoriaRateio;
  num? _totalCustoIngredientesReceita;
  num? _totalCustoMateriaisReceita;
  int? _empresaIdForDebug;

  Widget _buildEmpresaDeliveryGroupedList({required List<Map<String, dynamic>> rows}) {
    final cs = Theme.of(context).colorScheme;

    String empresaLabelForRow(Map<String, dynamic> row) {
      final empresaNome = row['empresa'] is Map
          ? (row['empresa'] as Map)['nomefantasia']?.toString().trim()
          : (row['empresa'] is List && (row['empresa'] as List).isNotEmpty && (row['empresa'] as List).first is Map
              ? ((row['empresa'] as List).first as Map)['nomefantasia']?.toString().trim()
              : null);
      final empresaId = row['empresaid'];
      final label = (empresaNome ?? '').trim();
      if (label.isNotEmpty && label != 'null') return label;
      return empresaId != null ? 'Empresa #$empresaId' : 'Empresa';
    }

    String deliveryLabelForRow(Map<String, dynamic> row) {
      final deliveryNome = row['delivery'] is Map
          ? (row['delivery'] as Map)['nome']?.toString().trim()
          : (row['delivery'] is List && (row['delivery'] as List).isNotEmpty && (row['delivery'] as List).first is Map
              ? ((row['delivery'] as List).first as Map)['nome']?.toString().trim()
              : null);
      final deliveryId = row['deliveryid'];
      final label = (deliveryNome ?? '').trim();
      if (label.isNotEmpty && label != 'null') return label;
      return deliveryId != null ? 'Delivery #$deliveryId' : 'Delivery';
    }

    String statusLabelForRow(Map<String, dynamic> row) {
      final raw = (row['status'] ?? '').toString().trim().toUpperCase();
      if (raw == 'A') return 'Ativo';
      if (raw == 'I') return 'Inativo';
      return raw.isEmpty ? '—' : raw;
    }

    String taxaLabelForRow(Map<String, dynamic> row) {
      final taxa = _formatPtBrCurrencyWithThousands(row['taxadelivery']) ?? row['taxadelivery']?.toString();
      final txt = (taxa ?? '').trim();
      return txt.isEmpty || txt == 'null' ? '—' : '$txt%';
    }

    final groups = <int, List<Map<String, dynamic>>>{};
    final groupLabels = <int, String>{};
    final unknownKey = -1;

    for (final r in rows) {
      final empresaIdRaw = r['empresaid'];
      final empresaId = empresaIdRaw is num ? empresaIdRaw.toInt() : int.tryParse(empresaIdRaw?.toString() ?? '');
      final key = empresaId ?? unknownKey;
      (groups[key] ??= <Map<String, dynamic>>[]).add(r);
      groupLabels[key] ??= empresaLabelForRow(r);
    }

    final orderedKeys = groups.keys.toList(growable: false)
      ..sort((a, b) => (groupLabels[a] ?? '').toLowerCase().compareTo((groupLabels[b] ?? '').toLowerCase()));

    return ListView.separated(
      controller: _listScrollController,
      itemCount: orderedKeys.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, idx) {
        final key = orderedKeys[idx];
        final label = groupLabels[key] ?? 'Empresa';
        final items = groups[key]!
          ..sort((a, b) {
            final da = deliveryLabelForRow(a).trim().toLowerCase();
            final db = deliveryLabelForRow(b).trim().toLowerCase();
            return da.compareTo(db);
          });

        final canQuickAddForThisEmpresa = widget.definition.keyName == 'empresadelivery' && key != unknownKey;

        return DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.25)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Text(
                          '${items.length} ${items.length == 1 ? 'delivery' : 'deliveries'}',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    if (canQuickAddForThisEmpresa) ...[
                      const SizedBox(width: AppSpacing.sm),
                      TextButton.icon(
                        onPressed: () => _openCreateForEmpresaDelivery(empresaId: key),
                        style: ButtonStyle(
                          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                          minimumSize: const WidgetStatePropertyAll(Size(0, 0)),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg))),
                          backgroundColor: WidgetStatePropertyAll(cs.primary.withValues(alpha: 0.10)),
                          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                        ),
                        icon: Icon(Icons.add_rounded, size: 18, color: cs.primary),
                        label: Text('Adicionar delivery', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.primary, fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                ListView.separated(
                  itemCount: items.length,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.xs),
                  itemBuilder: (context, i) {
                    final row = items[i];
                    final deliveryLabel = deliveryLabelForRow(row);
                    final taxaLabel = taxaLabelForRow(row);
                    final statusLabel = statusLabelForRow(row);
                    final isInativo = (row['status'] ?? '').toString().trim().toUpperCase() == 'I';

                    return DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest.withValues(alpha: 0.28),
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.22)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                        child: Row(
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
                                        child: Text(
                                          deliveryLabel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                        ),
                                      ),
                                      if (isInativo) ...[
                                        const SizedBox(width: AppSpacing.sm),
                                        const _StatusBadge(text: 'INATIVO'),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Taxa: $taxaLabel • Status: $statusLabel',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            _RowActions(
                              definition: widget.definition,
                              row: row,
                              onEdit: () => _openEdit(row),
                              onDelete: () => _delete(row),
                              onRefreshRequested: _load,
                              horizontal: false,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatItemsCount(int count) => count == 1 ? '1 item' : '$count itens';

  String _formatPtBrFixedDecimals(num value, int decimals) {
    final s = value.toStringAsFixed(decimals);
    return s.replaceAll('.', ',');
  }

  String? _formatPtBrNumber(Object? value) {
    if (value == null) return null;
    if (value is num) {
      final decimals = value % 1 == 0 ? 0 : 2;
      return _formatPtBrFixedDecimals(value, decimals);
    }
    final parsed = num.tryParse(value.toString());
    if (parsed != null) {
      final decimals = parsed % 1 == 0 ? 0 : 2;
      return _formatPtBrFixedDecimals(parsed, decimals);
    }
    return value.toString().replaceAll('.', ',');
  }

  num? _sumCustoIngredientesReceita(List<Map<String, dynamic>> rows, {int? receitaIdForDebug}) {
    if (rows.isEmpty) return 0;

    // Important: sum using integer cents to avoid floating point drift and
    // to match the per-row UI rounding (2 decimals). This prevents cases where
    // the header total differs slightly from the visible sum of the list.
    var totalCents = 0;

    final debugLines = <String>[];

    for (final row in rows) {
      num? custoIng;
      final stored = row['custoingrediente'];
      custoIng = parsePtBrNumber(stored);

      final storedIsZero = (custoIng != null && custoIng == 0);

      if (custoIng == null || storedIsZero) {
        // Fallback: item.custounitario * ingrediente.quantidadegrama
        num? custoUnit;
        final item = row['item'];
        if (item is Map) {
          final raw = item['custounitario'];
          custoUnit = parsePtBrNumber(raw);
        }

        final qtyRaw = row['quantidadegrama'];
        final qtyNum = parsePtBrNumber(qtyRaw);
        if (custoUnit != null && qtyNum != null) {
          final computed = custoUnit * qtyNum;
          if (custoIng == null || (storedIsZero && computed > 0)) custoIng = computed;
        }
      }

      if (custoIng != null) {
        // Round each row to cents (same as money formatting) before summing.
        // This is the behavior users expect when they manually add the list.
        final cents = (custoIng * 100).round();
        totalCents += cents;

        if (kDebugMode && receitaIdForDebug != null) {
          final ingredienteId = row['ingredienteid'];
          final itemId = row['itemid'];
          final qty = row['quantidadegrama'];
          debugLines.add('ingredienteid=$ingredienteId itemid=$itemId qty=$qty custoingrediente=$stored -> cents=$cents');
        }
      }
    }

    if (kDebugMode && receitaIdForDebug != null) {
      debugPrint(
        'Total custo ingredientes (receitaid=$receitaIdForDebug) rows=${rows.length}:\n'
        '${debugLines.join('\n')}\n'
        'TOTAL_CENTS=$totalCents',
      );
    }

    return totalCents / 100;
  }

  Future<num?> _loadReceitaCustoTotalIngrediente({required int receitaId, required int? empresaId}) async {
    try {
      // receitaid is the PK. Avoid filtering by empresaid here to prevent
      // returning null when empresaId is not in sync (typed differently).
      final row = await SupabaseService.selectSingle('receita', select: 'custototalingrediente', filters: {'receitaid': receitaId});
      return parsePtBrNumber(row?['custototalingrediente']);
    } catch (e) {
      debugPrint('Failed to load receita.custototalingrediente for receitaId=$receitaId: $e');
      return null;
    }
  }

  Future<num?> _loadReceitaCustoTotalMaterial({required int receitaId, required int? empresaId}) async {
    try {
      // receitaid is the PK. Avoid filtering by empresaid here to prevent
      // returning null when empresaId is not in sync (typed differently).
      final row = await SupabaseService.selectSingle('receita', select: 'custototalmaterial', filters: {'receitaid': receitaId});
      return parsePtBrNumber(row?['custototalmaterial']);
    } catch (e) {
      debugPrint('Failed to load receita.custototalmaterial for receitaId=$receitaId: $e');
      return null;
    }
  }

  num? _sumCustoMateriaisReceita(List<Map<String, dynamic>> rows, {int? receitaIdForDebug}) {
    if (rows.isEmpty) return 0;

    var totalCents = 0;
    final debugLines = <String>[];

    for (final row in rows) {
      num? custoMat;
      final stored = row['customaterial'];
      custoMat = parsePtBrNumber(stored);

      // If backend stored 0 due to older logic (e.g. using a null custounitario),
      // recompute from the item cost when we can.
      final storedIsZero = (custoMat != null && custoMat == 0);

      if (custoMat == null || storedIsZero) {
        // Fallback: item.custounitario * material.quantidade
        num? custoUnit;
        final item = row['item'];
        if (item is Map) {
          final raw = item['custounitario'];
          custoUnit = parsePtBrNumber(raw);
        }

        final qtyRaw = row['quantidade'];
        final qtyNum = parsePtBrNumber(qtyRaw);
        if (custoUnit != null && qtyNum != null) {
          final computed = custoUnit * qtyNum;
          // Only override the stored value when it is clearly wrong (0) and computed is > 0.
          if (custoMat == null || (storedIsZero && computed > 0)) custoMat = computed;
        }
      }

      if (custoMat != null) {
        final cents = (custoMat * 100).round();
        totalCents += cents;

        if (kDebugMode && receitaIdForDebug != null) {
          final materialId = row['materialid'];
          final itemId = row['itemid'];
          final qty = row['quantidade'];
          debugLines.add('materialid=$materialId itemid=$itemId qty=$qty customaterial=$stored -> cents=$cents');
        }
      }
    }

    if (kDebugMode && receitaIdForDebug != null) {
      debugPrint(
        'Total custo materiais (receitaid=$receitaIdForDebug) rows=${rows.length}:\n'
        '${debugLines.join('\n')}\n'
        'TOTAL_CENTS=$totalCents',
      );
    }

    return totalCents / 100.0;
  }

  Future<double> _sumCategoriaRateioPercent(int empresaId) async {
    // Evita `.sum()` por conta do erro PGRST123 (agregações bloqueadas no PostgREST).
    // Então buscamos os registros e somamos no Dart.
    const pageSize = 1000;
    var from = 0;
    var total = 0.0;
    var rowsFetched = 0;

    while (true) {
      final dynamic page = await SupabaseConfig.client
          .from('categoria')
          .select('percentualrateiodespesa')
          .eq('empresaid', empresaId)
          .range(from, from + pageSize - 1);

      if (page is! List || page.isEmpty) break;
      rowsFetched += page.length;

      for (final r in page) {
        if (r is! Map) continue;
        final raw = r['percentualrateiodespesa'];
        final n = parsePtBrNumber(raw);
        if (n != null) total += n;
      }

      if (page.length < pageSize) break;
      from += pageSize;
    }

    debugPrint('Sum (Dart) categoria.percentualrateiodespesa empresaId=$empresaId rows=$rowsFetched total=$total');
    return total;
  }

  String? _formatPtBrCompactNumber(Object? value) {
    if (value == null) return null;
    final n = value is num ? value : num.tryParse(value.toString());
    if (n == null) return value.toString().replaceAll('.', ',');
    final decimals = n % 1 == 0 ? 0 : 2;
    return n.toStringAsFixed(decimals).replaceAll('.', ',');
  }

  Future<void> _attachCustoProducaoToProdutoRows(List<Map<String, dynamic>> rows) async {
    try {
      final produtoIds = <int>[];
      for (final r in rows) {
        final id = r['produtoid'];
        if (id is num) produtoIds.add(id.toInt());
      }
      if (produtoIds.isEmpty) return;

      // Fetch all produtoreceita records for the visible products in one query.
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

      // Attach to each row so _RowCard can render it without extra context.
      for (final r in rows) {
        final id = r['produtoid'];
        if (id is! num) continue;
        r['_custo_producao'] = totals[id.toInt()] ?? 0.0;
      }
    } catch (e) {
      debugPrint('Failed to compute custo de produção for produto list: $e');
      // Non-fatal: list should still render.
    }
  }

  /// Aviso na tela quando o total de despesas não pôde ser gravado em `totaldespesas`.
  void _avisarFalhaRecalculo(String mensagem) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(mensagem),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        duration: const Duration(seconds: 8),
      ),
    );
  }

  // Total das despesas variáveis ATIVAS (status = 'A') da empresa.
  Future<double> _sumDespesaVariavelValorMensal(int empresaId) => TotalDespesasService.somarDespesaVariavelAtiva(empresaId);

  Future<double?> _loadTotalDespesaVariavelAndMaybeSync(int empresaId) async {
    // Observação importante: em alguns schemas a tabela `totaldespesas` não possui
    // colunas de auditoria como `dataatualizacao`. Então aqui evitamos depender disso.
    double? fromTotalDespesas;
    try {
      // IMPORTANTE (Supabase/Postgres): identificadores sem aspas são sempre lower_snake_case.
      // Pelo schema cache e logs, a coluna existente é `totaldespesavariavel`.
      final totalRow = await SupabaseService.selectSingle(
        'totaldespesas',
        select: 'totaldespesavariavel',
        filters: {'empresaid': empresaId},
      );
      fromTotalDespesas = parsePtBrNumber(totalRow?['totaldespesavariavel']);
    } catch (e) {
      debugPrint('Failed to read totaldespesas.totaldespesavariavel (empresaId=$empresaId): $e');
      fromTotalDespesas = null;
    }

    // Fallback: recalcula pela tabela origem.
    final fromItems = await _sumDespesaVariavelValorMensal(empresaId);
    final shouldSync = (fromTotalDespesas == null) || (fromTotalDespesas - fromItems).abs() > 0.009;

    if (shouldSync) {
      try {
        await TotalDespesasService.setTotals(empresaId: empresaId, totalDespesaVariavel: fromItems);
        debugPrint('TotalDespesaVariavel autocorrected for empresaId=$empresaId total=$fromItems (was=$fromTotalDespesas)');
      } catch (e) {
        // Mesmo se o upsert falhar (RLS/coluna inexistente/etc), ainda mostramos o total calculado.
        debugPrint('Failed to upsert totaldespesas (empresaId=$empresaId). Using calculated total=$fromItems. Error: $e');
        _avisarFalhaRecalculo('Não foi possível gravar o total de despesas variáveis. O valor exibido foi calculado na tela; '
            'clique em Atualizar para tentar novamente.');
      }
      return fromItems;
    }

    return fromTotalDespesas;
  }

  // Total das despesas fixas ATIVAS (status = 'A') da empresa.
  Future<double> _sumDespesaFixaValorMensal(int empresaId) => TotalDespesasService.somarDespesaFixaAtiva(empresaId);

  Future<double?> _loadTotalDespesaFixaAndMaybeSync(int empresaId) async {
    double? fromTotalDespesas;
    try {
      final totalRow = await SupabaseService.selectSingle(
        'totaldespesas',
        select: 'totaldespesafixa',
        filters: {'empresaid': empresaId},
      );
      fromTotalDespesas = parsePtBrNumber(totalRow?['totaldespesafixa']);
    } catch (e) {
      debugPrint('Failed to read totaldespesas.totaldespesafixa (empresaId=$empresaId): $e');
      fromTotalDespesas = null;
    }

    final fromItems = await _sumDespesaFixaValorMensal(empresaId);
    final shouldSync = (fromTotalDespesas == null) || (fromTotalDespesas - fromItems).abs() > 0.009;
    if (shouldSync) {
      try {
        await TotalDespesasService.setTotals(empresaId: empresaId, totalDespesaFixa: fromItems);
        debugPrint('TotalDespesaFixa autocorrected for empresaId=$empresaId total=$fromItems (was=$fromTotalDespesas)');
      } catch (e) {
        debugPrint('Failed to upsert totaldespesas.totaldespesafixa (empresaId=$empresaId). Using calculated total=$fromItems. Error: $e');
        _avisarFalhaRecalculo('Não foi possível gravar o total de despesas fixas. O valor exibido foi calculado na tela; '
            'clique em Atualizar para tentar novamente.');
      }
      return fromItems;
    }

    return fromTotalDespesas;
  }

  String get _backLocation {
    final override = widget.backLocation?.trim();
    if (override != null && override.isNotEmpty) return override;
    // When we're browsing nested cadastros inside a specific Receita
    // (Ingredientes/Materiais), the expected back behavior is to return
    // to the Receita list, not the Cadastros menu.
    final isNestedReceitaChildren = _contextReceitaId != null && (widget.definition.keyName == 'ingrediente' || widget.definition.keyName == 'material');
    if (isNestedReceitaChildren) return '/cadastros/receita';

    // If the entity belongs to “Cadastro operacional”, default back to its index.
    // This only matters when there is no navigation stack (e.g., deep link or
    // route replacement). When opened from the index, we prefer pop().
    const basicCadastros = <String>{
      'empresa',
      'usuario',
      'marca',
      'unidade',
      'rateiodespesa',
      'despesavariavel',
      'categoria',
      'delivery',
      'setup',
    };
    const internalCadastros = <String>{'produtoreceita', 'material', 'ingrediente'};
    final key = widget.definition.keyName;
    final isOperational = !basicCadastros.contains(key) && !internalCadastros.contains(key);
    return isOperational ? '/cadastros-operacional' : '/cadastros';
  }

  @override
  void initState() {
    super.initState();

    // Diagnostics: helps confirm which cadastro list is being opened at runtime.
    debugPrint('GenericCadastroListPage:init keyName=${widget.definition.keyName} table=${widget.definition.table}');

    final rid = widget.extraFilters?['receitaid'];
    if (rid is num) _contextReceitaId = rid.toInt();
    _receitaSearchController.addListener(_onReceitaSearchChanged);
    _produtoSearchController.addListener(_onProdutoSearchChanged);
    _itemSearchController.addListener(_onItemSearchChanged);
    // This page is used by many cadastros. For Receita, the filter must always
    // start blank when the user opens the cadastro list.
    _resetReceitaSearchIfNeeded();
    _resetProdutoSearchIfNeeded();
    _resetItemSearchIfNeeded();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      // Avoid duplicate subscriptions if dependencies change.
      appRouteObserver.unsubscribe(this);
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() {
    // Called when coming back to this page after popping a route that was on top.
    //
    // Main fix: when we return from Receita -> Ingredientes/Materiais pages,
    // the Receita list must reload so backend-triggered totals refresh.
    if (!mounted || _isLoading) return;

     // Avoid excessive reloads when multiple routes are popped quickly.
     final now = DateTime.now();
     final last = _lastAutoRefresh;
     if (last != null && now.difference(last).inMilliseconds < 700) return;
     _lastAutoRefresh = now;

     // Nested receita children (Ingredientes/Materiais) show a summary card that
     // depends on backend-triggered totals from *both* tables. When the user
     // edits/deletes items on the sibling screen and comes back, we must reload
     // so the header reflects the updated totals.
     final isReceitaChild = _contextReceitaId != null && (widget.definition.keyName == 'ingrediente' || widget.definition.keyName == 'material');
     if (isReceitaChild) {
       _load();
       return;
     }

    if (widget.definition.keyName == 'receita' && _contextReceitaId == null) {
      _load();
      return;
    }

    // Keep the same behavior for other cadastros that need to refresh derived
    // data after returning from nested flows.
    // Produto e Kit NÃO entram aqui: a lista já recarrega explicitamente ao voltar da
    // tela de edição (await context.push(...) + _load em _openEdit/_openCreate).
    // Recarregar também aqui fazia a lista carregar duas vezes seguidas.
    if (widget.definition.keyName == 'item') {
      _load();
    }
  }

  @override
  void dispose() {
    _listScrollController.dispose();
    appRouteObserver.unsubscribe(this);
    _receitaSearchController.removeListener(_onReceitaSearchChanged);
    _receitaSearchController.dispose();
    _produtoSearchController.removeListener(_onProdutoSearchChanged);
    _produtoSearchController.dispose();
    _itemSearchController.removeListener(_onItemSearchChanged);
    _itemSearchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant GenericCadastroListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.definition.keyName != widget.definition.keyName) {
      _openedInitialCreate = false;
      _resetReceitaSearchIfNeeded();
      _resetProdutoSearchIfNeeded();
      _resetItemSearchIfNeeded();
      _load();
    }
  }

  void _resetReceitaSearchIfNeeded() {
    if (widget.definition.keyName != 'receita') return;
    if (_receitaSearchController.text.isEmpty && _receitaSearchQuery.isEmpty) return;
    _receitaSearchController.text = '';
    _receitaSearchQuery = '';
  }

  void _resetProdutoSearchIfNeeded() {
    if (widget.definition.keyName != 'produto') return;
    if (_produtoSearchController.text.isEmpty && _produtoSearchQuery.isEmpty) return;
    _produtoSearchController.text = '';
    _produtoSearchQuery = '';
  }

  void _resetItemSearchIfNeeded() {
    if (widget.definition.keyName != 'item') return;
    if (_itemSearchController.text.isEmpty && _itemSearchQuery.isEmpty) return;
    _itemSearchController.text = '';
    _itemSearchQuery = '';
  }

  void _onReceitaSearchChanged() {
    if (widget.definition.keyName != 'receita') return;
    final q = _receitaSearchController.text.trim();
    if (q == _receitaSearchQuery) return;
    setState(() {
      _receitaSearchQuery = q;
      _applyReceitaFilter();
    });
  }

  void _onProdutoSearchChanged() {
    if (widget.definition.keyName != 'produto') return;
    final q = _produtoSearchController.text.trim();
    if (q == _produtoSearchQuery) return;
    setState(() {
      _produtoSearchQuery = q;
      _applyProdutoFilter();
    });
  }

  void _onItemSearchChanged() {
    if (widget.definition.keyName != 'item') return;
    final q = _itemSearchController.text.trim();
    if (q == _itemSearchQuery) return;
    setState(() {
      _itemSearchQuery = q;
      _applyItemFilter();
    });
  }

  void _setReceitaSearchSilently(String text) {
    _receitaSearchController.removeListener(_onReceitaSearchChanged);
    _receitaSearchController.text = text;
    _receitaSearchController.addListener(_onReceitaSearchChanged);
    _receitaSearchQuery = text.trim();
    _applyReceitaFilter();
  }

  void _applyReceitaFilter() {
    if (widget.definition.keyName != 'receita') {
      _filteredRows = _rows;
      return;
    }

    final q = _receitaSearchQuery.trim().toLowerCase();
    if (q.isEmpty) {
      _filteredRows = _rows;
      return;
    }

    bool matches(Map<String, dynamic> row) {
      final nome = row['nome']?.toString().trim().toLowerCase() ?? '';
      return nome.contains(q);
    }

    _filteredRows = _rows.where(matches).toList(growable: false);
  }

  void _applyProdutoFilter() {
    if (widget.definition.keyName != 'produto') {
      _produtoFilteredRows = _rows;
      return;
    }

    final q = _produtoSearchQuery.trim().toLowerCase();
    if (q.isEmpty) {
      _produtoFilteredRows = _rows;
      return;
    }

    bool matches(Map<String, dynamic> row) {
      final nome = row['nome']?.toString().trim().toLowerCase() ?? '';
      return nome.contains(q);
    }

    _produtoFilteredRows = _rows.where(matches).toList(growable: false);
  }

  void _applyItemFilter() {
    if (widget.definition.keyName != 'item') {
      _itemFilteredRows = _rows;
      return;
    }

    final q = _itemSearchQuery.trim().toLowerCase();
    final tipoId = _itemTipoFiltroId;
    if (q.isEmpty && tipoId == null) {
      _itemFilteredRows = _rows;
      return;
    }

    bool matches(Map<String, dynamic> row) {
      final nome = row['nome']?.toString().trim().toLowerCase() ?? '';
      if (q.isNotEmpty && !nome.contains(q)) return false;
      if (tipoId != null && (row['tipoitemid'] as num?)?.toInt() != tipoId) return false;
      return true;
    }

    _itemFilteredRows = _rows.where(matches).toList(growable: false);
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final session = context.read<AppSessionController>();
      final empresaId = session.empresaId;
      _empresaIdForDebug = empresaId;

      final filters = <String, dynamic>{};
      // Default behavior: cadastros "scopedByEmpresa" are filtered by the empresa
      // tied to the logged-in profile.
      //
      // IMPORTANT: Administrador (tipoUsuario = 'A') must be able to view records
      // across companies, so we skip this auto-filter for admins.
      // Only Super Admin (tipo 'A') can view cross-company data.
      if (widget.definition.scopedByEmpresa && empresaId != null && !session.isSuperAdmin) {
        filters['empresaid'] = empresaId;
      }
      // Empresa: por padrão, usuários não-admin só podem ver a própria empresa.
      // Admin pode visualizar todas.
      if (widget.definition.keyName == 'empresa' && empresaId != null && !session.isSuperAdmin) {
        filters['empresaid'] = empresaId;
      }

      // Usuário: admin da empresa (E) pode gerenciar somente usuários da própria empresa.
      if (widget.definition.keyName == 'usuario' && empresaId != null && !session.isSuperAdmin) {
        filters['empresaid'] = empresaId;
      }

      // Delivery da Empresa: usuário tipo E deve ver somente a empresa logada.
      if (widget.definition.keyName == 'empresadelivery' && empresaId != null && !session.isSuperAdmin) {
        filters['empresaid'] = empresaId;
      }

      // Classificação de Kit: sempre somente da empresa logada (inclusive para o tipo A).
      if (widget.definition.keyName == 'classificacaokit') {
        filters['empresaid'] = empresaId ?? -1;
      }

      // Imposto e taxas da empresa: usuário tipo E deve ver somente a empresa logada.
      // Sem empresa identificada, filtra por um id inexistente (não mostra nada) em vez de mostrar todas.
      if (widget.definition.keyName == 'empresataxas' && !session.isSuperAdmin) {
        filters['empresaid'] = empresaId ?? -1;
      }

      if (widget.extraFilters != null) {
        filters.addAll(widget.extraFilters!);
      }

      debugPrint('Loading ${widget.definition.table} key=${widget.definition.keyName} filters=$filters superAdmin=${session.isSuperAdmin} empresaId=$empresaId');

      // Extra selects to render richer list cards (show names instead of numeric codes).
      // - Ingrediente/Material: embed related Item (+ Unidade) to show item name/unit/cost.
      // - Despesa Variável: embed related Item to show item name.
      // - Item: embed Marca + TipoItem + Unidade to show a compact 2-line layout.
      // - Receita: embed Unidade to show "Nome (un)" in the 1st line.
      // - Produto: embed Categoria to show "Categoria: ..." in the 2nd line.
      final shouldEmbedItemInReceita = widget.definition.keyName == 'ingrediente' || widget.definition.keyName == 'material';
      final shouldEmbedItemInDespesaVariavel = widget.definition.keyName == 'despesavariavel';
      final shouldEmbedFkLabelsForItem = widget.definition.keyName == 'item';
      final shouldEmbedUnidadeForReceita = widget.definition.keyName == 'receita';
      final shouldEmbedCategoriaForProduto = widget.definition.keyName == 'produto';
      final shouldEmbedEmpresaDeliveryLabels = widget.definition.keyName == 'empresadelivery';

      final String? select;
      if (shouldEmbedItemInReceita || shouldEmbedItemInDespesaVariavel) {
        // Ingrediente/Material + Despesa Variável: embed Item so the list can show
        // the item name and (when applicable) the unit cost.
        //
        // IMPORTANT (multi-empresa): ingrediente/material tables do not have `empresaid`.
        // Receita IDs may collide across companies, so when we are inside a logged-in
        // company context, we also embed `receita.empresaid` so we can filter by it.
        final isIngredienteOrMaterial = widget.definition.keyName == 'ingrediente' || widget.definition.keyName == 'material';
        // Embed Item + its Unidade so nested Receita lists can show "Qtde" with unit.
        // Note: unidade table uses column `unidade` as its label.
        const itemSelect = 'item:itemid(nome,custounitario,unidade:unidadeid(unidade))';
        select = isIngredienteOrMaterial ? '*, $itemSelect, receita:receitaid(empresaid)' : '*, $itemSelect';
      } else if (shouldEmbedFkLabelsForItem) {
        // Item: embed related labels used by the 2-line list layout:
        // - Marca + TipoItem for the 2nd line
        // - Unidade to show "(gr)", "(ml)", etc on the 1st line
        select = '*, marca:marcaid(nome), tipoitem:tipoitemid(nome), unidade:unidadeid(unidade)';
      } else if (shouldEmbedUnidadeForReceita) {
        select = '*, unidade:unidadeid(unidade)';
      } else if (shouldEmbedCategoriaForProduto) {
        select = '*, categoria:categoriaid(nome)';
      } else if (widget.definition.keyName == 'kit') {
        // Kit: nome da classificação (classificacaokit.nome) para o card ao lado do nome.
        select = '*, classificacao:classificacaokitid(nome)';
      } else if (widget.definition.keyName == 'empresataxas') {
        // Imposto e taxas: exibir o nome da empresa em vez do id.
        select = '*, empresa:empresaid(nomefantasia)';
      } else if (shouldEmbedEmpresaDeliveryLabels) {
        // EmpresaDelivery: embed Empresa + Delivery so the list shows names (not IDs).
        // Note: uses explicit aliases to keep payload small.
        select = '*, empresa:empresaid(nomefantasia), delivery:deliveryid(nome)';
      } else {
        select = null;
      }

      // Extra safety (multi-empresa): when listing Ingredientes/Materiais, scope by
      // the empresa that owns the linked Receita. Without this, a receitaid from
      // another company could leak into the list/total.
      if ((widget.definition.keyName == 'ingrediente' || widget.definition.keyName == 'material') && empresaId != null && !session.isSuperAdmin) {
        // Works together with the `receita:receitaid(empresaid)` embed in the select.
        filters['receita.empresaid'] = empresaId;
      }

      Future<Map<String, dynamic>?>? receitaFuture;
      if (_contextReceitaId != null && _contextReceitaNome == null) {
        final receitaFilters = <String, dynamic>{'receitaid': _contextReceitaId};
        if (empresaId != null) receitaFilters['empresaid'] = empresaId;
        receitaFuture = SupabaseService.selectSingle('receita', select: 'receitaid,nome', filters: receitaFilters);
      }

      final rowsFuture = SupabaseService.select(
        widget.definition.table,
        select: select,
        filters: filters.isEmpty ? null : filters,
        // Prefer alphabetical ordering whenever possible.
        orderBy: _preferredOrderColumn(widget.definition),
        ascending: true,
        limit: 200,
      );

      Future<double?>? totalDespesaVariavelFuture;
      Future<double?>? totalDespesaFixaFuture;
      Future<double?>? totalCategoriaRateioFuture;
      Future<Map<String, dynamic>?>? impostoPctFuture;
      Future<List<_KitDelivery>>? kitDeliveriesFuture;
      Future<List<Map<String, dynamic>>>? kitClassificacoesFuture;
      if (empresaId != null) {
        if (widget.definition.keyName == 'kit') {
          impostoPctFuture = _loadEmpresaSetupKitHeader(empresaId);
          kitDeliveriesFuture = _loadKitDeliveries(empresaId);
          kitClassificacoesFuture = _loadKitClassificacoes(empresaId);
        }
        if (widget.definition.keyName == 'despesavariavel') {
          totalDespesaVariavelFuture = _loadTotalDespesaVariavelAndMaybeSync(empresaId);
        }
        if (widget.definition.keyName == 'rateiodespesa') {
          totalDespesaFixaFuture = _loadTotalDespesaFixaAndMaybeSync(empresaId);
        }
        if (widget.definition.keyName == 'categoria') {
          // Regra: total calculado sempre para a empresa logada.
          totalCategoriaRateioFuture = _sumCategoriaRateioPercent(empresaId);
        }
      }

      final results = await Future.wait<dynamic>([
        if (receitaFuture != null) receitaFuture,
        if (impostoPctFuture != null) impostoPctFuture,
        if (totalDespesaVariavelFuture != null) totalDespesaVariavelFuture,
        if (totalDespesaFixaFuture != null) totalDespesaFixaFuture,
        if (totalCategoriaRateioFuture != null) totalCategoriaRateioFuture,
        rowsFuture,
      ]);

      if (receitaFuture != null) {
        final receitaRow = results.first as Map<String, dynamic>?;
        final nome = receitaRow?['nome']?.toString().trim();
        if (nome != null && nome.isNotEmpty) _contextReceitaNome = nome;
      }

      if (impostoPctFuture != null) {
        final idx = receitaFuture != null ? 1 : 0;
        final setup = results[idx] as Map<String, dynamic>?;
        _empresaSetupImpostoPct = parsePtBrNumber(setup?['imposto']);
        _empresaSetupTaxaMotoboyPct = parsePtBrNumber(setup?['taxamotoboy']);
      }
      if (kitDeliveriesFuture != null) {
        _kitDeliveries = await kitDeliveriesFuture;
      }
      if (widget.definition.keyName == 'item') {
        _itemTipos = await _loadItemTipos();
        if (_itemTipoFiltroId != null &&
            !_itemTipos.any((t) => (t['tipoitemid'] as num?)?.toInt() == _itemTipoFiltroId)) {
          _itemTipoFiltroId = null;
        }
      }
      if (kitClassificacoesFuture != null) {
        _kitClassificacoes = await kitClassificacoesFuture;
        // Se a classificação filtrada não existir mais, volta para TODOS.
        if (_kitClassificacaoFiltroId != null &&
            !_kitClassificacoes.any((c) => (c['classificacaokitid'] as num?)?.toInt() == _kitClassificacaoFiltroId)) {
          _kitClassificacaoFiltroId = null;
        }
      }

      final offsetImposto = impostoPctFuture != null ? 1 : 0;

      if (totalDespesaVariavelFuture != null) {
        final idx = (receitaFuture != null ? 1 : 0) + offsetImposto;
        final total = results[idx];
        if (total is num) {
          _totalDespesaVariavel = total;
        } else {
          _totalDespesaVariavel = null;
        }
      } else {
        _totalDespesaVariavel = null;
      }

      if (totalDespesaFixaFuture != null) {
        final idx = (receitaFuture != null ? 1 : 0) + offsetImposto + (totalDespesaVariavelFuture != null ? 1 : 0);
        final total = results[idx];
        if (total is num) {
          _totalDespesaFixa = total;
        } else {
          _totalDespesaFixa = null;
        }
      } else {
        _totalDespesaFixa = null;
      }

      if (totalCategoriaRateioFuture != null) {
        final idx =
            (receitaFuture != null ? 1 : 0) + offsetImposto + (totalDespesaVariavelFuture != null ? 1 : 0) + (totalDespesaFixaFuture != null ? 1 : 0);
        final total = results[idx];
        if (total is num) {
          _totalCategoriaRateio = total;
        } else {
          _totalCategoriaRateio = null;
        }
      } else {
        _totalCategoriaRateio = null;
      }

      final rows = results.last as List<Map<String, dynamic>>;

      // Produto (lista principal): calcular e anexar o custo de produção para cada produto.
      // Fórmula (por receita no produto): (receita.custoreceita / receita.qtdreceita) * produtoreceita.quantidadereceita.
      if (widget.definition.keyName == 'produto') {
        await _attachCustoProducaoToProdutoRows(rows);
      }

      // Receita (lista principal): os totais agora vêm direto da tabela `receita`
      // (custototalingrediente, custototalmaterial, custoreceita), mantidos no
      // backend via triggers. Assim, a lista não precisa recalcular via joins.

      if (widget.definition.keyName == 'usuario') {
        final peek = rows.take(8).map((r) {
          final id = r['usuarioid'];
          final emp = r['empresaid'];
          final email = r['email'];
          final nome = r['nome'];
          final sobrenome = r['sobrenome'];
          return 'id=$id emp=$emp email=$email nome=$nome $sobrenome';
        }).join(' | ');
        debugPrint('Loaded usuario rows=${rows.length}. peek=[$peek]');
      }

      rows.sort((a, b) => _rowTitle(widget.definition, a).compareTo(_rowTitle(widget.definition, b)));

      // Ingredientes (lista aninhada da Receita): exibir o total vindo da própria
      // tabela `receita` (custototalingrediente), mantido no backend via triggers.
      if (widget.definition.keyName == 'ingrediente' && _contextReceitaId != null) {
        final backendTotal = await _loadReceitaCustoTotalIngrediente(receitaId: _contextReceitaId!, empresaId: empresaId);
        final computedTotal = _sumCustoIngredientesReceita(rows, receitaIdForDebug: _contextReceitaId);
        // IMPORTANT (UX): the header should reflect what is on screen.
        // So we *display* the computed value (when possible) and only use backend
        // as a fallback.
        _totalCustoIngredientesReceita = computedTotal ?? backendTotal;

        // Keep backend consistent when it diverges from the list.
        if (backendTotal != null && computedTotal != null) {
          final diff = (computedTotal - backendTotal).abs();
          if (diff >= 0.01) {
            if (backendTotal == 0 && computedTotal > 0) {
              debugPrint(
                'Receita $_contextReceitaId: backend custototalingrediente=0, but computed=$computedTotal. Using computed value (UI) and syncing.',
              );
            }
            try {
              await ReceitaService().syncTotalsForReceita(receitaId: _contextReceitaId!);
            } catch (e) {
              debugPrint('Failed to sync receita totals after ingrediente load (diff=$diff): $e');
            }
          }
        } else if (backendTotal == 0 && (computedTotal ?? 0) > 0) {
          // backendTotal can be null; still attempt to sync when we know it's wrong.
          try {
            await ReceitaService().syncTotalsForReceita(receitaId: _contextReceitaId!);
          } catch (e) {
            debugPrint('Failed to sync receita totals after ingrediente load: $e');
          }
        }

        // Also load materials total so the header can show a complete summary card.
        // (We don't have the materials rows here, so we rely on the backend total.)
        try {
          _totalCustoMateriaisReceita = await _loadReceitaCustoTotalMaterial(receitaId: _contextReceitaId!, empresaId: empresaId);

          // If DB triggers are missing or delayed, `custototalmaterial` can be stale.
          // This is most visible when opening Ingredientes first: the UI only has
          // ingredient rows, so it depends entirely on the stored material total.
          // When we suspect staleness (0 while user expects > 0), attempt a one-time
          // sync and reload.
          if ((_totalCustoMateriaisReceita ?? 0) == 0) {
            try {
              await ReceitaService().syncTotalsForReceita(receitaId: _contextReceitaId!, empresaId: empresaId);
              _totalCustoMateriaisReceita = await _loadReceitaCustoTotalMaterial(receitaId: _contextReceitaId!, empresaId: empresaId);
            } catch (e) {
              debugPrint('Failed to sync/reload receita.custototalmaterial for receitaId=$_contextReceitaId: $e');
            }
          }
        } catch (e) {
          debugPrint('Failed to load receita.custototalmaterial for receitaId=$_contextReceitaId: $e');
          _totalCustoMateriaisReceita = null;
        }
      } else {
        _totalCustoIngredientesReceita = null;
      }

      // Materiais (lista aninhada da Receita): calcular o custo total exibido no header.
      if (widget.definition.keyName == 'material' && _contextReceitaId != null) {
        final backendTotal = await _loadReceitaCustoTotalMaterial(receitaId: _contextReceitaId!, empresaId: empresaId);
        final computedTotal = _sumCustoMateriaisReceita(rows, receitaIdForDebug: _contextReceitaId);
        // IMPORTANT (UX): the header should reflect what is on screen.
        _totalCustoMateriaisReceita = computedTotal ?? backendTotal;

        // Keep backend consistent when it diverges from the list.
        if (backendTotal != null && computedTotal != null) {
          final diff = (computedTotal - backendTotal).abs();
          if (diff >= 0.01) {
            if (backendTotal == 0 && computedTotal > 0) {
              debugPrint('Receita $_contextReceitaId: backend custototalmaterial=0, but computed=$computedTotal. Using computed value (UI) and syncing.');
            }
            try {
              await ReceitaService().syncTotalsForReceita(receitaId: _contextReceitaId!);
            } catch (e) {
              debugPrint('Failed to sync receita totals after material load (diff=$diff): $e');
            }
          }
        } else if (backendTotal == 0 && (computedTotal ?? 0) > 0) {
          try {
            await ReceitaService().syncTotalsForReceita(receitaId: _contextReceitaId!);
          } catch (e) {
            debugPrint('Failed to sync receita totals after material load: $e');
          }
        }

        // Also load ingredients total so the header can show a complete summary card.
        // (We don't have the ingredients rows here, so we rely on the backend total.)
        try {
          _totalCustoIngredientesReceita = await _loadReceitaCustoTotalIngrediente(receitaId: _contextReceitaId!, empresaId: empresaId);

          // Symmetric fix: when opening Materiais first, the ingredient stored total
          // may be stale. Attempt a one-time sync when we suspect it.
          if ((_totalCustoIngredientesReceita ?? 0) == 0) {
            try {
              await ReceitaService().syncTotalsForReceita(receitaId: _contextReceitaId!, empresaId: empresaId);
              _totalCustoIngredientesReceita = await _loadReceitaCustoTotalIngrediente(receitaId: _contextReceitaId!, empresaId: empresaId);
            } catch (e) {
              debugPrint('Failed to sync/reload receita.custototalingrediente for receitaId=$_contextReceitaId: $e');
            }
          }
        } catch (e) {
          debugPrint('Failed to load receita.custototalingrediente for receitaId=$_contextReceitaId: $e');
          _totalCustoIngredientesReceita = null;
        }
      } else {
        // IMPORTANT: when we are on the Ingredientes page we still load
        // `_totalCustoMateriaisReceita` (from backend) to show a complete summary card.
        // So we must NOT wipe it here.
        if (widget.definition.keyName != 'ingrediente') _totalCustoMateriaisReceita = null;
      }

      // Despesas fixas e variáveis: sempre em ordem alfabética do nome da despesa
      // (sem diferenciar maiúsculas/acentos). Nas variáveis o nome vem do item.
      var rowsOrdenadas = rows;
      if (widget.definition.keyName == 'rateiodespesa' || widget.definition.keyName == 'despesavariavel') {
        String nomeDespesa(Map<String, dynamic> r) {
          final item = r['item'];
          final nome = widget.definition.keyName == 'despesavariavel' && item is Map ? item['nome'] : r['nome'];
          return chaveOrdenacaoAlfabetica((nome ?? '').toString());
        }

        rowsOrdenadas = List<Map<String, dynamic>>.from(rows)..sort((a, b) => nomeDespesa(a).compareTo(nomeDespesa(b)));
      }

      if (!mounted) return;
      setState(() {
        _rows = rowsOrdenadas;
        _applyReceitaFilter();
        _applyProdutoFilter();
        _applyItemFilter();
      });

      if (widget.openCreateOnLoad && !_openedInitialCreate) {
        _openedInitialCreate = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _openCreate());
      }
    } catch (e) {
      debugPrint('Load ${widget.definition.table} failed: $e');
      if (!mounted) return;
      // UX: When a new cadastro is wired in the app but the backing table was not
      // created yet in the database, PostgREST throws a "relation does not exist"
      // error. In this case, the user expectation is the same as an empty list.
      // So we render the same empty-state panel used in other cadastros.
      final msg = e.toString().toLowerCase();
      final table = widget.definition.table.toLowerCase();
      final looksLikeMissingTable = (msg.contains('relation') && msg.contains('does not exist') && msg.contains(table)) ||
          (msg.contains('could not find') && msg.contains(table)) ||
          (msg.contains('schema cache') && msg.contains(table));
      if (looksLikeMissingTable) {
        setState(() {
          _error = null;
          _rows = const [];
          _produtoFilteredRows = const [];
          _itemFilteredRows = const [];
          _filteredRows = const [];
        });
      } else {
        setState(() => _error = 'Não foi possível carregar os registros.');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Abre a pré-visualização do relatório PDF dos kits (com Imprimir e Salvar),
  /// usando somente os kits visíveis (filtro de classificação aplicado).
  Future<void> _openKitPdf(List<Map<String, dynamic>> rows) async {
    final session = context.read<AppSessionController>();
    final filtroId = _kitClassificacaoFiltroId;
    final filtroNome = filtroId == null
        ? 'TODOS'
        : (_kitClassificacoes
                .where((c) => (c['classificacaokitid'] as num?)?.toInt() == filtroId)
                .map((c) => (c['nome'] ?? '').toString())
                .firstOrNull ??
            '#$filtroId');
    final imposto = _empresaSetupImpostoPct;
    final taxaMotoboy = _empresaSetupTaxaMotoboyPct;
    final deliveries = List<_KitDelivery>.from(_kitDeliveries);
    final kits = List<Map<String, dynamic>>.from(rows);
    final empresa = session.empresaLabel;

    Future<Uint8List> build(PdfPageFormat format) async {
      final linhas = await Future.wait(kits.map((row) async {
        final kitId = row['kitid'];
        final empresaRaw = row['empresaid'];
        KitTotals? totals;
        if (kitId is num) {
          try {
            totals = await KitService().loadTotals(
              kitId.toInt(),
              empresaId: empresaRaw is num ? empresaRaw.toInt() : session.empresaId,
            );
          } catch (e) {
            debugPrint('KitPdf: loadTotals failed kitId=$kitId: $e');
          }
        }
        final total = totals?.totalKitComTaxa;
        final classificacao = row['classificacao'];
        return KitPdfLinha(
          nome: (row['nome'] ?? '').toString().trim(),
          classificacao: classificacao is Map ? classificacao['nome']?.toString() : null,
          inativo: (row['status'] ?? '').toString().trim().toUpperCase() == 'I',
          valorTotal: total,
          valorListaSite: calcularValorDeLista(total, [imposto, taxaMotoboy ?? 0]),
          deliveries: [
            for (final d in deliveries)
              KitPdfDelivery(nome: d.nome, taxaPct: d.taxaPct, valorLista: calcularValorDeLista(total, [d.taxaPct, imposto])),
          ],
        );
      }));
      return KitPdfReport.build(
        format: format,
        empresa: empresa,
        filtroClassificacao: filtroNome,
        impostoPct: imposto,
        taxaMotoboyPct: taxaMotoboy,
        deliveries: [for (final d in deliveries) KitPdfDelivery(nome: d.nome, taxaPct: d.taxaPct)],
        linhas: linhas,
      );
    }

    await _showPdfPreview(titulo: 'Relatório de kits', arquivo: 'kits', build: build);
  }

  /// Tipos de item (tabela interna, sem empresa) para o filtro da lista de itens.
  Future<List<Map<String, dynamic>>> _loadItemTipos() async {
    try {
      return await SupabaseService.select('tipoitem', select: 'tipoitemid,nome', orderBy: 'nome', ascending: true, limit: 200);
    } catch (e) {
      debugPrint('Load tipoitem (filtro item) failed: $e');
      return const [];
    }
  }

  /// Abre a pré-visualização do relatório PDF dos itens visíveis (filtros aplicados).
  Future<void> _openItemPdf(List<Map<String, dynamic>> rows) async {
    final session = context.read<AppSessionController>();
    final tipoId = _itemTipoFiltroId;
    final tipoNome = tipoId == null
        ? 'TODOS'
        : (_itemTipos
                .where((t) => (t['tipoitemid'] as num?)?.toInt() == tipoId)
                .map((t) => (t['nome'] ?? '').toString())
                .firstOrNull ??
            '#$tipoId');
    final itens = List<Map<String, dynamic>>.from(rows);
    final filtroNome = _itemSearchQuery.trim();
    final empresa = session.empresaLabel;
    await _showPdfPreview(
      titulo: 'Relatório de itens',
      arquivo: 'itens',
      build: (format) => ItemPdfReport.build(
        format: format,
        empresa: empresa,
        filtroTipo: tipoNome,
        filtroNome: filtroNome,
        itens: itens,
      ),
    );
  }

  /// Tela cheia com a pré-visualização do PDF e os botões Imprimir e Salvar.
  Future<void> _showPdfPreview({
    required String titulo,
    required String arquivo,
    required Future<Uint8List> Function(PdfPageFormat format) build,
  }) async {
    await showPdfPreviewDialog(context, titulo: titulo, arquivo: arquivo, build: build);
  }

  /// Classificações de kit da empresa (para o filtro da lista de kits).
  Future<List<Map<String, dynamic>>> _loadKitClassificacoes(int empresaId) async {
    try {
      return await SupabaseService.select(
        'classificacaokit',
        select: 'classificacaokitid,nome',
        filters: {'empresaid': empresaId},
        orderBy: 'nome',
        ascending: true,
        limit: 500,
      );
    } catch (e) {
      debugPrint('Load classificacaokit (filtro kit) failed: $e');
      return const [];
    }
  }

  /// Deliveries com associação ativa (empresadelivery.status = 'A') para a empresa.
  Future<List<_KitDelivery>> _loadKitDeliveries(int empresaId) async {
    try {
      final rows = await SupabaseService.select(
        'empresadelivery',
        select: 'deliveryid,taxadelivery, delivery:deliveryid(nome)',
        filters: {'empresaid': empresaId, 'status': 'A'},
        limit: 100,
      );
      final list = <_KitDelivery>[
        for (final r in rows)
          _KitDelivery(
            nome: ((r['delivery'] is Map ? (r['delivery'] as Map)['nome'] : null) ?? 'Delivery #${r['deliveryid']}').toString().trim(),
            taxaPct: parsePtBrNumber(r['taxadelivery']),
          ),
      ]..sort((a, b) => a.nome.toLowerCase().compareTo(b.nome.toLowerCase()));
      return list;
    } catch (e) {
      debugPrint('Load empresadelivery (kit) failed: $e');
      return const [];
    }
  }

  /// Imposto e taxa motoboy (empresasetup) da empresa logada, exibidos no cabeçalho da lista de kits.
  Future<Map<String, dynamic>?> _loadEmpresaSetupKitHeader(int empresaId) async {
    try {
      return await SupabaseService.selectSingle('empresasetup', select: 'imposto,taxamotoboy', filters: {'empresaid': empresaId});
    } catch (e) {
      debugPrint('Load empresasetup (imposto/taxamotoboy) failed: $e');
      return null;
    }
  }

  String _preferredOrderColumn(CadastroDefinition def) {
    final candidates = <String>{
      'nome',
      'nomefantasia',
      'razaosocial',
      'unidade',
      ...def.displayColumns,
    };
    for (final c in candidates) {
      if (c == def.idColumn) continue;
      if (def.fields.any((f) => f.column == c) || def.displayColumns.contains(c)) return c;
    }
    return def.idColumn;
  }

  String? _formatPtBrCurrencyWithThousands(Object? value) {
    if (value == null) return null;
    final n = value is num ? value : num.tryParse(value.toString());
    if (n == null) return value.toString();
    final negative = n < 0;
    final fixed = n.abs().toStringAsFixed(2); // "1234.56"
    final parts = fixed.split('.');
    var intPart = parts.first;
    final decPart = parts.length > 1 ? parts.last : '00';

    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      final posFromRight = intPart.length - i;
      buf.write(intPart[i]);
      if (posFromRight > 1 && posFromRight % 3 == 1) buf.write('.');
    }
    intPart = buf.toString();
    final out = '$intPart,$decPart';
    return negative ? '-$out' : out;
  }

  String _rowTitle(CadastroDefinition def, Map<String, dynamic> row) {
    final raw = _rowTitleRaw(def, row);
    return raw.toLowerCase();
  }

  String _rowTitleRaw(CadastroDefinition def, Map<String, dynamic> row) {
    if (def.keyName == 'usuario') {
      final nome = row['nome']?.toString().trim();
      final sobrenome = row['sobrenome']?.toString().trim();
      final full = [if (nome != null && nome.isNotEmpty) nome, if (sobrenome != null && sobrenome.isNotEmpty) sobrenome].join(' ');
      if (full.isNotEmpty) return full;
    }

    if (def.keyName == 'ingrediente' || def.keyName == 'material') {
      final item = row['item'];
      if (item is Map) {
        final nome = item['nome']?.toString().trim();
        if (nome != null && nome.isNotEmpty) return nome;
      }
    }

    for (final c in def.displayColumns) {
      if (c == def.idColumn) continue;
      final v = row[c];
      if (v == null) continue;
      final t = v.toString().trim();
      if (t.isEmpty) continue;
      return t;
    }
    return 'zzzz';
  }

  Future<void> _openCreate() async {
    // Permission: Empresa is created only by Super Admin (tipo 'A').
    if (widget.definition.keyName == 'empresa') {
      final session = context.read<AppSessionController>();
      if (!session.isSuperAdmin) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Somente o Administrador (tipo A) pode cadastrar uma empresa.')));
        return;
      }
    }

    final isKit = widget.definition.keyName == 'kit';
    final isFornecedor = widget.definition.keyName == 'fornecedor';
    final isDespesaVariavel = widget.definition.keyName == 'despesavariavel';
    final forced = <String, dynamic>{...?widget.createForcedValues};
    final hidden = <String>{...widget.createHiddenColumns};
    final readOnly = <String>{...widget.createReadOnlyColumns};

    if (isKit) {
      forced['status'] = 'A';
      // Na criação, status deve ser carregado automaticamente como Ativo.
      hidden.add('status');
      readOnly.add('status');
    }

    if (isFornecedor) {
      forced['status'] = 'A';
      hidden.add('status');
      readOnly.add('status');
    }

    if (isDespesaVariavel) {
      // Regra: sempre salvar como Ativo.
      forced['status'] = 'A';
      hidden.add('status');
      readOnly.add('status');
    }

    final result = await showModalBottomSheet<dynamic>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(
        definition: widget.definition,
        forcedValues: forced,
        hiddenColumns: hidden,
        readOnlyColumns: readOnly,
      ),
    );
    if (result == null) return;
    await _load();

    // For Produto, after creating we usually want to jump straight into the cascade editor.
    if (widget.definition.keyName == 'produto' && result is Map<String, dynamic>) {
      final id = result[widget.definition.idColumn];
      if (id is num) {
        if (!mounted) return;
        // As telas de cadastro ficam no navegador do menu lateral (ShellRoute), que o
        // RouteObserver não acompanha: por isso recarregamos explicitamente ao voltar.
        await context.push('/cadastros/produto/$id');
        if (mounted) await _load();
      }
    }

    if (widget.definition.keyName == 'kit' && result is Map<String, dynamic>) {
      final id = result[widget.definition.idColumn];
      if (id is num) {
        if (!mounted) return;
        // As telas de cadastro ficam no navegador do menu lateral (ShellRoute), que o
        // RouteObserver não acompanha: por isso recarregamos explicitamente ao voltar.
        await context.push('/cadastros/kit/$id');
        if (mounted) await _load();
      }
    }
  }

  Future<void> _openCreateForEmpresaDelivery({required int empresaId}) async {
    if (widget.definition.keyName != 'empresadelivery') return;
    final forced = <String, dynamic>{...?widget.createForcedValues, 'empresaid': empresaId};
    final hidden = <String>{...widget.createHiddenColumns};
    final readOnly = <String>{...widget.createReadOnlyColumns, 'empresaid'};

    final result = await showModalBottomSheet<dynamic>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(definition: widget.definition, forcedValues: forced, hiddenColumns: hidden, readOnlyColumns: readOnly),
    );
    if (result == null) return;
    await _load();
  }

  Future<void> _openEdit(Map<String, dynamic> row) async {
    // Permission safety: when editing users, admin da empresa (E) can only edit same empresa.
    if (widget.definition.keyName == 'usuario') {
      final session = context.read<AppSessionController>();
      if (!session.isSuperAdmin && session.empresaId != null) {
        final rowEmpresaId = row['empresaid'];
        final rowEmpresaNum = rowEmpresaId is num ? rowEmpresaId.toInt() : int.tryParse(rowEmpresaId?.toString() ?? '');
        if (rowEmpresaNum != null && rowEmpresaNum != session.empresaId) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sem permissão para editar usuário de outra empresa.')));
          return;
        }
      }
    }
    if (widget.definition.keyName == 'produto') {
      final id = row[widget.definition.idColumn];
      if (id is num) {
        // Recarrega a lista ao voltar da tela de edição (descrição, classificação, itens...).
        await context.push('/cadastros/produto/$id');
        if (mounted) await _load();
        return;
      }
    }

    if (widget.definition.keyName == 'kit') {
      final id = row[widget.definition.idColumn];
      if (id is num) {
        // Recarrega a lista ao voltar da tela de edição (descrição, classificação, itens...).
        await context.push('/cadastros/kit/$id');
        if (mounted) await _load();
        return;
      }
    }

    final isDespesaVariavel = widget.definition.keyName == 'despesavariavel';

    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(
        definition: widget.definition,
        initialRow: row,
        // Na edição da Despesa Variável, o usuário precisa enxergar e poder ajustar o status.
        // Na criação, o status é forçado para 'A' e oculto em _openCreate().
        forcedValues: null,
        hiddenColumns: const {},
        // Para Despesa Variável, permitir editar o valor mensal manualmente se necessário.
        // (O app ainda tenta sugerir/recalcular automaticamente quando possível.)
        readOnlyColumns: const {},
      ),
    );
    if (updated == true) {
      await _load();
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final cs = Theme.of(context).colorScheme;
    final id = row[widget.definition.idColumn];
    if (id == null) return;

    // Global integrity rule: do not allow deleting a PK record that is still
    // referenced as FK in another table.
    final session = context.read<AppSessionController>();
    final decision = await FkDeleteGuard.checkBeforeDelete(
      keyName: widget.definition.keyName,
      table: widget.definition.table,
      id: id,
      empresaId: session.empresaId,
    );
    if (decision.type == FkDeleteDecisionType.unknown) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'O registro não pode ser excluído, pois está associado a outras informações.',
          ),
        ),
      );
      return;
    }
    if (decision.type == FkDeleteDecisionType.blocked) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Não é possível excluir este registro porque ele está associado a outro cadastro (${decision.block!.reference.referencingTitle}).',
          ),
        ),
      );
      return;
    }

    // Imposto e taxas da empresa: só permite excluir se a empresa do registro não
    // estiver referenciada em nenhuma outra tabela (bloqueia também se a checagem falhar).
    if (widget.definition.keyName == 'empresataxas') {
      final empresaIdRaw = row['empresaid'];
      final empresaIdDoRegistro = empresaIdRaw is num ? empresaIdRaw.toInt() : int.tryParse(empresaIdRaw?.toString() ?? '');
      var podeExcluir = false;
      if (empresaIdDoRegistro != null) {
        try {
          podeExcluir = !await _isEmpresaReferencedElsewhere(empresaIdDoRegistro, ignoreTable: widget.definition.table);
        } catch (e) {
          debugPrint('Failed to check empresa references before deleting empresasetup: $e');
        }
      }
      if (!podeExcluir) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('O registro não pode ser excluído, pois está associado a outras informações.')),
        );
        return;
      }
    }

    // Business rule: do not allow deleting Empresa/Delivery if associated in empresadelivery.
    // (We also expect the DB to have FKs that prevent deletion, but this gives a nicer UX.)
    if (widget.definition.keyName == 'empresa' || widget.definition.keyName == 'delivery') {
      try {
        final hasAssociation = await _hasEmpresaDeliveryAssociation(
          empresaId: widget.definition.keyName == 'empresa' ? id : null,
          deliveryId: widget.definition.keyName == 'delivery' ? id : null,
        );
        if (hasAssociation) {
          if (!mounted) return;
          final what = widget.definition.keyName == 'empresa' ? 'empresa' : 'delivery';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Não é possível excluir este(a) $what porque existe associação na tabela EmpresaDelivery.'),
            ),
          );
          return;
        }
      } catch (e) {
        // If the table doesn't exist yet or any unexpected error happens, we don't block deletion here.
        // The DB constraints (if present) will still protect integrity.
        debugPrint('Failed to check empresadelivery association before delete: $e');
      }
    }

    // Permission: only Super Admin (tipo 'A') can delete Empresa.
    if (widget.definition.keyName == 'empresa') {
      if (!session.isSuperAdmin) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Somente o Administrador (tipo A) pode excluir uma empresa.')));
        return;
      }
    }

    // Permission safety: when deleting users, admin da empresa (E) can only delete same empresa.
    if (widget.definition.keyName == 'usuario') {
      if (!session.isSuperAdmin && session.empresaId != null) {
        final rowEmpresaId = row['empresaid'];
        final rowEmpresaNum = rowEmpresaId is num ? rowEmpresaId.toInt() : int.tryParse(rowEmpresaId?.toString() ?? '');
        if (rowEmpresaNum != null && rowEmpresaNum != session.empresaId) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sem permissão para excluir usuário de outra empresa.')));
          return;
        }
      }
    }

    final isDespesaFixa = widget.definition.table == 'despesafixa' || widget.definition.keyName == 'rateiodespesa';
    final isDespesaVariavel = widget.definition.table == 'despesavariavel' || widget.definition.keyName == 'despesavariavel';
    final isCategoria = widget.definition.table == 'categoria' || widget.definition.keyName == 'categoria';
    final isMaterialOrIngrediente = widget.definition.keyName == 'material' || widget.definition.keyName == 'ingrediente';
    final isKit = widget.definition.keyName == 'kit';
    String? nomeDespesa = row['nome']?.toString().trim();

    // Importante: em Ingrediente/Material, queremos mostrar o nome do Item no sheet
    // de confirmação. Quando o select retorna o item aninhado (item:itemid(nome)),
    // usamos ele; caso contrário resolvemos via itemid.
    if (isMaterialOrIngrediente && (nomeDespesa == null || nomeDespesa.isEmpty)) {
      final nestedItem = row['item'];
      final nestedNome = nestedItem is Map ? nestedItem['nome']?.toString().trim() : null;
      if (nestedNome != null && nestedNome.isNotEmpty) {
        nomeDespesa = nestedNome;
      } else {
        final itemId = row['itemid'];
        if (itemId != null) {
          try {
            final item = await SupabaseService.selectSingle('item', select: 'nome', filters: {'itemid': itemId});
            final resolved = item?['nome']?.toString().trim();
            if (resolved != null && resolved.isNotEmpty) nomeDespesa = resolved;
          } catch (e) {
            debugPrint('Failed to resolve item.nome for ${widget.definition.keyName} delete (itemid=$itemId): $e');
          }
        }
      }
    }
    // Importante: em Despesa Variável, o nome vem da tabela `item`.
    // (despesavariavel não possui coluna `nome` no schema.)
    if (isDespesaVariavel && (nomeDespesa == null || nomeDespesa.isEmpty)) {
      final itemId = row['itemid'];
      if (itemId != null) {
        try {
          final item = await SupabaseService.selectSingle(
            'item',
            select: 'nome',
            filters: {'itemid': itemId},
          );
          nomeDespesa = item?['nome']?.toString().trim();
        } catch (e) {
          debugPrint('Failed to resolve item.nome for despesavariavel delete (itemid=$itemId): $e');
        }
      }
    }
    final valorMensal = _formatPtBrCurrencyWithThousands(parsePtBrNumber(row['valormensal'])) ?? row['valormensal']?.toString();

    final String message;
    if (isDespesaFixa) {
      message = [
        if (nomeDespesa != null && nomeDespesa.isNotEmpty) 'Despesa fixa - $nomeDespesa',
        if (valorMensal != null && valorMensal.isNotEmpty) 'Valor - R\$ $valorMensal',
        'Esta ação não poderá ser desfeita.',
      ].join('\n');
    } else if (isDespesaVariavel) {
      message = [
        if (nomeDespesa != null && nomeDespesa.isNotEmpty) 'Despesa variável - $nomeDespesa',
        if (valorMensal != null && valorMensal.isNotEmpty) 'Valor - R\$ $valorMensal',
        'Esta ação não poderá ser desfeita.',
      ].join('\n');
    } else if (isCategoria) {
      // Para Categoria, o usuário quer uma confirmação limpa mostrando apenas o nome
      // (via `recordIdentifier`) e a mensagem padrão de irreversibilidade.
      message = 'Esta ação não poderá ser desfeita.';
    } else if (isKit) {
      message = [
        'Atenção: ao excluir o kit, todos os produtos e embalagens configurados para ele também serão excluídos.',
        'Esta ação não poderá ser desfeita.',
      ].join('\n');
    } else {
      message = 'Esta ação não poderá ser desfeita.';
    }

    // Best-effort record identifier for the confirmation sheet.
    // We prefer human-friendly "label" fields over IDs.
    final rawIdentifier = (nomeDespesa?.trim().isNotEmpty ?? false)
        ? nomeDespesa!
        : (
                row['nomefantasia'] ??
                row['razaosocial'] ??
                row['nome'] ??
                row['titulo'] ??
                row['unidade'] ??
                row['descricao'] ??
                row['codigo'] ??
                '')
            .toString()
            .trim();
    // Imposto e taxas: identificar pelo nome da empresa (vem do join empresa:empresaid).
    final empresaJoin = row['empresa'];
    final empresaTaxasNome =
        widget.definition.keyName == 'empresataxas' && empresaJoin is Map ? empresaJoin['nomefantasia']?.toString().trim() : null;
    final identifier = (empresaTaxasNome != null && empresaTaxasNome.isNotEmpty)
        ? empresaTaxasNome
        : (rawIdentifier.isNotEmpty ? rawIdentifier : '#$id');

    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return ConfirmDeleteSheet(
          title: 'Excluir registro?',
          recordIdentifier: identifier,
          message: message,
          confirmLabel: 'Excluir',
          confirmColor: cs.error,
        );
      },
    );
    if (ok != true) return;

    try {
      if (widget.definition.keyName == 'receita' && id is num) {
        await ReceitaService().deleteCascade(id.toInt());
      } else if (widget.definition.keyName == 'kit' && id is num) {
        await KitService().deleteCascade(id.toInt());
      } else {
        await SupabaseService.delete(widget.definition.table, filters: {widget.definition.idColumn: id});
      }
      // Kits usam imposto/taxa adm do empresasetup em cache.
      if (widget.definition.table == 'empresasetup') KitService.clearEmpresaSetupCache();
      // Despesas fixas/variáveis: recalcula o total (só ativas) em `totaldespesas` da empresa logada.
      // `session` já foi lida no início de _delete (antes dos awaits).
      final empresaLogada = session.empresaId;
      String? falhaRecalculo;
      if (empresaLogada != null && widget.definition.table == 'despesafixa') {
        try {
          await TotalDespesasService.recalcularDespesaFixa(empresaLogada);
        } catch (e) {
          debugPrint('Recalc totaldespesafixa after delete failed: $e');
          falhaRecalculo = 'despesas fixas';
        }
      }
      if (empresaLogada != null && widget.definition.table == 'despesavariavel') {
        try {
          await TotalDespesasService.recalcularDespesaVariavel(empresaLogada);
        } catch (e) {
          debugPrint('Recalc totaldespesavariavel after delete failed: $e');
          falhaRecalculo = 'despesas variáveis';
        }
      }
      if (!mounted) return;
      if (falhaRecalculo != null) {
        _avisarFalhaRecalculo('A despesa foi excluída, mas não foi possível atualizar o total de $falhaRecalculo. '
            'Clique em Atualizar para recalcular.');
      }
      // Padrão adotado nos outros cadastros: após excluir, apenas recarrega a lista
      // (sem exibir SnackBar de sucesso, para evitar “poluição” visual).
      await _load();
    } catch (e) {
      debugPrint('Delete ${widget.definition.table} failed: $e');
      if (!mounted) return;

      // Friendlier message for FK violations (empresa/delivery associated in empresadelivery).
      final msg = e.toString().toLowerCase();
      final isFkViolation = msg.contains('foreign key') || msg.contains('violates foreign key') || msg.contains('23503');
      if ((widget.definition.keyName == 'empresa' || widget.definition.keyName == 'delivery') && isFkViolation) {
        final what = widget.definition.keyName == 'empresa' ? 'empresa' : 'delivery';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Não é possível excluir este(a) $what porque está associado(a) a um cadastro de delivery da empresa.')),
        );
        return;
      }

      if (isFkViolation) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não é possível excluir porque este registro está associado a outros dados.')),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível excluir.')));
    }
  }

  /// Verifica se a empresa é referenciada (coluna `empresaid`) em alguma tabela
  /// cadastrada nas definições, exceto [ignoreTable].
  Future<bool> _isEmpresaReferencedElsewhere(int empresaId, {required String ignoreTable}) async {
    final tables = <String>{
      for (final def in Cadastros.all)
        if (def.table != ignoreTable &&
            def.table != 'empresa' &&
            (def.scopedByEmpresa || def.fields.any((f) => f.column == 'empresaid')))
          def.table,
    };
    for (final table in tables) {
      final rows = await SupabaseService.select(table, select: 'empresaid', filters: {'empresaid': empresaId}, limit: 1);
      if (rows.isNotEmpty) {
        debugPrint('Empresa $empresaId referenciada em $table');
        return true;
      }
    }
    return false;
  }

  Future<bool> _hasEmpresaDeliveryAssociation({dynamic empresaId, dynamic deliveryId}) async {
    if (empresaId == null && deliveryId == null) return false;

    // Check existence using a lightweight select+limit.
    if (empresaId != null) {
      final rows = await SupabaseService.select(
        'empresadelivery',
        select: 'empresadeliveryid',
        filters: {'empresaid': empresaId},
        limit: 1,
      );
      if (rows.isNotEmpty) return true;
    }
    if (deliveryId != null) {
      final rows = await SupabaseService.select(
        'empresadelivery',
        select: 'empresadeliveryid',
        filters: {'deliveryid': deliveryId},
        limit: 1,
      );
      if (rows.isNotEmpty) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = context.watch<AppSessionController>();
    final title = widget.definition.title;
    final isBackToCompras = _backLocation == '/compras';
    final isDespesaVariavel = widget.definition.keyName == 'despesavariavel';
    final isDespesaFixa = widget.definition.keyName == 'rateiodespesa';
    final isCategoria = widget.definition.keyName == 'categoria';
    final isIngrediente = widget.definition.keyName == 'ingrediente';
    final isMaterial = widget.definition.keyName == 'material';
    final isReceita = widget.definition.keyName == 'receita';
    final isProduto = widget.definition.keyName == 'produto';
    final isItem = widget.definition.keyName == 'item';
    final isEmpresa = widget.definition.keyName == 'empresa';
    final isEmpresaDelivery = widget.definition.keyName == 'empresadelivery';
    final isKit = widget.definition.keyName == 'kit';

    // Permission: only Super Admin (tipo 'A') can create/delete Empresa.
    final canCreate = !(isEmpresa && !session.isSuperAdmin);

    if (isDespesaVariavel) {
      debugPrint('Render despesavariavel header empresaId=$_empresaIdForDebug total=$_totalDespesaVariavel');
    }

    final totalDespesaVariavelLine = isDespesaVariavel
        ? Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _TotalDespesaVariavelLine(
              total: _totalDespesaVariavel != null ? _formatPtBrCurrencyWithThousands(_totalDespesaVariavel) : null,
            ),
          )
        : const SizedBox.shrink();

    final totalDespesaFixaLine = isDespesaFixa
        ? Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _TotalDespesaFixaLine(
              total: _totalDespesaFixa != null ? _formatPtBrCurrencyWithThousands(_totalDespesaFixa) : null,
            ),
          )
        : const SizedBox.shrink();

    final totalCategoriaRateioLine = isCategoria
        ? Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _TotalCategoriaRateioLine(
              total: _totalCategoriaRateio != null ? _formatPtBrCompactNumber(_totalCategoriaRateio) : null,
            ),
          )
        : const SizedBox.shrink();

    final bool isReceitaChild = _contextReceitaId != null && (isIngrediente || isMaterial);
    final receitaCostsCard = isReceitaChild
        ? Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _ReceitaCostsSummaryCard(
              custoIngredientes: _totalCustoIngredientesReceita,
              custoMateriais: _totalCustoMateriaisReceita,
              actions: StackedListActions(isLoading: _isLoading, onRefresh: _load, onCreate: canCreate ? _openCreate : null),
            ),
          )
        : const SizedBox.shrink();

    final visibleRows = isReceita
        ? _filteredRows
        : (isProduto
              ? _produtoFilteredRows
              : (isItem
                    ? _itemFilteredRows
                    : (isKit && _kitClassificacaoFiltroId != null
                          ? _rows
                              .where((r) => (r['classificacaokitid'] as num?)?.toInt() == _kitClassificacaoFiltroId)
                              .toList(growable: false)
                          : _rows)));

    // UX: when inside a nested context (e.g., Receita -> Ingredientes/Materiais)
    // we already show the count next to the section title. Avoid duplicating it
    // below the actions/filter area.
    final itemsCountLine = (!_isLoading && _error == null && _contextReceitaId == null)
        ? (isKit
              ? Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Preços a serem publicados para o kit',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    // Quantidade de kits em destaque (fundo vermelho).
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.red.shade700,
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: Colors.red.shade700),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                          child: Text(
                            _formatItemsCount(visibleRows.length),
                            key: ValueKey('itemsCount_${widget.definition.keyName}_${visibleRows.length}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.25)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Text(
                          "Imposto: ${_formatPtBrNumber(_empresaSetupImpostoPct) ?? '—'}%",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.primary, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.25)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Text(
                          "Taxa motoboy: ${_empresaSetupTaxaMotoboyPct == null ? '—' : formatPtBrMoney(_empresaSetupTaxaMotoboyPct!, decimalDigits: 2)}%",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.primary, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ],
                )
              : Align(
                  alignment: Alignment.centerRight,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                    child: Text(
                      _formatItemsCount(visibleRows.length),
                      key: ValueKey('itemsCount_${widget.definition.keyName}_${visibleRows.length}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
                    ),
                  ),
                ))
        : const SizedBox.shrink();
    final receitaFilterField = (!isReceita || _contextReceitaId != null)
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.sm),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(AppRadius.xl),
                border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, size: 18, color: cs.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _receitaSearchController,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Filtrar receitas pelo nome',
                          border: InputBorder.none,
                          isDense: true,
                          hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    if (_receitaSearchQuery.trim().isNotEmpty)
                      IconButton(
                        tooltip: 'Limpar filtro',
                        onPressed: () {
                          _receitaSearchController.text = '';
                          FocusScope.of(context).unfocus();
                        },
                        icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant, size: 18),
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                        padding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ),
            ),
          );

    final produtoFilterField = !isProduto
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.sm),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(AppRadius.xl),
                border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, size: 18, color: cs.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _produtoSearchController,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Filtrar produtos pelo nome',
                          border: InputBorder.none,
                          isDense: true,
                          hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    if (_produtoSearchQuery.trim().isNotEmpty)
                      IconButton(
                        tooltip: 'Limpar filtro',
                        onPressed: () {
                          _produtoSearchController.text = '';
                          FocusScope.of(context).unfocus();
                        },
                        icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant, size: 18),
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                        padding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ),
            ),
          );

    // Kit: filtro por classificação (TODOS = sem filtro).
    final kitFilterField = !isKit || _contextReceitaId != null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.sm),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(AppRadius.xl),
                border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.filter_list_rounded, size: 18, color: cs.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Text('Classificação:', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int?>(
                          value: _kitClassificacaoFiltroId,
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem<int?>(value: null, child: Text('TODOS')),
                            for (final c in _kitClassificacoes)
                              if (c['classificacaokitid'] is num)
                                DropdownMenuItem<int?>(
                                  value: (c['classificacaokitid'] as num).toInt(),
                                  child: Text((c['nome'] ?? '').toString(), overflow: TextOverflow.ellipsis),
                                ),
                          ],
                          onChanged: (v) => setState(() => _kitClassificacaoFiltroId = v),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );

    // Item: filtro por tipo (TODOS = sem filtro).
    final itemTipoFilterField = !isItem
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(AppRadius.xl),
                border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.filter_list_rounded, size: 18, color: cs.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Text('Tipo:', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int?>(
                          value: _itemTipoFiltroId,
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem<int?>(value: null, child: Text('TODOS')),
                            for (final t in _itemTipos)
                              if (t['tipoitemid'] is num)
                                DropdownMenuItem<int?>(
                                  value: (t['tipoitemid'] as num).toInt(),
                                  child: Text((t['nome'] ?? '').toString(), overflow: TextOverflow.ellipsis),
                                ),
                          ],
                          onChanged: (v) => setState(() {
                            _itemTipoFiltroId = v;
                            _applyItemFilter();
                          }),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );

    final itemFilterField = !isItem
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.sm),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(AppRadius.xl),
                border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, size: 18, color: cs.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _itemSearchController,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Filtrar itens pelo nome',
                          border: InputBorder.none,
                          isDense: true,
                          hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    if (_itemSearchQuery.trim().isNotEmpty)
                      IconButton(
                        tooltip: 'Limpar filtro',
                        onPressed: () {
                          _itemSearchController.text = '';
                          FocusScope.of(context).unfocus();
                        },
                        icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant, size: 18),
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                        padding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ),
            ),
          );

    Widget content = SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: isBackToCompras
                    ? 'Menu de Compras'
                      : (_backLocation == '/cadastros/receita'
                          ? 'Lista de Receitas'
                          : (_backLocation == '/cadastros-operacional' ? 'Menu de Cadastros operacional' : 'Menu de Cadastros básico')),
                onPressed: () {
                  // Prefer pop to preserve state and let RouteObserver notify the
                  // previous screen (so lists refresh reliably). Fallback to go()
                  // when there is no back stack.
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go(_backLocation);
                  }
                },
                icon: Icon(Icons.arrow_back_rounded, color: cs.onSurface),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            if (_contextReceitaId != null) ...[
              Text(
                _contextReceitaNome ?? 'Receita',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: ((isIngrediente || isMaterial) ? Theme.of(context).textTheme.titleMedium : Theme.of(context).textTheme.labelLarge)
                          ?.copyWith(color: cs.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (visibleRows.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: Text(
                        _formatItemsCount(visibleRows.length),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              ),
              receitaCostsCard,
              totalDespesaVariavelLine,
              totalDespesaFixaLine,
              totalCategoriaRateioLine,
              const SizedBox(height: AppSpacing.md),
              if (!isReceitaChild)
                Row(
                  children: [
                    const Spacer(),
                    StackedListActions(isLoading: _isLoading, onRefresh: _load, onCreate: canCreate ? _openCreate : null),
                  ],
                ),
            ] else ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: isIngrediente ? Theme.of(context).textTheme.headlineMedium : Theme.of(context).textTheme.headlineSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  StackedListActions(
                    isLoading: _isLoading,
                    onRefresh: _load,
                    onCreate: canCreate ? _openCreate : null,
                    leadingActions: [
                      if (isItem)
                        OutlinedButton.icon(
                          onPressed: _isLoading ? null : () => _openItemPdf(visibleRows),
                          icon: Icon(Icons.picture_as_pdf_rounded, color: cs.primary),
                          label: Text('PDF', style: TextStyle(color: cs.primary)),
                        ),
                      if (isKit)
                        OutlinedButton.icon(
                          onPressed: _isLoading ? null : () => _openKitPdf(visibleRows),
                          icon: Icon(Icons.picture_as_pdf_rounded, color: cs.primary),
                          label: Text('PDF', style: TextStyle(color: cs.primary)),
                        ),
                    ],
                  ),
                ],
              ),
              totalDespesaVariavelLine,
              totalDespesaFixaLine,
              totalCategoriaRateioLine,
            ],
            const SizedBox(height: AppSpacing.sm),
            receitaFilterField,
            produtoFilterField,
            itemFilterField,
            itemTipoFilterField,
            kitFilterField,
            const SizedBox(height: AppSpacing.xs),
            itemsCountLine,
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? _ErrorPanel(message: _error!, onRetry: _load)
                  : visibleRows.isEmpty
                  ? const _EmptyPanel()
                  : Scrollbar(
                      controller: _listScrollController,
                      thumbVisibility: true,
                      child: isEmpresaDelivery
                          ? _buildEmpresaDeliveryGroupedList(rows: visibleRows)
                          : ListView.separated(
                              controller: _listScrollController,
                              itemCount: visibleRows.length,
                              // Compact separators so more rows fit without scrolling.
                              separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.xs),
                              itemBuilder: (context, i) {
                                final row = visibleRows[i];
                                return _RowCard(
                                  definition: widget.definition,
                                  row: row,
                                  kitImpostoPct: _empresaSetupImpostoPct,
                                  kitTaxaMotoboyPct: _empresaSetupTaxaMotoboyPct,
                                  kitDeliveries: _kitDeliveries,
                                  onEdit: () => _openEdit(row),
                                  onDelete: () => _delete(row),
                                  onRefreshRequested: _load,
                                );
                              },
                            ),
                    ),
            ),
          ],
        ),
      ),
    );

    // When returning from nested pages, the navigation path may not always hit
    // an explicit refresh callback.
    //
    // - Receita: ensure backend-triggered totals (`custototalingrediente`, etc.)
    //   refresh when coming back from Ingredientes/Materiais.
    // - Produto: NÃO entra aqui. A lista já recarrega explicitamente ao voltar da
    //   tela do produto (await context.push + _load); recarregar também no foco
    //   fazia a lista carregar duas vezes seguidas.
    if (widget.definition.keyName == 'receita' || widget.definition.keyName == 'item') {
      content = Focus(
        autofocus: true,
        onFocusChange: (hasFocus) {
          if (!hasFocus || !mounted || _isLoading) return;

          // Requirement: when the user opens the Receita cadastro list, the filter
          // must start blank so all recipes are shown. Clearing on focus also
          // prevents returning to a partially-filtered list after navigating away.
          if (widget.definition.keyName == 'receita' && _contextReceitaId == null) {
            final hadQuery = _receitaSearchQuery.trim().isNotEmpty || _receitaSearchController.text.trim().isNotEmpty;
            if (hadQuery) {
              setState(() => _setReceitaSearchSilently(''));
            }
          }

          if (widget.definition.keyName == 'produto') {
            final hadQuery = _produtoSearchQuery.trim().isNotEmpty || _produtoSearchController.text.trim().isNotEmpty;
            if (hadQuery) {
              setState(() {
                _produtoSearchController.text = '';
                _produtoSearchQuery = '';
                _applyProdutoFilter();
              });
            }
          }

          if (widget.definition.keyName == 'item') {
            final hadQuery = _itemSearchQuery.trim().isNotEmpty || _itemSearchController.text.trim().isNotEmpty;
            if (hadQuery) {
              setState(() {
                _itemSearchController.text = '';
                _itemSearchQuery = '';
                _applyItemFilter();
              });
            }
          }

          final now = DateTime.now();
          final last = _lastAutoRefresh;
          if (last != null && now.difference(last) < const Duration(milliseconds: 600)) return;
          _lastAutoRefresh = now;
          _load();
        },
        child: content,
      );
    }

    return content;
  }
}

class _TotalDespesaVariavelLine extends StatelessWidget {
  const _TotalDespesaVariavelLine({required this.total});

  final String? total;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final value = (total == null || total!.trim().isEmpty) ? '0,00' : total!.trim();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.summarize_rounded, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Total de despesas variáveis mensais',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'R\$ $value',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalDespesaFixaLine extends StatelessWidget {
  const _TotalDespesaFixaLine({required this.total});

  final String? total;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final value = (total == null || total!.trim().isEmpty) ? '0,00' : total!.trim();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.summarize_rounded, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Total de despesas fixas mensais',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'R\$ $value',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceitaCostsSummaryCard extends StatelessWidget {
  const _ReceitaCostsSummaryCard({required this.custoIngredientes, required this.custoMateriais, this.actions});

  final num? custoIngredientes;
  final num? custoMateriais;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ing = custoIngredientes ?? 0;
    final mat = custoMateriais ?? 0;
    final total = ing + mat;

    String fmt(num? v) => v == null ? '—' : 'R\$ ${_format(v)}';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.summarize_rounded, size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Custos da receita',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
                  ),
                ),
                if (actions != null) ...[
                  const SizedBox(width: 10),
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: actions!,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ReceitaCostMiniCard(icon: Icons.spa, label: 'Ingredientes', value: fmt(custoIngredientes)),
                    const SizedBox(width: 10),
                    _ReceitaCostMiniCard(icon: Icons.all_inbox_rounded, label: 'Materiais', value: fmt(custoMateriais)),
                    const SizedBox(width: 10),
                    _ReceitaCostMiniCard(icon: Icons.summarize, label: 'Total', value: 'R\$ ${_format(total)}', emphasize: true),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _format(num v) {
    // Keep formatting consistent with the rest of this page (pt-BR, thousands).
    final s = v.toStringAsFixed(2);
    // This file already has helper methods in State, but this widget is
    // stateless. Implement minimal formatting here without extra deps.
    final parts = s.split('.');
    final intPart = parts[0];
    final decPart = parts.length > 1 ? parts[1] : '00';
    final buf = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      final idx = intPart.length - i;
      buf.write(intPart[i]);
      if (idx > 1 && idx % 3 == 1) buf.write('.');
    }
    return '${buf.toString()},$decPart';
  }
}

class _ReceitaCostMiniCard extends StatelessWidget {
  const _ReceitaCostMiniCard({required this.icon, required this.label, required this.value, this.emphasize = false});

  final IconData icon;
  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = emphasize ? cs.primary.withValues(alpha: 0.10) : cs.surface.withValues(alpha: 0.65);
    final fg = emphasize ? cs.primary : cs.onSurface;
    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 10),
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalIngredientesReceitaLine extends StatelessWidget {
  const _TotalIngredientesReceitaLine({required this.total});

  final String? total;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final value = (total == null || total!.trim().isEmpty) ? '0,00' : total!.trim();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.functions_rounded, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Custo total dos ingredientes na receita',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'R\$ $value',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalMateriaisReceitaLine extends StatelessWidget {
  const _TotalMateriaisReceitaLine({required this.total});

  final String? total;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final value = (total == null || total!.trim().isEmpty) ? '0,00' : total!.trim();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.functions_rounded, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Custo total dos materiais de preparo da receita',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'R\$ $value',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalCategoriaRateioLine extends StatelessWidget {
  const _TotalCategoriaRateioLine({required this.total});

  /// Formatação pt-BR (ex: "12,5"), sem o símbolo de %.
  final String? total;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final value = (total == null || total!.trim().isEmpty) ? '0' : total!.trim();

    final n = parsePtBrNumber(value) ?? 0;
    final isAbove100 = n > 100;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.percent_rounded, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '% Total de despesas rateadas: ',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
                    ),
                    TextSpan(
                      text: '$value %',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isAbove100) ...[
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Total de despesas rateadas acima de 100%',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  // Force a clearly-red color even if the current theme's `colorScheme.error`
                  // is customized to something less saturated.
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.red, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IngredienteInlineCostsRow extends StatelessWidget {
  const _IngredienteInlineCostsRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final item = row['item'];
    num? custoUnit;
    String? unidadeTxt;
    if (item is Map) {
      final raw = item['custounitario'];
      custoUnit = raw is num ? raw : num.tryParse(raw?.toString() ?? '');

      // Embedded as: item: { ..., unidade: { unidade: 'g' } }
      final unidade = item['unidade'];
      if (unidade is Map) {
        unidadeTxt = unidade['unidade']?.toString().trim();
      } else if (unidade is List && unidade.isNotEmpty && unidade.first is Map) {
        unidadeTxt = (unidade.first as Map)['unidade']?.toString().trim();
      }
    }

    final qtyRaw = row['quantidadegrama'];
    final qtyNum = qtyRaw is num ? qtyRaw : num.tryParse(qtyRaw?.toString() ?? '');
    final qtyTxt = qtyNum == null ? '—' : _formatFixedPtBr(qtyNum, 4);

    num? custoIng;
    final stored = row['custoingrediente'];
    custoIng = stored is num ? stored : num.tryParse(stored?.toString() ?? '');

    final storedIsZero = (custoIng != null && custoIng == 0);
    if ((custoIng == null || storedIsZero) && custoUnit != null && qtyNum != null) {
      final computed = custoUnit * qtyNum;
      if (custoIng == null || (storedIsZero && computed > 0)) custoIng = computed;
    }

    final unitSuffix = (unidadeTxt != null && unidadeTxt!.isNotEmpty && unidadeTxt != 'null') ? ' ${unidadeTxt!.trim()}' : '';
    final custoUnitTxt = custoUnit == null ? '—' : 'R\$ ${_formatCurrencyPtBr(custoUnit, decimals: 4)}';
    final custoIngTxt = custoIng == null ? '—' : 'R\$ ${_formatCurrencyPtBr(custoIng)}';

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _InlineInfoPill(icon: Icons.scale_rounded, label: 'Qtde', value: '$qtyTxt$unitSuffix', colorScheme: cs),
              const SizedBox(width: 8),
              _InlineInfoPill(icon: Icons.request_quote_rounded, label: 'Custo unit.', value: custoUnitTxt, colorScheme: cs),
              const SizedBox(width: 8),
              _InlineInfoPill(icon: Icons.summarize_rounded, label: 'Custo na receita', value: custoIngTxt, colorScheme: cs, emphasize: true),
            ],
          ),
        ),
      ),
    );
  }

  String _formatFixedPtBr(num value, int decimals) => value.toStringAsFixed(decimals).replaceAll('.', ',');

  String _formatCurrencyPtBr(num value, {int decimals = 2}) {
    final negative = value < 0;
    final fixed = value.abs().toStringAsFixed(decimals);
    final parts = fixed.split('.');
    var intPart = parts.first;
    final decPart = parts.length > 1 ? parts.last : ''.padLeft(decimals, '0');

    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      final posFromRight = intPart.length - i;
      buf.write(intPart[i]);
      if (posFromRight > 1 && posFromRight % 3 == 1) buf.write('.');
    }
    intPart = buf.toString();
    final out = decimals <= 0 ? intPart : '$intPart,$decPart';
    return negative ? '-$out' : out;
  }
}

class _MaterialInlineCostsRow extends StatelessWidget {
  const _MaterialInlineCostsRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final item = row['item'];
    num? custoUnit;
    String? unidadeTxt;
    if (item is Map) {
      final raw = item['custounitario'];
      custoUnit = raw is num ? raw : num.tryParse(raw?.toString() ?? '');

      final unidade = item['unidade'];
      if (unidade is Map) {
        unidadeTxt = unidade['unidade']?.toString().trim();
      } else if (unidade is List && unidade.isNotEmpty && unidade.first is Map) {
        unidadeTxt = (unidade.first as Map)['unidade']?.toString().trim();
      }
    }

    final qtyRaw = row['quantidade'];
    final qtyNum = qtyRaw is num ? qtyRaw : num.tryParse(qtyRaw?.toString() ?? '');
    final qtyTxt = qtyNum == null ? '—' : _formatFixedPtBr(qtyNum, 4);

    num? custoMat;
    final stored = row['customaterial'];
    custoMat = stored is num ? stored : num.tryParse(stored?.toString() ?? '');

    final storedIsZero = (custoMat != null && custoMat == 0);
    if ((custoMat == null || storedIsZero) && custoUnit != null && qtyNum != null) {
      final computed = custoUnit * qtyNum;
      if (custoMat == null || (storedIsZero && computed > 0)) custoMat = computed;
    }

    final unitSuffix = (unidadeTxt != null && unidadeTxt!.isNotEmpty && unidadeTxt != 'null') ? ' ${unidadeTxt!.trim()}' : '';
    final custoUnitTxt = custoUnit == null ? '—' : 'R\$ ${_formatCurrencyPtBr(custoUnit, decimals: 4)}';
    final custoMatTxt = custoMat == null ? '—' : 'R\$ ${_formatCurrencyPtBr(custoMat)}';

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _InlineInfoPill(icon: Icons.scale_rounded, label: 'Qtde', value: '$qtyTxt$unitSuffix', colorScheme: cs),
              const SizedBox(width: 8),
              _InlineInfoPill(icon: Icons.request_quote_rounded, label: 'Custo unit.', value: custoUnitTxt, colorScheme: cs),
              const SizedBox(width: 8),
              _InlineInfoPill(icon: Icons.summarize_rounded, label: 'Custo na receita', value: custoMatTxt, colorScheme: cs, emphasize: true),
            ],
          ),
        ),
      ),
    );
  }

  String _formatFixedPtBr(num value, int decimals) => value.toStringAsFixed(decimals).replaceAll('.', ',');

  String _formatCurrencyPtBr(num value, {int decimals = 2}) {
    final negative = value < 0;
    final fixed = value.abs().toStringAsFixed(decimals);
    final parts = fixed.split('.');
    var intPart = parts.first;
    final decPart = parts.length > 1 ? parts.last : ''.padLeft(decimals, '0');

    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      final posFromRight = intPart.length - i;
      buf.write(intPart[i]);
      if (posFromRight > 1 && posFromRight % 3 == 1) buf.write('.');
    }
    intPart = buf.toString();
    final out = decimals <= 0 ? intPart : '$intPart,$decPart';
    return negative ? '-$out' : out;
  }
}

class _DespesaVariavelInlineInfoRow extends StatelessWidget {
  const _DespesaVariavelInlineInfoRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final item = row['item'];
    num? custoUnit;
    String? unidadeTxt;
    if (item is Map) {
      final raw = item['custounitario'];
      custoUnit = raw is num ? raw : num.tryParse(raw?.toString() ?? '');

      final unidade = item['unidade'];
      if (unidade is Map) {
        unidadeTxt = unidade['unidade']?.toString().trim();
      } else if (unidade is List && unidade.isNotEmpty && unidade.first is Map) {
        unidadeTxt = (unidade.first as Map)['unidade']?.toString().trim();
      }
    }

    final consumoRaw = row['consumomensal'];
    final consumoNum = consumoRaw is num ? consumoRaw : num.tryParse(consumoRaw?.toString() ?? '');
    final consumoTxt = consumoNum == null ? '—' : _formatFixedPtBr(consumoNum, 4);

    final valorRaw = row['valormensal'];
    final valorNum = valorRaw is num ? valorRaw : num.tryParse(valorRaw?.toString() ?? '');
    final valorTxt = valorNum == null ? '—' : 'R\$ ${_formatCurrencyPtBr(valorNum)}';

    final unitClean = (unidadeTxt == null || unidadeTxt!.trim().isEmpty || unidadeTxt == 'null') ? null : unidadeTxt!.trim();
    final consumoSuffix = unitClean == null ? '' : ' $unitClean';

    final custoUnitTxt = custoUnit == null ? '—' : 'R\$ ${_formatCurrencyPtBr(custoUnit, decimals: 4)}';
    final unitSuffix = unitClean == null ? '' : '/$unitClean';

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _InlineInfoPill(icon: Icons.scale_rounded, label: 'Consumo mensal', value: '$consumoTxt$consumoSuffix', colorScheme: cs),
              const SizedBox(width: 8),
              _InlineInfoPill(icon: Icons.request_quote_rounded, label: 'Custo unit.', value: '$custoUnitTxt$unitSuffix', colorScheme: cs),
              const SizedBox(width: 8),
              _InlineInfoPill(icon: Icons.summarize_rounded, label: 'Total/mês', value: valorTxt, colorScheme: cs, emphasize: true),
            ],
          ),
        ),
      ),
    );
  }

  String _formatFixedPtBr(num value, int decimals) => value.toStringAsFixed(decimals).replaceAll('.', ',');

  String _formatCurrencyPtBr(num value, {int decimals = 2}) {
    final negative = value < 0;
    final fixed = value.abs().toStringAsFixed(decimals);
    final parts = fixed.split('.');
    var intPart = parts.first;
    final decPart = parts.length > 1 ? parts.last : ''.padLeft(decimals, '0');

    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      final posFromRight = intPart.length - i;
      buf.write(intPart[i]);
      if (posFromRight > 1 && posFromRight % 3 == 1) buf.write('.');
    }
    intPart = buf.toString();
    final out = decimals <= 0 ? intPart : '$intPart,$decPart';
    return negative ? '-$out' : out;
  }
}

class _DespesaVariavelInlineInfoPills extends StatelessWidget {
  const _DespesaVariavelInlineInfoPills({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final item = row['item'];
    num? custoUnit;
    String? unidadeTxt;
    if (item is Map) {
      final raw = item['custounitario'];
      custoUnit = raw is num ? raw : num.tryParse(raw?.toString() ?? '');

      final unidade = item['unidade'];
      if (unidade is Map) {
        unidadeTxt = unidade['unidade']?.toString().trim();
      } else if (unidade is List && unidade.isNotEmpty && unidade.first is Map) {
        unidadeTxt = (unidade.first as Map)['unidade']?.toString().trim();
      }
    }

    final consumoRaw = row['consumomensal'];
    final consumoNum = consumoRaw is num ? consumoRaw : num.tryParse(consumoRaw?.toString() ?? '');
    final consumoTxt = consumoNum == null ? '—' : consumoNum.toStringAsFixed(4).replaceAll('.', ',');

    final valorRaw = row['valormensal'];
    final valorNum = valorRaw is num ? valorRaw : num.tryParse(valorRaw?.toString() ?? '');
    final valorTxt = valorNum == null ? '—' : 'R\$ ${_formatCurrencyPtBr(valorNum)}';

    final unitClean = (unidadeTxt == null || unidadeTxt!.trim().isEmpty || unidadeTxt == 'null') ? null : unidadeTxt!.trim();
    final consumoSuffix = unitClean == null ? '' : ' $unitClean';

    final custoUnitTxt = custoUnit == null ? '—' : 'R\$ ${_formatCurrencyPtBr(custoUnit, decimals: 4)}';
    final unitSuffix = unitClean == null ? '' : '/$unitClean';

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _InlineInfoPill(icon: Icons.scale_rounded, label: 'Consumo mensal', value: '$consumoTxt$consumoSuffix', colorScheme: cs),
        _InlineInfoPill(icon: Icons.request_quote_rounded, label: 'Custo unit.', value: '$custoUnitTxt$unitSuffix', colorScheme: cs),
        _InlineInfoPill(icon: Icons.summarize_rounded, label: 'Total/mês', value: valorTxt, colorScheme: cs, emphasize: true),
      ],
    );
  }

  String _formatCurrencyPtBr(num value, {int decimals = 2}) {
    final negative = value < 0;
    final fixed = value.abs().toStringAsFixed(decimals);
    final parts = fixed.split('.');
    var intPart = parts.first;
    final decPart = parts.length > 1 ? parts.last : ''.padLeft(decimals, '0');

    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      final posFromRight = intPart.length - i;
      buf.write(intPart[i]);
      if (posFromRight > 1 && posFromRight % 3 == 1) buf.write('.');
    }
    intPart = buf.toString();
    final out = decimals <= 0 ? intPart : '$intPart,$decPart';
    return negative ? '-$out' : out;
  }
}

class _ItemInlineInfoPills extends StatelessWidget {
  const _ItemInlineInfoPills({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    String? marcaNome = _relatedNome(row['marca']);
    marcaNome ??= row['marcaid']?.toString().trim();
    if (marcaNome == 'null' || (marcaNome?.isEmpty ?? true)) marcaNome = null;

    String? tipoNome = _relatedNome(row['tipoitem']);
    tipoNome ??= row['tipoitemid']?.toString().trim();
    if (tipoNome == 'null' || (tipoNome?.isEmpty ?? true)) tipoNome = null;

    String? unidadeTxt = _relatedStringField(row['unidade'], 'unidade');
    unidadeTxt ??= row['unidadeid']?.toString().trim();
    if (unidadeTxt == 'null' || (unidadeTxt?.isEmpty ?? true)) unidadeTxt = null;

    final rawCusto = row['custounitario'];
    final custoUnit = rawCusto is num ? rawCusto : num.tryParse(rawCusto?.toString() ?? '');
    final custoTxt = custoUnit == null ? null : 'R\$ ${_formatCurrencyPtBr(custoUnit, decimals: 4)}';
    final custoSuffix = (unidadeTxt == null) ? '' : '/${unidadeTxt!.trim()}';

    final pills = <Widget>[];
    if (unidadeTxt != null) pills.add(_InlineInfoPill(icon: Icons.straighten_rounded, label: 'Unid', value: unidadeTxt!, colorScheme: cs));
    if (marcaNome != null) pills.add(_InlineInfoPill(icon: Icons.sell_rounded, label: 'Marca', value: marcaNome!, colorScheme: cs));
    if (tipoNome != null) pills.add(_InlineInfoPill(icon: Icons.category_rounded, label: 'Tipo', value: tipoNome!, colorScheme: cs));
    if (custoTxt != null) pills.add(_InlineInfoPill(icon: Icons.request_quote_rounded, label: 'Custo unit.', value: '$custoTxt$custoSuffix', colorScheme: cs));

    if (pills.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: pills,
      ),
    );
  }

  String? _relatedNome(Object? related) {
    if (related is Map) {
      final nome = related['nome']?.toString().trim();
      return (nome == null || nome.isEmpty) ? null : nome;
    }
    if (related is List && related.isNotEmpty) {
      final first = related.first;
      if (first is Map) {
        final nome = first['nome']?.toString().trim();
        return (nome == null || nome.isEmpty) ? null : nome;
      }
    }
    return null;
  }

  String? _relatedStringField(Object? related, String field) {
    if (related is Map) {
      final v = related[field]?.toString().trim();
      return (v == null || v.isEmpty) ? null : v;
    }
    if (related is List && related.isNotEmpty) {
      final first = related.first;
      if (first is Map) {
        final v = first[field]?.toString().trim();
        return (v == null || v.isEmpty) ? null : v;
      }
    }
    return null;
  }

  String _formatCurrencyPtBr(num value, {int decimals = 2}) {
    final negative = value < 0;
    final fixed = value.abs().toStringAsFixed(decimals);
    final parts = fixed.split('.');
    var intPart = parts.first;
    final decPart = parts.length > 1 ? parts.last : ''.padLeft(decimals, '0');

    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      final posFromRight = intPart.length - i;
      buf.write(intPart[i]);
      if (posFromRight > 1 && posFromRight % 3 == 1) buf.write('.');
    }
    intPart = buf.toString();
    final out = decimals <= 0 ? intPart : '$intPart,$decPart';
    return negative ? '-$out' : out;
  }
}

class _ReceitaInlineCostsRow extends StatelessWidget {
  const _ReceitaInlineCostsRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Preferir os campos persistidos na tabela `receita`.
    final ing = row['custototalingrediente'] ?? row['_custo_total_ingredientes'];
    final mat = row['custototalmaterial'] ?? row['_custo_total_materiais'];
    final total = row['custoreceita'] ?? row['_custo_total_receita'];

    final ingTxt = _formatCurrency(ing);
    final matTxt = _formatCurrency(mat);
    final totalTxt = _formatCurrency(total);

    if (ingTxt == null && matTxt == null && totalTxt == null) return const SizedBox.shrink();

    Widget pill({required IconData icon, required String label, required String value, bool emphasize = false}) =>
        _InlineInfoPill(icon: icon, label: label, value: value, colorScheme: cs, emphasize: emphasize);

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outline.withValues(alpha: 0.12)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (ingTxt != null) pill(icon: Icons.restaurant_rounded, label: 'Ing', value: 'R\$ $ingTxt'),
              if (ingTxt != null && (matTxt != null || totalTxt != null)) const SizedBox(width: AppSpacing.sm),
              if (matTxt != null) pill(icon: Icons.handyman_rounded, label: 'Mat', value: 'R\$ $matTxt'),
              if (matTxt != null && totalTxt != null) const SizedBox(width: AppSpacing.sm),
              if (totalTxt != null) pill(icon: Icons.receipt_long_rounded, label: 'Tot', value: 'R\$ $totalTxt', emphasize: true),
            ],
          ),
        ),
      ),
    );
  }

  String? _formatCurrency(Object? value, {int decimals = 2}) {
    if (value == null) return null;
    final n = value is num ? value : num.tryParse(value.toString());
    if (n == null) return null;

    final negative = n < 0;
    final fixed = n.abs().toStringAsFixed(decimals);
    final parts = fixed.split('.');
    var intPart = parts.first;
    final decPart = parts.length > 1 ? parts.last : ''.padLeft(decimals, '0');

    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      final posFromRight = intPart.length - i;
      buf.write(intPart[i]);
      if (posFromRight > 1 && posFromRight % 3 == 1) buf.write('.');
    }
    intPart = buf.toString();
    final out = decimals <= 0 ? intPart : '$intPart,$decPart';
    return negative ? '-$out' : out;
  }
}

class _KitInlineInfoRow extends StatefulWidget {
  const _KitInlineInfoRow({required this.row, this.impostoPct, this.taxaMotoboyPct, this.deliveries = const []});

  final Map<String, dynamic> row;

  /// Valores exibidos no topo da lista de kits (cards Imposto e Taxa motoboy).
  final num? impostoPct;
  final num? taxaMotoboyPct;

  /// Deliveries ativos da empresa logada: uma linha por delivery em cada kit.
  final List<_KitDelivery> deliveries;

  @override
  State<_KitInlineInfoRow> createState() => _KitInlineInfoRowState();
}

class _KitInlineInfoRowState extends State<_KitInlineInfoRow> {
  Future<KitTotals?>? _future;

  @override
  void initState() {
    super.initState();
    _prime();
  }

  @override
  void didUpdateWidget(covariant _KitInlineInfoRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Recarrega os totais quando a linha muda (outro kit ou lista recarregada do banco,
    // ex.: ao voltar da tela de edição do kit com produtos/embalagens alterados).
    if (!identical(oldWidget.row, widget.row)) _prime();
  }

  void _prime() {
    final id = widget.row['kitid'];
    if (id is! num) {
      _future = null;
      return;
    }
    // Keep totals loading independent from the list fetch. This avoids needing
    // extra columns in `kit` and keeps the UI consistent with the edit screen.
    final empresaRaw = widget.row['empresaid'];
    final empresaId = empresaRaw is num ? empresaRaw.toInt() : context.read<AppSessionController>().empresaId;
    _future = KitService().loadTotals(id.toInt(), empresaId: empresaId).then((v) => v).catchError((_) => null);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final desc = widget.row['descricao']?.toString().trim();

    Widget descriptionChip() => _DescricaoChip(texto: desc);

    final future = _future;
    Widget totalsRow() {
      if (future == null) return const SizedBox.shrink();
      return FutureBuilder<KitTotals?>(
        future: future,
        builder: (context, snap) {
          final totals = snap.data;
          if (snap.connectionState == ConnectionState.waiting) {
            return Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: cs.outline.withValues(alpha: 0.12)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(width: 10),
                  Text('Carregando totais…', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25)),
                ],
              ),
            );
          }

          final prod = totals?.totalKitComTaxa;
          // O I.R. não é mais exibido por kit (só entra no cálculo do valor de lista do site).
          if (prod == null) return const SizedBox.shrink();
          // Valor de lista do site = valor total do kit / (1 - imposto/100 - taxa motoboy/100),
          // usando os percentuais exibidos no topo da lista.
          final imposto = widget.impostoPct;
          final divisor = imposto == null ? null : 1 - imposto / 100 - (widget.taxaMotoboyPct ?? 0) / 100;
          final valorListaSite = (divisor != null && divisor > 0) ? prod / divisor : null;

          Widget line(List<Widget> pills) => Container(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: cs.outline.withValues(alpha: 0.12)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(mainAxisSize: MainAxisSize.min, children: pills),
                  ),
                ),
              );

          // Uma linha por delivery: valor total do kit / (1 - taxa delivery/100 - imposto/100).
          final deliveryLines = <Widget>[
            for (final d in widget.deliveries)
              Builder(builder: (context) {
                final taxa = d.taxaPct;
                final div = (imposto == null || taxa == null) ? null : 1 - taxa / 100 - imposto / 100;
                final valorLista = (div != null && div > 0) ? prod / div : null;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: line([
                    _InlineInfoPill(icon: Icons.delivery_dining_rounded, label: 'Nome', value: d.nome, colorScheme: cs),
                    const SizedBox(width: AppSpacing.sm),
                    _InlineInfoPill(
                      label: 'Taxa de delivery - %',
                      value: taxa == null ? '—' : formatPtBrMoney(taxa, decimalDigits: 2),
                      colorScheme: cs,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _InlineInfoPill(
                      icon: Icons.storefront_rounded,
                      label: 'Valor de lista para ${d.nome} - R\$',
                      value: valorLista == null ? '—' : formatPtBrCurrency(valorLista),
                      colorScheme: cs,
                    ),
                  ]),
                );
              }),
          ];

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              line([
                    _InlineInfoPill(
                      icon: Icons.shopping_bag_rounded,
                      label: 'Valor total do kit - R\$',
                      value: formatPtBrCurrency(prod),
                      colorScheme: cs,
                    ),
                    if (valorListaSite != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      _InlineInfoPill(
                        icon: Icons.storefront_rounded,
                        label: 'Valor de lista do site - R\$',
                        value: formatPtBrCurrency(valorListaSite),
                        colorScheme: cs,
                      ),
                    ],
              ]),
              ...deliveryLines,
            ],
          );
        },
      );
    }

    final hasDesc = desc != null && desc.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasDesc) descriptionChip(),
        if (hasDesc) const SizedBox(height: 6),
        totalsRow(),
      ],
    );
  }
}

/// Descrição completa (kit/produto) em um card abaixo do nome: quebra em várias
/// linhas e mantém as quebras de linha digitadas.
class _DescricaoChip extends StatelessWidget {
  const _DescricaoChip({required this.texto});
  final String? texto;

  @override
  Widget build(BuildContext context) {
    final desc = texto?.trim();
    if (desc == null || desc.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outline.withValues(alpha: 0.12)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.inventory_2_rounded, size: 16, color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              desc,
              softWrap: true,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25),
            ),
          ),
        ],
      ),
    );
  }
}

/// Produto: dados em cards numa única linha (encolhe para caber em telas estreitas).
class _ProdutoInlineInfoPills extends StatelessWidget {
  const _ProdutoInlineInfoPills({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final codigo = row['codigo']?.toString().trim();
    final categoria = row['categoria'];
    final categoriaNome = categoria is Map ? categoria['nome']?.toString().trim() : null;
    final custoProducao = parsePtBrNumber(row['_custo_producao']);
    final qtd = parsePtBrNumber(row['qtdproduzida']);
    final qtdTxt = qtd == null ? null : (qtd == qtd.roundToDouble() ? qtd.toInt().toString() : formatPtBrMoney(qtd));

    final pills = <Widget>[
      if (codigo != null && codigo.isNotEmpty)
        _InlineInfoPill(icon: Icons.tag_rounded, label: 'Código', value: codigo, colorScheme: cs),
      if (categoriaNome != null && categoriaNome.isNotEmpty)
        _InlineInfoPill(
          icon: Icons.category_rounded,
          label: 'Categoria',
          value: categoriaNome,
          colorScheme: cs,
          backgroundColor: Colors.green.shade700,
          foregroundColor: Colors.white,
        ),
      if (custoProducao != null)
        _InlineInfoPill(icon: Icons.request_quote_rounded, label: 'Custo de produção', value: formatPtBrCurrency(custoProducao), colorScheme: cs),
      if (qtdTxt != null)
        _InlineInfoPill(icon: Icons.inventory_rounded, label: 'Qtd produzida', value: qtdTxt, colorScheme: cs),
    ];
    if (pills.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < pills.length; i++) ...[
                if (i > 0) const SizedBox(width: AppSpacing.sm),
                pills[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Delivery ativo da empresa (empresadelivery + delivery.nome) usado na lista de kits.
class _KitDelivery {
  const _KitDelivery({required this.nome, this.taxaPct});
  final String nome;
  final num? taxaPct;
}

/// Mantido por compatibilidade: delega ao componente compartilhado [InfoPill].
class _InlineInfoPill extends StatelessWidget {
  const _InlineInfoPill({
    this.icon,
    required this.label,
    required this.value,
    required this.colorScheme,
    this.emphasize = false,
    this.backgroundColor,
    this.foregroundColor,
  });

  final IconData? icon;
  final String label;
  final String value;
  final ColorScheme colorScheme;
  final bool emphasize;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) => InfoPill(
        icon: icon,
        label: label,
        value: value,
        emphasize: emphasize,
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
      );
}

class _RowCard extends StatelessWidget {
  const _RowCard({
    required this.definition,
    required this.row,
    required this.onEdit,
    required this.onDelete,
    this.onRefreshRequested,
    this.kitImpostoPct,
    this.kitTaxaMotoboyPct,
    this.kitDeliveries = const [],
  });

  final CadastroDefinition definition;
  final Map<String, dynamic> row;

  /// Kit: imposto e taxa motoboy exibidos no topo da lista (empresa logada).
  final num? kitImpostoPct;
  final num? kitTaxaMotoboyPct;
  final List<_KitDelivery> kitDeliveries;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onRefreshRequested;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final isEmpresa = definition.keyName == 'empresa';
    final isUsuario = definition.keyName == 'usuario';
    final isMarca = definition.keyName == 'marca';
    final isItem = definition.keyName == 'item';
    final isRateio = definition.keyName == 'rateiodespesa';
    final isDespesaVariavel = definition.keyName == 'despesavariavel';
    final isProduto = definition.keyName == 'produto';
    final isKit = definition.keyName == 'kit';
    final isReceita = definition.keyName == 'receita';
    final isIngrediente = definition.keyName == 'ingrediente';
    final isMaterial = definition.keyName == 'material';
    final isFornecedor = definition.keyName == 'fornecedor';
    final isCategoria = definition.keyName == 'categoria';

    final empresaRazao = isEmpresa ? row['razaosocial']?.toString().trim() : null;
    final empresaTipoDoc = isEmpresa ? row['tipodocumento']?.toString().trim().toUpperCase() : null;
    final empresaCnpjRaw = isEmpresa ? row['cnpj']?.toString().trim() : null;
    final empresaCpfRaw = isEmpresa ? row['cpf']?.toString().trim() : null;
    final empresaCnpj = isEmpresa ? _formatCnpj(empresaCnpjRaw) : null;
    final empresaCpf = isEmpresa ? _formatCpf(empresaCpfRaw) : null;

    final fornecedorRazao = isFornecedor ? row['razaosocial']?.toString().trim() : null;
    final fornecedorTipoDoc = isFornecedor ? row['tipodocumento']?.toString().trim().toUpperCase() : null;
    final fornecedorCnpjRaw = isFornecedor ? row['cnpj']?.toString().trim() : null;
    final fornecedorCpfRaw = isFornecedor ? row['cpf']?.toString().trim() : null;
    final fornecedorCnpj = isFornecedor ? _formatCnpj(fornecedorCnpjRaw) : null;
    final fornecedorCpf = isFornecedor ? _formatCpf(fornecedorCpfRaw) : null;

    final isInativo = (row['status'] ?? '').toString().trim().toUpperCase() == 'I';

    final empresaDocumento = isEmpresa
        ? (empresaTipoDoc == 'J' ? empresaCnpj : empresaCpf)
        : null;

    final fornecedorDocumento = isFornecedor
        ? (fornecedorTipoDoc == 'F' ? fornecedorCpf : fornecedorCnpj)
        : null;

    final usuarioEmail = isUsuario ? row['email']?.toString().trim() : null;
    final usuarioTipo = isUsuario ? _tipoUsuarioLabel(row['tipousuario']?.toString()) : null;

    final titleText = _titleText(definition, row);
    final subtitleText = _subtitleText(definition, row);
    final titleStyle = _titleStyle(context, definition);

    // UX: economizar espaço colocando os ícones de editar/excluir na mesma linha
    // do título/descrição para cadastros usados com frequência.
    final isDespesaFixaCadastro = definition.table == 'despesafixa' || definition.keyName == 'rateiodespesa';
    final isDespesaVariavelCadastro = definition.table == 'despesavariavel' || definition.keyName == 'despesavariavel';

    // UI: em Despesas Fixas, exibir também o custo (R$) na mesma linha do título.
    // Nota: a coluna monetária é `valormensal`.
    final despesaFixaCustoTxt = isDespesaFixaCadastro
        ? _formatPtBrCurrencyWithThousands(parsePtBrNumber(row['valormensal'])) ?? row['valormensal']?.toString()
        : null;

    final embedActionsInTitleLine =
        isItem ||
        isProduto ||
        isKit ||
        isReceita ||
        isIngrediente ||
        isMaterial ||
        isRateio ||
        isDespesaFixaCadastro ||
        isDespesaVariavelCadastro;

    if (kDebugMode && (isDespesaFixaCadastro || isDespesaVariavelCadastro)) {
      debugPrint(
        'GenericCadastroListPage:_RowCard embedActionsInTitleLine=$embedActionsInTitleLine keyName=${definition.keyName} table=${definition.table}',
      );
    }

    final categoriaQuantidade = isCategoria ? _formatPtBrNumber(row['quantidadeproducaomes']) : null;
    final categoriaRateio = isCategoria ? _formatPtBrNumber(row['percentualrateiodespesa']) : null;
    final categoriaLucro = isCategoria ? _formatPtBrNumber(row['percentuallucro']) : null;

    // Despesas Fixas: o selo INATIVO é exibido na própria linha (junto do card Custo),
    // mais abaixo; por isso não entram aqui.
    final showInactiveOnlyBadge = (isEmpresa || isUsuario || isFornecedor) && isInativo;
    // Seguir o padrão dos outros cadastros — só mostrar quando estiver inativo.
    final showProdutoBadge = isProduto && isInativo;
    final showKitBadge = isKit && isInativo;
    final showReceitaBadge = isReceita && isInativo;

    // Generic fallback lines (used only when the cadastro doesn't have a tailored subtitle).
    // Important: avoid repeating the title value (usually the "nome") as a second line.
    final lines = <String>[];
    if (!isEmpresa && !isUsuario && !isMarca && !isItem && !isRateio && !isProduto && !isKit && !isReceita && !isFornecedor) {
      for (final col in definition.displayColumns) {
        if (col == definition.idColumn) continue;
        final v = row[col];
        if (v == null) continue;
        final txt = _formatListValue(definition, col, v).trim();
        if (txt.isEmpty) continue;
        if (txt == titleText) continue;
        lines.add('${_pretty(col)}: $txt');
        if (lines.length >= 3) break;
      }
    }

    // Kit: card "Classificação" ao lado do nome (classificacaokit.nome via join).
    final classificacaoJoin = row['classificacao'];
    final kitClassificacaoNome =
        isKit && classificacaoJoin is Map ? classificacaoJoin['nome']?.toString().trim() : null;
    Widget titleWithKitClassificacao(Widget title) {
      if (kitClassificacaoNome == null || kitClassificacaoNome.isEmpty) return title;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(child: title),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: _InlineInfoPill(
              icon: Icons.label_rounded,
              label: 'Classificação',
              value: kitClassificacaoNome,
              colorScheme: cs,
              backgroundColor: Colors.green.shade700,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
      ),
      child: Padding(
        // More compact internal spacing so more cards fit on screen.
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showInactiveOnlyBadge || showProdutoBadge || showKitBadge || showReceitaBadge)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: titleWithKitClassificacao(Text(
                            titleText,
                            // Receita names can be long; allow up to 2 lines.
                            maxLines: isReceita ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          )),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        const _StatusBadge(text: 'INATIVO'),
                        if (embedActionsInTitleLine) ...[
                          const SizedBox(width: AppSpacing.sm),
                          _RowActions(
                            definition: definition,
                            row: row,
                            onEdit: onEdit,
                            onDelete: onDelete,
                            onRefreshRequested: onRefreshRequested,
                            horizontal: true,
                          ),
                        ],
                      ],
                    )
                  else if (embedActionsInTitleLine)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          // Despesa variável: nome na 1ª linha e os cards de valores sempre na 2ª.
                          child: isDespesaVariavelCadastro
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      titleText,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: titleStyle,
                                    ),
                                    const SizedBox(height: 6),
                                    _DespesaVariavelInlineInfoPills(row: row),
                                  ],
                                )
                              : isItem
                                   ? Column(
                                       crossAxisAlignment: CrossAxisAlignment.start,
                                       children: [
                                         Text(
                                           titleText,
                                           maxLines: 1,
                                           overflow: TextOverflow.ellipsis,
                                           style: titleStyle,
                                         ),
                                         _ItemInlineInfoPills(row: row),
                                       ],
                                     )
                              : titleWithKitClassificacao(Text(
                                  titleText,
                                  // Receita names can be long; allow up to 2 lines.
                                  maxLines: isReceita ? 2 : 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: titleStyle,
                                )),
                        ),
                        if (isDespesaFixaCadastro && (despesaFixaCustoTxt?.trim().isNotEmpty ?? false)) ...[
                          const SizedBox(width: AppSpacing.sm),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 190),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: _InlineInfoPill(
                                icon: Icons.payments_rounded,
                                label: 'Custo',
                                value: 'R\$ ${despesaFixaCustoTxt!.trim()}',
                                colorScheme: cs,
                                emphasize: true,
                              ),
                            ),
                          ),
                        ],
                        // Despesa fixa/variável inativa (status = 'I').
                        if ((isDespesaFixaCadastro || isDespesaVariavelCadastro) && isInativo) ...[
                          const SizedBox(width: AppSpacing.sm),
                          const _StatusBadge(text: 'INATIVO'),
                        ],
                        const SizedBox(width: AppSpacing.sm),
                        _RowActions(definition: definition, row: row, onEdit: onEdit, onDelete: onDelete, onRefreshRequested: onRefreshRequested, horizontal: true),
                      ],
                    )
                  else
                    Text(
                      titleText,
                      // Receita names can be long; allow up to 2 lines.
                      maxLines: isReceita ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                  const SizedBox(height: 4),
                  if (isEmpresa) ...[
                    if (empresaRazao != null && empresaRazao.isNotEmpty)
                      Text(
                        empresaRazao,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        // Same size as CNPJ and without bold, as requested.
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurface, height: 1.25),
                      ),
                    if (empresaDocumento != null && empresaDocumento.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        empresaDocumento,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25),
                      ),
                    ],
                  ] else if (isFornecedor) ...[
                    if (fornecedorRazao != null && fornecedorRazao.isNotEmpty)
                      Text(
                        fornecedorRazao,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurface, height: 1.25),
                      ),
                    if (fornecedorDocumento != null && fornecedorDocumento.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        fornecedorDocumento,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25),
                      ),
                    ],
                  ] else if (isUsuario) ...[
                    if (usuarioEmail != null && usuarioEmail.isNotEmpty)
                      Text(
                        usuarioEmail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25),
                      ),
                    if (usuarioTipo != null && usuarioTipo.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        usuarioTipo,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurface, height: 1.25),
                      ),
                    ],
                  ] else if (isCategoria) ...[
                    if (categoriaQuantidade != null && categoriaQuantidade.isNotEmpty)
                      Text(
                        'Quantidade produção/mês: $categoriaQuantidade',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25),
                      ),
                    if ((categoriaRateio != null && categoriaRateio.isNotEmpty) || (categoriaLucro != null && categoriaLucro.isNotEmpty)) ...[
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (categoriaRateio != null && categoriaRateio.isNotEmpty) 'Rateio despesa (%): $categoriaRateio',
                          if (categoriaLucro != null && categoriaLucro.isNotEmpty) 'Lucro (%): $categoriaLucro',
                        ].join(' • '),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25),
                      ),
                    ],
                  ] else if (isIngrediente)
                    _IngredienteInlineCostsRow(row: row)
                  else if (isMaterial)
                    _MaterialInlineCostsRow(row: row)
                  else if (isDespesaVariavel)
                    const SizedBox.shrink()
                  else if (isReceita)
                    // Receita: descrição completa abaixo do nome (mesmo padrão de kit/produto).
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ((row['descricao']?.toString().trim() ?? '').isNotEmpty) ...[
                          const SizedBox(height: 6),
                          _DescricaoChip(texto: row['descricao']?.toString()),
                        ],
                        _ReceitaInlineCostsRow(row: row),
                      ],
                    )
                  else if (isProduto)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ((row['descricao']?.toString().trim() ?? '').isNotEmpty) ...[
                          const SizedBox(height: 6),
                          _DescricaoChip(texto: row['descricao']?.toString()),
                        ],
                        _ProdutoInlineInfoPills(row: row),
                      ],
                    )
                  else if (isKit)
                    _KitInlineInfoRow(row: row, impostoPct: kitImpostoPct, taxaMotoboyPct: kitTaxaMotoboyPct, deliveries: kitDeliveries)
                  else if (subtitleText != null && subtitleText.isNotEmpty)
                    Text(subtitleText, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25))
                  else if (lines.isNotEmpty)
                    Text(
                      lines.join(' • '),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25),
                    ),
                ],
              ),
            ),
            if (!embedActionsInTitleLine) ...[
              const SizedBox(width: AppSpacing.sm),
              _RowActions(definition: definition, row: row, onEdit: onEdit, onDelete: onDelete, onRefreshRequested: onRefreshRequested),
            ],
          ],
        ),
      ),
    );
  }

  String _primaryTitle(CadastroDefinition def, Map<String, dynamic> row) {
    if (def.keyName == 'ingrediente' || def.keyName == 'material') {
      final item = row['item'];
      if (item is Map) {
        final nome = item['nome']?.toString().trim();
        if (nome != null && nome.isNotEmpty) return nome;
      }
      final id = row['itemid'];
      if (id != null) return 'Item #$id';
    }
    for (final c in def.displayColumns) {
      final v = row[c];
      if (v == null) continue;
      final t = v.toString().trim();
      if (t.isEmpty) continue;
      return t;
    }
    return 'Registro';
  }

  String _titleText(CadastroDefinition def, Map<String, dynamic> row) {
    if (def.keyName == 'empresataxas') {
      final empresaNome = _relatedStringField(row['empresa'], 'nomefantasia');
      if (empresaNome != null && empresaNome.isNotEmpty) return empresaNome;
      final empresaId = row['empresaid'];
      return empresaId != null ? 'Empresa #$empresaId' : 'Empresa';
    }
    if (def.keyName == 'empresadelivery') {
      final empresaNome = _relatedStringField(row['empresa'], 'nomefantasia');
      final deliveryNome = _relatedStringField(row['delivery'], 'nome');
      final empresaId = row['empresaid'];
      final deliveryId = row['deliveryid'];

      final left = (empresaNome != null && empresaNome.isNotEmpty)
          ? empresaNome
          : (empresaId != null ? 'Empresa #$empresaId' : 'Empresa');
      final right = (deliveryNome != null && deliveryNome.isNotEmpty)
          ? deliveryNome
          : (deliveryId != null ? 'Delivery #$deliveryId' : 'Delivery');
      return '$left • $right';
    }
    if (def.keyName == 'usuario') {
      final nome = row['nome']?.toString().trim();
      final sobrenome = row['sobrenome']?.toString().trim();
      final full = [if (nome != null && nome.isNotEmpty) nome, if (sobrenome != null && sobrenome.isNotEmpty) sobrenome].join(' ');
      if (full.isNotEmpty) return full;
    }
    if (def.keyName == 'produto') {
      final nome = row['nome']?.toString().trim();
      if (nome != null && nome.isNotEmpty) return nome;
    }
    if (def.keyName == 'rateiodespesa') {
      final nome = row['nome']?.toString().trim();
      final total = _formatPtBrCurrencyWithThousands(row['valormensal']);
      if (nome != null && nome.isNotEmpty && total != null && total.isNotEmpty) return '$nome - R\$ $total';
      if (nome != null && nome.isNotEmpty) return nome;
    }
    if (def.keyName == 'despesavariavel') {
      String? nome;
      final item = row['item'];
      if (item is Map) {
        nome = item['nome']?.toString().trim();
      }
      if (nome != null && nome.isNotEmpty) return nome;
    }
    if (def.keyName == 'item') {
      final nome = row['nome']?.toString().trim();
      if (nome == null || nome.isEmpty) return _primaryTitle(def, row);

      // 1ª linha: Nome do item + unidade entre parêntesis (ex.: (gr), (ml)).
      String? unidade;
      unidade = _relatedStringField(row['unidade'], 'unidade');
      if (unidade == null || unidade.isEmpty) {
        // Fallback: caso a unidade não venha embutida.
        unidade = row['unidade_nome']?.toString().trim();
      }
      if (unidade != null && unidade.isNotEmpty && unidade != 'null') return '$nome (${unidade.trim()})';
      return nome;
    }

    if (def.keyName == 'receita') {
      final nome = row['nome']?.toString().trim();
      if (nome == null || nome.isEmpty) return _primaryTitle(def, row);

      // 1ª linha: Nome da receita + (qtd + unidade) entre parêntesis.
      // Ex.: "Bolo de cenoura (1,5 kg)".
      final qtdTxt = _formatPtBrNumber(row['qtdreceita']);
      final unidadeTxt = _relatedStringField(row['unidade'], 'unidade');
      final hasQtd = qtdTxt != null && qtdTxt.isNotEmpty;
      final hasUnidade = unidadeTxt != null && unidadeTxt.isNotEmpty && unidadeTxt != 'null';

      if (hasQtd && hasUnidade) return '$nome (${qtdTxt} ${unidadeTxt!.trim()})';
      if (hasQtd) return '$nome (${qtdTxt})';
      if (hasUnidade) return '$nome (${unidadeTxt!.trim()})';
      return nome;
    }

    if (def.keyName == 'ingrediente' || def.keyName == 'material') {
      // 1ª linha: Nome do item + unidade do item entre parêntesis.
      final item = row['item'];
      if (item is Map) {
        final nome = item['nome']?.toString().trim();
        final unidade = _relatedStringField(item['unidade'], 'unidade');
        if (nome != null && nome.isNotEmpty) {
          if (unidade != null && unidade.isNotEmpty && unidade != 'null') return '$nome (${unidade.trim()})';
          return nome;
        }
      }
      return _primaryTitle(def, row);
    }

    if (def.keyName == 'marca' || def.keyName == 'rateiodespesa') {
      final nome = row['nome']?.toString().trim();
      if (nome != null && nome.isNotEmpty) return nome;
    }
    return _primaryTitle(def, row);
  }

  TextStyle? _titleStyle(BuildContext context, CadastroDefinition def) {
    // Compact title style for denser lists.
    final base = Theme.of(context).textTheme.titleSmall;
    if (def.keyName == 'marca' || def.keyName == 'rateiodespesa' || def.keyName == 'produto' || def.keyName == 'kit') {
      return base?.copyWith(fontWeight: FontWeight.w700);
    }
    return base;
  }

  String? _subtitleText(CadastroDefinition def, Map<String, dynamic> row) {
    if (def.keyName == 'empresataxas') {
      final imposto = _formatPtBrCurrencyWithThousands(row['imposto']);
      final taxaAdm = _formatPtBrCurrencyWithThousands(row['taxaadm']);
      final taxaMotoboy = _formatPtBrCurrencyWithThousands(row['taxamotoboy']);
      final bits = <String>[
        if (imposto != null) 'I.R.: $imposto%',
        if (taxaAdm != null) 'Taxa adm: $taxaAdm%',
        if (taxaMotoboy != null) 'Taxa motoboy: $taxaMotoboy',
      ];
      return bits.isEmpty ? null : bits.join(' • ');
    }
    if (def.keyName == 'empresadelivery') {
      final taxa = _formatPtBrCurrencyWithThousands(row['taxadelivery']);
      final status = row['status'];
      final statusTxt = status == null ? null : _formatListValue(def, 'status', status);

      final bits = <String>[];
      if (taxa != null && taxa.trim().isNotEmpty) bits.add('Taxa: $taxa%');
      if (statusTxt != null && statusTxt.trim().isNotEmpty) bits.add('Status: $statusTxt');
      return bits.isEmpty ? null : bits.join(' • ');
    }
    if (def.keyName == 'despesavariavel') {
      final consumoTxt = _formatPtBrNumber(row['consumomensal']);
      if (consumoTxt == null || consumoTxt.trim().isEmpty) return null;

      // Try to show the unit from the embedded item relationship:
      // item: { ..., unidade: { unidade: 'kg' } }
      String? unidadeTxt;
      final item = row['item'];
      if (item is Map) {
        unidadeTxt = _relatedStringField(item['unidade'], 'unidade');
      }
      final unitSuffix = (unidadeTxt != null && unidadeTxt.trim().isNotEmpty && unidadeTxt != 'null') ? ' ${unidadeTxt.trim()}' : '';
      return 'Consumo mensal: $consumoTxt$unitSuffix';
    }

    if (def.keyName == 'receita') {
      // Preferir os campos persistidos na tabela `receita`.
      // Mantemos fallback para chaves antigas calculadas em memória (caso existam).
      final ing = row['custototalingrediente'] ?? row['_custo_total_ingredientes'];
      final mat = row['custototalmaterial'] ?? row['_custo_total_materiais'];
      final total = row['custoreceita'] ?? row['_custo_total_receita'];

      final ingTxt = _formatPtBrCurrencyWithThousands(ing);
      final matTxt = _formatPtBrCurrencyWithThousands(mat);
      final totalTxt = _formatPtBrCurrencyWithThousands(total);

      // 2ª linha: consolidar em UMA linha (padrão de 2 linhas).
      final parts = <String>[];
      if (ingTxt != null) parts.add('Ingredientes: R\$ $ingTxt');
      if (matTxt != null) parts.add('Materiais: R\$ $matTxt');
      if (totalTxt != null) parts.add('Total: R\$ $totalTxt');
      return parts.isEmpty ? null : parts.join(' • ');
    }

    if (def.keyName == 'usuario') {
      final email = row['email']?.toString().trim();
      final tipo = _tipoUsuarioLabel(row['tipousuario']?.toString());
      final parts = <String>[];
      if (email != null && email.isNotEmpty) parts.add(email);
      if (tipo != null && tipo.isNotEmpty) parts.add(tipo);
      return parts.isEmpty ? null : parts.join(' • ');
    }

    if (def.keyName == 'produto') {
      final parts = <String>[];
      final codigo = row['codigo']?.toString().trim();
      if (codigo != null && codigo.isNotEmpty) parts.add('Código: $codigo');

      final categoriaNome = _relatedNome(row['categoria']);
      if (categoriaNome != null && categoriaNome.isNotEmpty) parts.add('Categoria: $categoriaNome');

      final custoProducaoTxt = _formatPtBrCurrencyWithThousands(row['_custo_producao']);
      if (custoProducaoTxt != null && custoProducaoTxt.isNotEmpty) parts.add('Custo de produção: R\$ $custoProducaoTxt');

      final qtdProduzidaTxt = _formatPtBrNumber(row['qtdproduzida']);
      if (qtdProduzidaTxt != null && qtdProduzidaTxt.isNotEmpty) parts.add('Qtd produzida: $qtdProduzidaTxt');

      return parts.isEmpty ? null : parts.join(' • ');
    }

    if (def.keyName == 'item') {
      // As infos do Item (unidade/marca/tipo/custo) são exibidas como cards/pílulas
      // na 1ª linha, então não renderizamos subtítulo para evitar duplicidade.
      return null;
    }

    // Marca e Rateio: só o nome em negrito (sem subtítulo).
    if (def.keyName == 'marca' || def.keyName == 'rateiodespesa') return null;

    // Ingrediente (lista aninhada da receita): exibir custos também.
    if (def.keyName == 'ingrediente') {
      final qtyRaw = row['quantidadegrama'];
      final qtyTxt = qtyRaw == null ? null : _formatListValue(def, 'quantidadegrama', qtyRaw).trim();

      num? custoUnit;
      final item = row['item'];
      String? unidadeTxt;
      if (item is Map) {
        final raw = item['custounitario'];
        if (raw is num) {
          custoUnit = raw;
        } else if (raw != null) {
          custoUnit = num.tryParse(raw.toString());
        }

        // Embedded as: item: { ..., unidade: { unidade: 'g' } }
        unidadeTxt = _relatedStringField(item['unidade'], 'unidade');
      }

      // Prefer the stored value (ingrediente.custoingrediente). If missing, compute:
      // item.custounitario * ingrediente.quantidadegrama
      num? custoIng;
      final stored = row['custoingrediente'];
      if (stored is num) {
        custoIng = stored;
      } else if (stored != null) {
        custoIng = num.tryParse(stored.toString());
      }

      final storedIsZero = (custoIng != null && custoIng == 0);
      if ((custoIng == null || storedIsZero) && custoUnit != null && qtyRaw != null) {
        final qtyNum = qtyRaw is num ? qtyRaw : num.tryParse(qtyRaw.toString());
        if (qtyNum != null) {
          final computed = custoUnit * qtyNum;
          if (custoIng == null || (storedIsZero && computed > 0)) custoIng = computed;
        }
      }

      final custoUnitTxt = custoUnit == null
          ? '—'
          : (_formatPtBrCurrencyWithThousands(custoUnit, decimals: 4) ?? custoUnit.toString());
      final custoIngTxt = custoIng == null ? '—' : (_formatPtBrCurrencyWithThousands(custoIng) ?? custoIng.toString());

      final parts = <String>[];
      if (qtyTxt != null && qtyTxt.isNotEmpty) {
        final unitSuffix = (unidadeTxt != null && unidadeTxt!.isNotEmpty) ? ' $unidadeTxt' : '';
        parts.add('Qtde: $qtyTxt$unitSuffix');
      }
      parts.add('Custo unitário - R\$: ${custoUnit == null ? '—' : custoUnitTxt}');
      parts.add('Custo do ingrediente na receita - R\$: ${custoIng == null ? '—' : custoIngTxt}');
      return parts.join(' • ');
    }

    // Material (lista aninhada da receita): exibir custos também.
    if (def.keyName == 'material') {
      final qtyRaw = row['quantidade'];
      final qtyTxt = qtyRaw == null ? null : _formatListValue(def, 'quantidade', qtyRaw).trim();

      num? custoUnit;
      final item = row['item'];
      String? unidadeTxt;
      if (item is Map) {
        final raw = item['custounitario'];
        if (raw is num) {
          custoUnit = raw;
        } else if (raw != null) {
          custoUnit = num.tryParse(raw.toString());
        }

        // Embedded as: item: { ..., unidade: { unidade: 'un' } }
        unidadeTxt = _relatedStringField(item['unidade'], 'unidade');
      }

      num? custoMat;
      final stored = row['customaterial'];
      if (stored is num) {
        custoMat = stored;
      } else if (stored != null) {
        custoMat = num.tryParse(stored.toString());
      }

      final storedIsZero = (custoMat != null && custoMat == 0);
      if ((custoMat == null || storedIsZero) && custoUnit != null && qtyRaw != null) {
        final qtyNum = qtyRaw is num ? qtyRaw : num.tryParse(qtyRaw.toString());
        if (qtyNum != null) {
          final computed = custoUnit * qtyNum;
          if (custoMat == null || (storedIsZero && computed > 0)) custoMat = computed;
        }
      }

      final custoUnitTxt = custoUnit == null
          ? '—'
          : (_formatPtBrCurrencyWithThousands(custoUnit, decimals: 4) ?? custoUnit.toString());
      final custoMatTxt = custoMat == null ? '—' : (_formatPtBrCurrencyWithThousands(custoMat) ?? custoMat.toString());

      final parts = <String>[];
      if (qtyTxt != null && qtyTxt.isNotEmpty) {
        final unitSuffix = (unidadeTxt != null && unidadeTxt!.isNotEmpty) ? ' $unidadeTxt' : '';
        parts.add('Qtde: $qtyTxt$unitSuffix');
      }
      parts.add('Custo unitário - R\$: ${custoUnit == null ? '—' : custoUnitTxt}');
      parts.add('Custo do material - R\$: ${custoMat == null ? '—' : custoMatTxt}');
      return parts.join(' • ');
    }

    return null;
  }

  String? _relatedNome(Object? related) {
    // PostgREST embeds can come as:
    // - Map<String, dynamic> (single object)
    // - List<dynamic> (when relationship is inferred as 1:N)
    // We accept both and pick the first row when it is a list.
    if (related is Map) {
      final nome = related['nome']?.toString().trim();
      return (nome == null || nome.isEmpty) ? null : nome;
    }
    if (related is List && related.isNotEmpty) {
      final first = related.first;
      if (first is Map) {
        final nome = first['nome']?.toString().trim();
        return (nome == null || nome.isEmpty) ? null : nome;
      }
    }
    return null;
  }

  String? _relatedStringField(Object? related, String field) {
    if (related is Map) {
      final v = related[field]?.toString().trim();
      return (v == null || v.isEmpty) ? null : v;
    }
    if (related is List && related.isNotEmpty) {
      final first = related.first;
      if (first is Map) {
        final v = first[field]?.toString().trim();
        return (v == null || v.isEmpty) ? null : v;
      }
    }
    return null;
  }

  String? _tipoUsuarioLabel(String? raw) {
    final v = raw?.trim().toUpperCase();
    switch (v) {
      case 'A':
        return 'Administrador';
      case 'E':
        return 'Administrador da Empresa';
      case 'U':
        return 'Usuário';
      default:
        return v;
    }
  }

  String _pretty(String col) {
    if (col == 'quantidadegrama') return 'Qtde em gramas';
    if (col.endsWith('id')) return col;
    return col.replaceAll('_', ' ');
  }

  String _formatListValue(CadastroDefinition def, String col, Object v) {
    if (col.toLowerCase() == 'status') {
      final s = v.toString().trim().toUpperCase();
      if (s == 'A') return 'Ativo';
      if (s == 'I') return 'Inativo';
      // Evita exibir valores vazios/inesperados como "null".
      return s.isEmpty ? '' : v.toString();
    }
    // Ingrediente: show quantity with pt-BR decimal comma and 4 decimals (mask 99999,9999).
    if (def.keyName == 'ingrediente' && col == 'quantidadegrama') {
      final n = v is num ? v : num.tryParse(v.toString());
      if (n == null) return v.toString();
      return _formatPtBrFixedDecimals(n, 4);
    }
    // Material: keep same numeric style as ingrediente (4 decimals) for quantity.
    if (def.keyName == 'material' && col == 'quantidade') {
      final n = v is num ? v : num.tryParse(v.toString());
      if (n == null) return v.toString();
      return _formatPtBrFixedDecimals(n, 4);
    }
    return v.toString();
  }

  String _formatPtBrFixedDecimals(num value, int decimals) {
    // No thousand separators; just fixed decimals and decimal comma.
    final s = value.toStringAsFixed(decimals);
    return s.replaceAll('.', ',');
  }

  String? _formatPtBrNumber(Object? value) {
    if (value == null) return null;
    if (value is num) {
      // Keep the UI compact: show integer without decimals, otherwise 2 decimals.
      final decimals = value % 1 == 0 ? 0 : 2;
      return _formatPtBrFixedDecimals(value, decimals);
    }
    final parsed = num.tryParse(value.toString());
    if (parsed != null) {
      final decimals = parsed % 1 == 0 ? 0 : 2;
      return _formatPtBrFixedDecimals(parsed, decimals);
    }
    // Fallback: still convert decimal point to comma when present.
    return value.toString().replaceAll('.', ',');
  }

  String? _formatPtBrCurrencyWithThousands(Object? value, {int decimals = 2}) {
    if (value == null) return null;
    final n = value is num ? value : num.tryParse(value.toString());
    if (n == null) return value.toString();
    final negative = n < 0;
    final fixed = n.abs().toStringAsFixed(decimals); // e.g. "1234.5600"
    final parts = fixed.split('.');
    var intPart = parts.first;
    final decPart = parts.length > 1 ? parts.last : ''.padLeft(decimals, '0');

    // Add thousand separators with dot: 1234567 -> 1.234.567
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      final posFromRight = intPart.length - i;
      buf.write(intPart[i]);
      if (posFromRight > 1 && posFromRight % 3 == 1) buf.write('.');
    }
    intPart = buf.toString();
    final out = decimals <= 0 ? intPart : '$intPart,$decPart';
    return negative ? '-$out' : out;
  }

  String _formatCnpj(String? raw) {
    if (raw == null) return '';
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 14) return raw;
    return '${digits.substring(0, 2)}.${digits.substring(2, 5)}.${digits.substring(5, 8)}/${digits.substring(8, 12)}-${digits.substring(12, 14)}';
  }

  String _formatCpf(String? raw) {
    if (raw == null) return '';
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 11) return raw;
    return '${digits.substring(0, 3)}.${digits.substring(3, 6)}.${digits.substring(6, 9)}-${digits.substring(9, 11)}';
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.error.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onErrorContainer, fontWeight: FontWeight.w700, letterSpacing: 0.6),
        ),
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = active ? cs.primaryContainer : cs.errorContainer;
    final fg = active ? cs.onPrimaryContainer : cs.onErrorContainer;
    final border = active ? cs.primary.withValues(alpha: 0.22) : cs.error.withValues(alpha: 0.22);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          active ? 'Ativo' : 'Inativo',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w700, letterSpacing: 0.2),
        ),
      ),
    );
  }
}

class _RowActions extends StatelessWidget {
  const _RowActions({
    required this.definition,
    required this.row,
    required this.onEdit,
    required this.onDelete,
    this.onRefreshRequested,
    this.horizontal = false,
  });

  final CadastroDefinition definition;
  final Map<String, dynamic> row;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  /// Called after returning from nested pages (e.g. Receita > Ingredientes/Materiais)
  /// so the parent list can reload fresh totals from the backend.
  final VoidCallback? onRefreshRequested;

  /// When true, render actions in a single horizontal row (Edit + Delete)
  /// to save vertical space.
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = context.watch<AppSessionController>();
    final isEmpresa = definition.keyName == 'empresa';
    final canDelete = !(isEmpresa && !session.isSuperAdmin);

    final isReceita = definition.keyName == 'receita';
    final receitaId = row[definition.idColumn];

    IconButton _compactIcon({required String tooltip, required VoidCallback? onPressed, required IconData icon, required Color color}) {
      return IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: color),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        padding: EdgeInsets.zero,
      );
    }

    if (isReceita) {
      // Force a consistent 2x2 layout to keep card height predictable.
      final Widget ingBtn = _compactIcon(
        tooltip: 'Ingredientes',
        onPressed: receitaId is num
            ? () async {
                await context.push('/cadastros/receita/${receitaId.toInt()}/ingredientes');
                if (context.mounted) onRefreshRequested?.call();
              }
            : null,
        icon: Icons.science_outlined,
        color: cs.primary,
      );
      final Widget matBtn = _compactIcon(
        tooltip: 'Materiais',
        onPressed: receitaId is num
            ? () async {
                await context.push('/cadastros/receita/${receitaId.toInt()}/materiais');
                if (context.mounted) onRefreshRequested?.call();
              }
            : null,
        icon: Icons.all_inbox_outlined,
        color: cs.primary,
      );
      final Widget editBtn = _compactIcon(tooltip: 'Editar', onPressed: onEdit, icon: Icons.edit_rounded, color: cs.primary);
      final Widget delBtn = _compactIcon(tooltip: 'Excluir', onPressed: onDelete, icon: Icons.delete_outline_rounded, color: cs.error);

      // Receita cards have 4 actions. Keep predictable layout by default.
      // If horizontal is requested, prefer a compact Wrap so it can fit in-line.
      if (horizontal) {
        return Wrap(spacing: 4, runSpacing: 4, children: [ingBtn, matBtn, editBtn, delBtn]);
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [ingBtn, const SizedBox(width: 4), matBtn]),
          const SizedBox(height: 4),
          Row(mainAxisSize: MainAxisSize.min, children: [editBtn, const SizedBox(width: 4), delBtn]),
        ],
      );
    }

    final editBtn = _compactIcon(tooltip: 'Editar', onPressed: onEdit, icon: Icons.edit_rounded, color: cs.primary);
    final delBtn = _compactIcon(tooltip: 'Excluir', onPressed: onDelete, icon: Icons.delete_outline_rounded, color: cs.error);

    if (horizontal) {
      return Row(mainAxisSize: MainAxisSize.min, children: [editBtn, if (canDelete) ...[const SizedBox(width: 4), delBtn]]);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        editBtn,
        if (canDelete) ...[const SizedBox(height: 2), delBtn],
      ],
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel();

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
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_outlined, color: cs.onSurfaceVariant, size: 28),
              const SizedBox(height: AppSpacing.sm),
              Text('Nenhum registro encontrado.', style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 4),
              Text(
                'Use o botão "Novo" para incluir o primeiro.',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
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
          color: cs.errorContainer.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: cs.error.withValues(alpha: 0.22)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, color: cs.onErrorContainer, size: 28),
              const SizedBox(height: AppSpacing.sm),
              Text(message, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: cs.onErrorContainer)),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: onRetry,
                icon: Icon(Icons.refresh_rounded, color: cs.onPrimary),
                label: Text('Tentar novamente', style: TextStyle(color: cs.onPrimary)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

