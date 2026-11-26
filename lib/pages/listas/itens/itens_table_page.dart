import 'package:bakepro/components/observacao_dialog.dart';
import 'package:bakepro/components/action_icon_button.dart';
import 'package:bakepro/components/count_badge.dart';
import 'package:bakepro/components/info_pill.dart';
import 'package:bakepro/components/stacked_list_actions.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:bakepro/nav.dart';
import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

class ItensTablePage extends StatefulWidget {
  const ItensTablePage({super.key});

  @override
  State<ItensTablePage> createState() => _ItensTablePageState();
}

class _ItensTablePageState extends State<ItensTablePage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _allRows = const [];
  List<Map<String, dynamic>> _rows = const [];
  List<String> _columns = const [];
  int? _sortColumnIndex;
  bool _sortAscending = true;
  int? _lastEmpresaId;
  bool? _lastIsAdmin;
  bool _requestedLoadAfterProfile = false;
  bool _wasRouteCurrent = false;

  final TextEditingController _filterCtrl = TextEditingController();
  Timer? _filterDebounce;

  @override
  void initState() {
    super.initState();
    // Don't load here unconditionally: the AppSessionController may still be
    // refreshing the profile (empresaId). We'll trigger the first load from
    // didChangeDependencies and re-load when empresaId becomes available.

    _filterCtrl.addListener(_onFilterChanged);
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    _filterCtrl.removeListener(_onFilterChanged);
    _filterCtrl.dispose();
    super.dispose();
  }

  void _onFilterChanged() {
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() => _applyFilterAndSort());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = context.watch<AppSessionController>();

    final empresaId = session.empresaId;
    final isAdmin = session.isSuperAdmin;

    final shouldReload = !_requestedLoadAfterProfile || _lastEmpresaId != empresaId || _lastIsAdmin != isAdmin;
    _lastEmpresaId = empresaId;
    _lastIsAdmin = isAdmin;

    if (shouldReload) {
      _requestedLoadAfterProfile = true;
      // Avoid setState during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _load();
      });
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final session = context.read<AppSessionController>();
      final empresaId = session.empresaId;

      final filters = <String, dynamic>{};
      if (!session.isSuperAdmin) {
        if (empresaId == null) {
          // We can't safely show company data without empresaId.
          debugPrint('ItensTablePage: empresaId is null (user not admin). Waiting for profile to load.');
          setState(() {
            _rows = const [];
            _columns = const [];
          });
          return;
        }
        filters['empresaid'] = empresaId;
      }

      debugPrint('ItensTablePage: loading items with empresaId=$empresaId isSuperAdmin=${session.isSuperAdmin} filters=$filters');

      // Include FK labels (when relationships exist in Supabase) so we can show
      // friendly columns for Tipo de Item / Marca / Unidade.
      final rowsRaw = await SupabaseService.select(
        'item',
        // NOTE: Unidade table uses column `unidade` (not `nome`) in this project.
        // Selecting `nome` causes: "column unidade_1.nome does not exist".
        select: '*, tipoitem:tipoitemid(nome), marca:marcaid(nome), unidade:unidadeid(unidade)',
        filters: filters,
        orderBy: 'itemid',
        ascending: true,
        limit: 5000,
      );

      // Fallback label lookup: in some Supabase setups the FK relationship may
      // not be inferred by PostgREST (missing constraint) or may be blocked by
      // RLS for embedded selects. In that case, `tipoitem` / `marca` come back
      // as null even though `tipoitemid` / `marcaid` are present.
      //
      // We avoid N+1 by fetching all referenced IDs in a single query per table.
      Future<Map<int, String>> _fetchLabelMap({
        required String table,
        required String idColumn,
        required String labelColumn,
        required Set<int> ids,
        Map<String, dynamic> extraEqFilters = const {},
      }) async {
        if (ids.isEmpty) return const {};
        try {
          dynamic q = SupabaseService.from(table).select('$idColumn,$labelColumn');
          for (final entry in extraEqFilters.entries) {
            q = q.eq(entry.key, entry.value);
          }
          q = q.inFilter(idColumn, ids.toList());
          final res = await q;
          final map = <int, String>{};
          for (final r in (res as List)) {
            final m = Map<String, dynamic>.from(r as Map);
            final id = (m[idColumn] as num?)?.toInt();
            final label = m[labelColumn]?.toString();
            if (id != null && label != null && label.trim().isNotEmpty) map[id] = label;
          }
          return map;
        } catch (e) {
          debugPrint('ItensTablePage: fallback label lookup failed for $table: $e');
          return const {};
        }
      }

      String? _extractEmbeddedField(dynamic embedded, String fieldName) {
        if (embedded == null) return null;
        if (embedded is Map) return embedded[fieldName]?.toString();
        // Depending on FK constraints / PostgREST inference, an embedded relationship
        // can come back as a List (even when logically it's 1:1). In that case,
        // pick the first record.
        if (embedded is List && embedded.isNotEmpty) {
          final first = embedded.first;
          if (first is Map) return first[fieldName]?.toString();
        }
        return null;
      }

      int? _toInt(dynamic v) {
        if (v == null) return null;
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v.trim());
        return int.tryParse(v.toString().trim());
      }

      final rows = rowsRaw.map((r) {
        final m = Map<String, dynamic>.from(r);

        final tipoItem = m['tipoitem'];
        m['tipoitem_nome'] = _extractEmbeddedField(tipoItem, 'nome');

        final marca = m['marca'];
        m['marca_nome'] = _extractEmbeddedField(marca, 'nome');

        final unidade = m['unidade'];
        m['unidade_nome'] = _extractEmbeddedField(unidade, 'unidade');

        // Keep the table "flat"; hide the embedded objects to avoid showing
        // raw Map(...) in a cell.
        m.remove('tipoitem');
        m.remove('marca');
        m.remove('unidade');
        return m;
      }).toList(growable: false);

      // If embedded relationships were not returned, try a fallback lookup.
      // We only do this when we detect missing labels.
      final missingMarcaIds = <int>{};
      final missingTipoIds = <int>{};
      for (final r in rows) {
        final marcaNome = r['marca_nome']?.toString().trim();
        final tipoNome = r['tipoitem_nome']?.toString().trim();
        if (marcaNome == null || marcaNome.isEmpty || marcaNome == 'null') {
          // Supabase/PostgREST may return numeric columns as String depending on
          // view/cast; accept both.
          final id = _toInt(r['marcaid'] ?? r['marcaId']);
          if (id != null) missingMarcaIds.add(id);
        }
        if (tipoNome == null || tipoNome.isEmpty || tipoNome == 'null') {
          final id = _toInt(r['tipoitemid'] ?? r['tipoitemId']);
          if (id != null) missingTipoIds.add(id);
        }
      }

      debugPrint(
        'ItensTablePage: missing labels -> marcaIds=${missingMarcaIds.length} tipoIds=${missingTipoIds.length}',
      );

      if (missingMarcaIds.isNotEmpty || missingTipoIds.isNotEmpty) {
        final marcaMap = await _fetchLabelMap(
          table: 'marca',
          idColumn: 'marcaid',
          labelColumn: 'nome',
          ids: missingMarcaIds,
          // Marca is scoped by empresa in this project.
          extraEqFilters: (!session.isSuperAdmin && empresaId != null) ? {'empresaid': empresaId} : const {},
        );
        // TipoItem is not scoped by empresa in the data model, but some setups
        // may have RLS policies that require empresaid. We'll try without extra
        // filters first, then fall back to empresaid if the first lookup yields
        // nothing.
        var tipoMap = await _fetchLabelMap(table: 'tipoitem', idColumn: 'tipoitemid', labelColumn: 'nome', ids: missingTipoIds);
        if (tipoMap.isEmpty && !session.isSuperAdmin && empresaId != null) {
          final tipoMapEmpresa = await _fetchLabelMap(
            table: 'tipoitem',
            idColumn: 'tipoitemid',
            labelColumn: 'nome',
            ids: missingTipoIds,
            extraEqFilters: {'empresaid': empresaId},
          );
          if (tipoMapEmpresa.isNotEmpty) tipoMap = tipoMapEmpresa;
        }

        debugPrint('ItensTablePage: fallback maps -> marca=${marcaMap.length} tipo=${tipoMap.length}');

        for (final r in rows) {
          final marcaNome = r['marca_nome']?.toString().trim();
          if (marcaNome == null || marcaNome.isEmpty || marcaNome == 'null') {
            final id = _toInt(r['marcaid'] ?? r['marcaId']);
            if (id != null && marcaMap.containsKey(id)) r['marca_nome'] = marcaMap[id];
          }
          final tipoNome = r['tipoitem_nome']?.toString().trim();
          if (tipoNome == null || tipoNome.isEmpty || tipoNome == 'null') {
            final id = _toInt(r['tipoitemid'] ?? r['tipoitemId']);
            if (id != null && tipoMap.containsKey(id)) r['tipoitem_nome'] = tipoMap[id];
          }
        }
      }

      if (rows.isNotEmpty) {
        debugPrint('ItensTablePage: sample row keys=${rows.first.keys.toList()}');
        debugPrint('ItensTablePage: sample tipoitem_nome=${rows.first['tipoitem_nome']} marca_nome=${rows.first['marca_nome']}');
        debugPrint(
          'ItensTablePage: sample raw ids marcaid=${rows.first['marcaid']}(${rows.first['marcaid']?.runtimeType}) tipoitemid=${rows.first['tipoitemid']}(${rows.first['tipoitemid']?.runtimeType})',
        );

        // Extra diagnostics to understand why Tipo/Marca may not render.
        // Log the first few rows with their IDs + resolved labels.
        final sampleCount = math.min(5, rows.length);
        for (var i = 0; i < sampleCount; i++) {
          final r = rows[i];
          debugPrint('ItensTablePage: row[$i] itemid=${r['itemid']} nome=${r['nome']}');
          debugPrint('  marcaid=${r['marcaid']} marca_nome=${r['marca_nome']}');
          debugPrint('  tipoitemid=${r['tipoitemid']} tipoitem_nome=${r['tipoitem_nome']}');
        }
      }

      final cols = <String>{};
      for (final r in rows) {
        cols.addAll(r.keys.map((k) => k.toString()));
      }

      final ordered = cols.toList()..sort();
      if (ordered.remove('itemid')) ordered.insert(0, 'itemid');
      if (ordered.remove('nome')) ordered.insert(math.min(1, ordered.length).toInt(), 'nome');

      // This list is already scoped by the logged empresaId; no need to show it.
      ordered.remove('empresaid');

      // IDs that are not useful in the table UI.
      ordered.remove('marcaid');
      // Replace unidadeId by its label.
      ordered.remove('unidadeid');

      // Replace tipoitemId by its label.
      ordered.remove('tipoitemid');

      // Prefer showing friendly labels near the name.
      // We now render Tipo/Marca *inside* the Nome cell to keep the table compact.
      // Keep the fields in each row (for display), but remove them from the columns.
      ordered.remove('tipoitem_nome');
      ordered.remove('marca_nome');

      // unidadeid is hidden; keep only the friendly label.
      if (ordered.remove('unidade_nome')) {
        final nomeIdx = ordered.indexOf('nome');
        if (nomeIdx >= 0) {
          ordered.insert(math.min(nomeIdx + 1, ordered.length).toInt(), 'unidade_nome');
        } else {
          ordered.add('unidade_nome');
        }
      }

      setState(() {
        _allRows = rows;
        _rows = rows;
        _columns = ordered;
      });

      // Apply filter (if any) and keep sort preference.
      setState(() => _applyFilterAndSort());

      debugPrint('ItensTablePage: loaded ${rows.length} rows; columns=${ordered.length}');
    } catch (e) {
      debugPrint('ItensTablePage load failed: $e');
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _sortBy(String column, int columnIndex) {
    final asc = (_sortColumnIndex == columnIndex) ? !_sortAscending : true;
    setState(() {
      _sortColumnIndex = columnIndex;
      _sortAscending = asc;
      _applyFilterAndSort();
    });
  }

  void _applyFilterAndSort() {
    final q = _filterCtrl.text.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _allRows
        : _allRows.where((r) => (r['nome']?.toString().toLowerCase() ?? '').contains(q)).toList(growable: false);

    if (_sortColumnIndex != null && _sortColumnIndex! >= 0 && _sortColumnIndex! < _columns.length) {
      final col = _columns[_sortColumnIndex!];
      final sorted = [...filtered]
        ..sort((a, b) {
          final av = a[col];
          final bv = b[col];
          final c = _compare(av, bv);
          return _sortAscending ? c : -c;
        });
      _rows = sorted;
    } else {
      _rows = filtered is List<Map<String, dynamic>> ? filtered : filtered.toList(growable: false);
    }
  }

  int _compare(dynamic a, dynamic b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;

    if (a is num && b is num) return a.compareTo(b);
    return a.toString().toLowerCase().compareTo(b.toString().toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final isRouteCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (isRouteCurrent && !_wasRouteCurrent) {
      // Reset filter whenever this page becomes visible again (e.g. returning
      // from an item edit screen). The requirement is to always open this list
      // showing all items.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_filterCtrl.text.isNotEmpty) {
          _filterCtrl.clear();
          setState(() => _applyFilterAndSort());
        }
      });
    }
    _wasRouteCurrent = isRouteCurrent;

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final session = context.watch<AppSessionController>();

    // Rendered inside AppShell (ShellRoute). Avoid nesting another Scaffold/AppBar.
    debugPrint(
      'ItensTablePage: build route=${GoRouterState.of(context).matchedLocation} loading=$_loading error=${_error != null} rows=${_rows.length}',
    );

    final content = _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? _ErrorState(message: _error!, onRetry: _load)
        : (!session.isSuperAdmin && session.empresaId == null)
        ? _MissingEmpresaState(onRetry: () async {
            await session.reloadProfile();
            if (!mounted) return;
            await _load();
          })
        : _rows.isEmpty
        ? const _EmptyState()
        : _ItensList(
            rows: _rows,
            onOpenItem: (itemId, row) async {
              final result = await context.push(AppRoutes.listasItemEdit(itemId), extra: row);
              if (result == true) await _load();
            },
          );

    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cabeçalho no padrão das listas de cadastro: voltar, título e "Atualizar".
            IconButton(
              onPressed: () => context.pop(),
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: 'Voltar',
            ),
            Row(
              children: [
                Expanded(child: Text('Itens', style: theme.textTheme.headlineSmall)),
                StackedListActions(isLoading: _loading, onRefresh: _load),
              ],
            ),
            // Filtro no padrão das listas de cadastro (caixa arredondada com lupa).
            Padding(
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
                          controller: _filterCtrl,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: 'Filtrar itens pelo nome',
                            border: InputBorder.none,
                            isDense: true,
                            hintStyle: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                          ),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      if (_filterCtrl.text.isNotEmpty)
                        IconButton(
                          tooltip: 'Limpar filtro',
                          onPressed: () {
                            _filterCtrl.clear();
                            FocusScope.of(context).unfocus();
                            setState(() => _applyFilterAndSort());
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
            ),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }
}

class _ItensList extends StatelessWidget {
  const _ItensList({required this.rows, required this.onOpenItem});

  final List<Map<String, dynamic>> rows;
  final Future<void> Function(int itemId, Map<String, dynamic> row) onOpenItem;

  @override
  Widget build(BuildContext context) {
    // Padrão das listas de cadastro: contador abóbora à direita e cards soltos.
    return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: CountBadge(rows.length == 1 ? '1 item' : '${rows.length} itens'),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.zero,
              sliver: SliverList.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                itemBuilder: (context, i) => _ItemCard(
                  row: rows[i],
                  onTap: () {
                    final idRaw = rows[i]['itemid'];
                    final itemId = (idRaw is num) ? idRaw.toInt() : int.tryParse(idRaw?.toString() ?? '');
                    if (itemId == null) {
                      debugPrint('ItensTablePage: invalid itemid in row: ${rows[i]['itemid']}');
                      return;
                    }
                    onOpenItem(itemId, rows[i]);
                  },
                ),
              ),
            ),
          ],
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.row, required this.onTap});

  final Map<String, dynamic> row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final nome = (row['nome'] ?? '').toString().trim();
    final tipo = (row['tipoitem_nome'] ?? '').toString().trim();
    final marca = (row['marca_nome'] ?? '').toString().trim();
    final unidade = (row['unidade_nome'] ?? '').toString().trim();
    final custoUnit = row['custounitario'];
    final custoUnitFmt = _formatCustoPerUnidade(custoUnit, unidade);

    final dataAtualizacao = row['dataatualizacao'];
    final dataAtualizacaoFmt = _formatBrDateTime(dataAtualizacao);

    bool has(String s) => s.isNotEmpty && s != 'null';

    // Padrão das listas de cadastro: card com nome + lápis na 1ª linha e os
    // dados em cards (InfoPill) na 2ª; custo (calculado) no ameixa padrão.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    nome.isEmpty ? '—' : nome,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                // Observação (bloco de notas) só quando o item tiver texto em `obs`.
                if (observacaoDe(row) != null) ...[
                  AppActionIconButton.observacao(
                    onPressed: () => showObservacaoDialog(
                      context,
                      titulo: nome.isEmpty ? 'Observação' : nome,
                      texto: observacaoDe(row)!,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                AppActionIconButton.edit(onPressed: onTap),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: 6,
              children: [
                if (has(unidade)) InfoPill(icon: Icons.straighten_rounded, label: 'Unid', value: unidade),
                if (has(marca)) InfoPill(icon: Icons.sell_rounded, label: 'Marca', value: marca),
                if (has(tipo)) InfoPill(icon: Icons.category_rounded, label: 'Tipo', value: tipo),
                InfoPill(icon: Icons.request_quote_rounded, label: 'Custo unit.', value: custoUnitFmt, calculated: true),
                InfoPill(icon: Icons.update_rounded, label: 'Atualização', value: dataAtualizacaoFmt),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Custo em pt-BR com 4 casas e milhar (ex.: "R$ 0,2100/Grama"), como na lista de cadastro.
  String _formatCustoPerUnidade(dynamic v, String unidadeNome) {
    final n = parsePtBrNumber(v);
    if (n == null) return '—';
    final base = formatPtBrCurrency(n, decimalDigits: 4);
    final u = unidadeNome.trim();
    if (u.isEmpty || u == 'null') return base;
    return '$base/$u';
  }

  String _formatBrDateTime(dynamic v) {
    if (v == null) return '—';
    DateTime? dt;
    if (v is DateTime) {
      dt = v;
    } else if (v is String) {
      dt = DateTime.tryParse(v);
    } else {
      dt = DateTime.tryParse(v.toString());
    }
    if (dt == null) return v.toString();
    final d = dt.toLocal();
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yyyy = d.year.toString().padLeft(4, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    return '$dd/$mm/$yyyy $hh:$min';
  }
}

class _MissingEmpresaState extends StatelessWidget {
  const _MissingEmpresaState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.domain_disabled_outlined, size: 44, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text('Empresa do usuário não carregada', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                'Não foi possível identificar a empresa vinculada ao seu usuário.\n\nIsso normalmente se resolve ao recarregar o perfil.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onRetry,
                icon: Icon(Icons.refresh_rounded, color: theme.colorScheme.onPrimary),
                label: Text('Recarregar', style: TextStyle(color: theme.colorScheme.onPrimary)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ItensDataTable extends StatefulWidget {
  const _ItensDataTable({
    required this.rows,
    required this.columns,
    required this.sortAscending,
    required this.sortColumnIndex,
    required this.onSort,
    required this.onNeedsReload,
  });

  final List<Map<String, dynamic>> rows;
  final List<String> columns;
  final bool sortAscending;
  final int? sortColumnIndex;
  final void Function(String column, int columnIndex) onSort;
  final Future<void> Function() onNeedsReload;

  @override
  State<_ItensDataTable> createState() => _ItensDataTableState();
}

class _ItensDataTableState extends State<_ItensDataTable> {
  int _rowsPerPage = 20;
  int _pageIndex = 0;

  late final ScrollController _hScroll;
  late final ScrollController _vScroll;

  @override
  void initState() {
    super.initState();
    _hScroll = ScrollController();
    _vScroll = ScrollController();
  }

  @override
  void dispose() {
    _hScroll.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ItensDataTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.rows, widget.rows)) {
      final totalPages = _totalPagesFor(widget.rows.length, _rowsPerPage);
      if (_pageIndex >= totalPages) _pageIndex = (totalPages - 1).clamp(0, 1 << 30);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final totalRows = widget.rows.length;
    final effectiveRowsPerPage = _rowsPerPage.clamp(1, 5000);
    final totalPages = _totalPagesFor(totalRows, effectiveRowsPerPage);
    final pageIndex = _pageIndex.clamp(0, (totalPages - 1).clamp(0, 1 << 30));
    final startIndex = pageIndex * effectiveRowsPerPage;
    final computedEnd = startIndex + effectiveRowsPerPage;
    final endIndex = computedEnd > totalRows ? totalRows : computedEnd;
    final pageRows = widget.rows.sublist(startIndex, endIndex);

    // Estimate a minimum width so the user can scroll through *all* columns.
    final estimatedTableWidth = widget.columns.fold<double>(0, (sum, c) => sum + _colWidth(c));
    final minWidth = math.max(1200.0, estimatedTableWidth);

    return Padding(
      padding: const EdgeInsets.all(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7)),
            borderRadius: BorderRadius.circular(16),
            color: theme.colorScheme.surface,
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Keep the horizontal scrollbar OUTSIDE the vertical scroll.
                      // Also: to keep the column labels always visible, render a fixed header
                      // and scroll only the body vertically.
                      const headerHeight = 48.0;
                      final bodyHeight = (constraints.maxHeight - headerHeight).clamp(80.0, 100000.0);

                      return Scrollbar(
                        // IMPORTANT: keep the *vertical* scrollbar OUTSIDE the horizontal scroll.
                        // If the vertical scrollbar is inside the horizontally scrollable content,
                        // it can end up rendered at the far-right of the (very wide) table, giving
                        // the impression it "disappeared".
                        controller: _vScroll,
                        thumbVisibility: true,
                        trackVisibility: true,
                        interactive: true,
                        scrollbarOrientation: ScrollbarOrientation.right,
                        // This table has nested scrollables (horizontal + vertical).
                        // The default predicate (depth == 0) prevents the scrollbar from
                        // reacting to notifications coming from the inner ListView.
                        // Accept all notifications so the thumb is actually painted on web.
                        notificationPredicate: (_) => true,
                        thickness: 10,
                        radius: const Radius.circular(12),
                        child: Scrollbar(
                          controller: _hScroll,
                          thumbVisibility: true,
                          trackVisibility: true,
                          interactive: true,
                          scrollbarOrientation: ScrollbarOrientation.bottom,
                          notificationPredicate: (_) => true,
                          thickness: 10,
                          radius: const Radius.circular(12),
                          child: SingleChildScrollView(
                            controller: _hScroll,
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: minWidth,
                              height: constraints.maxHeight,
                              child: Column(
                                children: [
                                  // Header is outside the vertical scroll area => stays visible ("frozen").
                                  _StickyHeaderRow(
                                    columns: widget.columns,
                                    sortAscending: widget.sortAscending,
                                    sortColumnIndex: widget.sortColumnIndex,
                                    onSort: widget.onSort,
                                    columnLabel: _columnLabel,
                                    colWidth: _colWidth,
                                  ),
                                  SizedBox(
                                    height: bodyHeight,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.7)))),
                                      child: ListView.builder(
                                        controller: _vScroll,
                                        itemCount: pageRows.length,
                                        itemExtent: 76,
                                        itemBuilder: (context, i) => _StickyDataRow(
                                          theme: theme,
                                          columns: widget.columns,
                                          rowIndex: startIndex + i,
                                          row: pageRows[i],
                                          colWidth: _colWidth,
                                          fmt: _fmt,
                                          cellTextStyle: _cellTextStyle,
                                          onOpenItem: (itemId) async {
                                            final result = await context.push(AppRoutes.listasItemEdit(itemId), extra: pageRows[i]);
                                            if (result == true) await widget.onNeedsReload();
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                _TablePager(
                  totalRows: totalRows,
                  startIndex: startIndex,
                  endIndex: endIndex,
                  pageIndex: pageIndex,
                  totalPages: totalPages,
                  rowsPerPage: effectiveRowsPerPage,
                  onRowsPerPageChanged: (v) {
                    setState(() {
                      _rowsPerPage = v;
                      _pageIndex = 0;
                    });
                  },
                  onFirst: () => setState(() => _pageIndex = 0),
                  onPrev: () => setState(() => _pageIndex = pageIndex > 0 ? pageIndex - 1 : 0),
                  onNext: () => setState(() => _pageIndex = (pageIndex + 1) < totalPages ? pageIndex + 1 : pageIndex),
                  onLast: () => setState(() => _pageIndex = totalPages > 0 ? totalPages - 1 : 0),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  int _totalPagesFor(int totalRows, int rowsPerPage) => totalRows == 0 ? 1 : ((totalRows - 1) ~/ rowsPerPage) + 1;

  double _colWidth(String column) {
    switch (column) {
      case 'itemid':
        return 90;
      case 'nome':
        return 320;
      case 'unidade_nome':
        return 120;
      case 'tipoitem_nome':
        return 180;
      case 'marca_nome':
        return 180;
      case 'custounitario':
        return 170;
      case 'dataatualizacao':
        return 170;
      default:
        return 180;
    }
  }

  TextStyle? _cellTextStyle({required ThemeData theme, required String column, required bool isLink}) {
    final base = column == 'nome' ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600) : theme.textTheme.bodyMedium;
    if (!isLink) return base;
    return base?.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary.withValues(alpha: 0.5),
    );
  }

  String _fmt(String column, dynamic v) {
    if (v == null) return '—';
    if (column == 'dataatualizacao') {
      final dt = _tryParseDateTime(v);
      if (dt == null) return v.toString();
      return _formatBrDate(dt);
    }
    if (v is String) return v;
    if (v is num) {
      // Keep cost columns consistent with the form: 4 decimal places.
      if (column == 'custounitario') return v.toStringAsFixed(4);
      return v.toString();
    }
    return v.toString();
  }

  DateTime? _tryParseDateTime(dynamic v) {
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    return DateTime.tryParse(v.toString());
  }

  String _formatBrDate(DateTime dt) {
    final d = dt.toLocal();
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yyyy = d.year.toString().padLeft(4, '0');
    return '$dd/$mm/$yyyy';
  }

  String _columnLabel(String col) {
    switch (col) {
      case 'custounitario':
        return 'Custo Unitário - R\$';
      case 'dataatualizacao':
        return 'Data de Atualização';
      case 'tipoitem_nome':
        return 'Tipo de Item';
      case 'marca_nome':
        return 'Marca';
      case 'unidade_nome':
        return 'Unidade';
      default:
        return col;
    }
  }
}

class _StickyHeaderRow extends StatelessWidget {
  const _StickyHeaderRow({
    required this.columns,
    required this.sortAscending,
    required this.sortColumnIndex,
    required this.onSort,
    required this.columnLabel,
    required this.colWidth,
  });

  final List<String> columns;
  final bool sortAscending;
  final int? sortColumnIndex;
  final void Function(String column, int columnIndex) onSort;
  final String Function(String column) columnLabel;
  final double Function(String column) colWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      height: 48,
      decoration: BoxDecoration(color: cs.surface, border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.7)))),
      child: Row(
        children: [
          for (var i = 0; i < columns.length; i++)
            _HeaderCell(
              width: colWidth(columns[i]),
              label: columnLabel(columns[i]),
              isSorted: sortColumnIndex == i,
              sortAscending: sortAscending,
              onTap: () => onSort(columns[i], i),
            ),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({required this.width, required this.label, required this.isSorted, required this.sortAscending, required this.onTap});

  final double width;
  final String label;
  final bool isSorted;
  final bool sortAscending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final icon = !isSorted
        ? null
        : Icon(sortAscending ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded, size: 18, color: cs.onSurface);

    return InkWell(
      onTap: onTap,
      hoverColor: cs.primary.withValues(alpha: 0.06),
      highlightColor: cs.primary.withValues(alpha: 0.08),
      splashFactory: NoSplash.splashFactory,
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              if (icon != null) icon,
            ],
          ),
        ),
      ),
    );
  }
}

class _StickyDataRow extends StatelessWidget {
  const _StickyDataRow({
    required this.theme,
    required this.columns,
    required this.rowIndex,
    required this.row,
    required this.colWidth,
    required this.fmt,
    required this.cellTextStyle,
    required this.onOpenItem,
  });

  final ThemeData theme;
  final List<String> columns;
  final int rowIndex;
  final Map<String, dynamic> row;
  final double Function(String column) colWidth;
  final String Function(String column, dynamic value) fmt;
  final TextStyle? Function({required ThemeData theme, required String column, required bool isLink}) cellTextStyle;
  final Future<void> Function(int itemId) onOpenItem;

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    // Keep rows with a uniform background. (Zebra striping was confusing and
    // also made the table look like it had alternating selection states.)
    final bg = cs.surface;

    final itemId = (row['itemid'] as num?)?.toInt();
    final canOpen = itemId != null;

    final tipoNome = row['tipoitem_nome']?.toString().trim();
    final marcaNome = row['marca_nome']?.toString().trim();
    final unidadeNome = row['unidade_nome']?.toString().trim();
    final custoUnitarioRaw = row['custounitario'];
    final custoUnitarioText = (custoUnitarioRaw == null) ? null : fmt('custounitario', custoUnitarioRaw);

    return DecoratedBox(
      decoration: BoxDecoration(color: bg),
      child: Row(
        children: [
          for (final c in columns)
            if (c == 'nome')
              _ItemNameCell(
                width: colWidth(c),
                nome: fmt(c, row[c]),
                unidadeNome: (unidadeNome == null || unidadeNome.isEmpty || unidadeNome == 'null') ? null : unidadeNome,
                marcaNome: (marcaNome == null || marcaNome.isEmpty || marcaNome == 'null') ? null : marcaNome,
                tipoNome: (tipoNome == null || tipoNome.isEmpty || tipoNome == 'null') ? null : tipoNome,
                custoUnitarioText: (custoUnitarioText == null || custoUnitarioText == '—') ? null : custoUnitarioText,
                textStyle: cellTextStyle(theme: theme, column: c, isLink: canOpen),
                onTap: canOpen ? () => onOpenItem(itemId!) : null,
              )
            else
              _BodyCell(
                width: colWidth(c),
                text: fmt(c, row[c]),
                textStyle: cellTextStyle(theme: theme, column: c, isLink: (c == 'itemid') && canOpen),
                onTap: ((c == 'itemid') && canOpen) ? () => onOpenItem(itemId!) : null,
              ),
        ],
      ),
    );
  }
}

class _ItemNameCell extends StatelessWidget {
  const _ItemNameCell({
    required this.width,
    required this.nome,
    required this.unidadeNome,
    required this.marcaNome,
    required this.tipoNome,
    required this.custoUnitarioText,
    required this.textStyle,
    required this.onTap,
  });

  final double width;
  final String nome;
  final String? unidadeNome;
  final String? marcaNome;
  final String? tipoNome;
  final String? custoUnitarioText;
  final TextStyle? textStyle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);

    final title = (unidadeNome == null || unidadeNome!.trim().isEmpty) ? nome : '$nome (${unidadeNome!.trim()})';

    final details = <String>[];
    if (marcaNome != null) details.add('Marca: $marcaNome');
    if (tipoNome != null) details.add('Tipo: $tipoNome');
    if (custoUnitarioText != null) {
      final u = unidadeNome?.trim();
      if (u != null && u.isNotEmpty) {
        details.add('Custo un.: R\$ $custoUnitarioText / $u');
      } else {
        details.add('Custo un.: R\$ $custoUnitarioText');
      }
    }
    final detailsText = details.join(' • ');

    return InkWell(
      onTap: onTap,
      hoverColor: onTap == null ? null : cs.primary.withValues(alpha: 0.05),
      highlightColor: onTap == null ? null : cs.primary.withValues(alpha: 0.07),
      splashFactory: NoSplash.splashFactory,
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: textStyle ?? theme.textTheme.bodyMedium),
              if (detailsText.isNotEmpty) Text(detailsText, maxLines: 1, overflow: TextOverflow.ellipsis, style: secondaryStyle),
            ],
          ),
        ),
      ),
    );
  }
}

class _BodyCell extends StatelessWidget {
  const _BodyCell({required this.width, required this.text, required this.textStyle, required this.onTap});

  final double width;
  final String text;
  final TextStyle? textStyle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      hoverColor: onTap == null ? null : cs.primary.withValues(alpha: 0.05),
      highlightColor: onTap == null ? null : cs.primary.withValues(alpha: 0.07),
      splashFactory: NoSplash.splashFactory,
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textStyle ?? theme.textTheme.bodyMedium,
            ),
          ),
        ),
      ),
    );
  }
}

class _TablePager extends StatelessWidget {
  const _TablePager({
    required this.totalRows,
    required this.startIndex,
    required this.endIndex,
    required this.pageIndex,
    required this.totalPages,
    required this.rowsPerPage,
    required this.onRowsPerPageChanged,
    required this.onFirst,
    required this.onPrev,
    required this.onNext,
    required this.onLast,
  });

  final int totalRows;
  final int startIndex;
  final int endIndex;
  final int pageIndex;
  final int totalPages;
  final int rowsPerPage;

  final ValueChanged<int> onRowsPerPageChanged;
  final VoidCallback onFirst;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final canPrev = pageIndex > 0;
    final canNext = pageIndex < totalPages - 1;

    final label = totalRows == 0 ? '0 itens' : '${startIndex + 1}–$endIndex de $totalRows';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.7))),
        color: cs.surface,
      ),
      child: Row(
        children: [
          // Contador/posição padrão (card abóbora).
          CountBadge(label),
          const Spacer(),
          Text('Linhas:', style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(width: 8),
          _RowsPerPageDropdown(value: rowsPerPage, onChanged: onRowsPerPageChanged),
          const SizedBox(width: 10),
          IconButton(
            tooltip: 'Primeira página',
            onPressed: canPrev ? onFirst : null,
            icon: Icon(Icons.first_page_rounded, color: canPrev ? cs.onSurface : cs.onSurfaceVariant),
          ),
          IconButton(
            tooltip: 'Página anterior',
            onPressed: canPrev ? onPrev : null,
            icon: Icon(Icons.chevron_left_rounded, color: canPrev ? cs.onSurface : cs.onSurfaceVariant),
          ),
          // Página atual / total de páginas: mesmo card abóbora.
          CountBadge('${pageIndex + 1}/$totalPages', dense: true),
          IconButton(
            tooltip: 'Próxima página',
            onPressed: canNext ? onNext : null,
            icon: Icon(Icons.chevron_right_rounded, color: canNext ? cs.onSurface : cs.onSurfaceVariant),
          ),
          IconButton(
            tooltip: 'Última página',
            onPressed: canNext ? onLast : null,
            icon: Icon(Icons.last_page_rounded, color: canNext ? cs.onSurface : cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _RowsPerPageDropdown extends StatelessWidget {
  const _RowsPerPageDropdown({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final candidates = const [10, 20, 50, 100, 200];
    final items = {
      value,
      ...candidates,
    }.toList(growable: false)..sort();

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.8)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: DropdownButton<int>(
          value: value,
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(12),
          items: [
            for (final v in items)
              DropdownMenuItem<int>(
                value: v,
                child: Text('$v', style: theme.textTheme.bodySmall),
              ),
          ],
          onChanged: (v) {
            if (v == null) return;
            onChanged(v);
          },
        ),
      ),
    );
  }
}

// NOTE: We intentionally rely on DataCell.onTap (instead of an InkWell inside the
// cell). On web, nested gesture detectors inside tabular widgets can be flaky.

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_rounded, size: 44, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('Nenhum item encontrado', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Verifique se existem itens cadastrados para sua empresa.', style: theme.textTheme.bodySmall),
          ],
        ),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 44, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text('Falha ao carregar itens', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(message, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onRetry,
                icon: Icon(Icons.refresh_rounded, color: theme.colorScheme.onPrimary),
                label: Text('Tentar novamente', style: TextStyle(color: theme.colorScheme.onPrimary)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
