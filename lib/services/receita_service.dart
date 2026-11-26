import 'package:bakepro/models/receita.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:flutter/foundation.dart';

class ReceitaService {
  static const String table = 'receita';

  static const String _ingredienteTable = 'ingrediente';
  static const String _materialTable = 'material';

  // Join `unidade` so the UI can show the human label (unidade.unidade)
  // while still using the new FK schema (unidadeid).
  static const String _selectWithUnidade =
      'receitaid,empresaid,nome,descricao,qtdreceita,custoreceita,custototalingrediente,custototalmaterial,status,unidadeid,unidade:unidadeid(unidadeid,unidade)';

  static const String _pk = 'receitaid';

  num _round2(num v) => num.parse(v.toStringAsFixed(2));

  /// Recomputes and persists totals for a single receita:
  /// - custototalingrediente = sum(ingrediente.custoingrediente)
  /// - custototalmaterial = sum(material.customaterial)
  /// - custoreceita = sum of both
  ///
  /// This is a client-side sync used when DB triggers are not available or when
  /// legacy data needs to be brought up to date.
  Future<void> syncTotalsForReceita({required int receitaId, int? empresaId}) async {
    try {
      // IMPORTANT:
      // Legacy rows may have custoingrediente/customaterial = 0 because older
      // logic didn't compute costs when item.custounitario was null.
      // We recompute using item.custounitario * quantidade.
      final ingredienteRows = await SupabaseService.from(_ingredienteTable)
          .select('custoingrediente,quantidadegrama,item:itemid(custounitario)')
          .eq('receitaid', receitaId);
      final materialRows = await SupabaseService.from(_materialTable)
          .select('customaterial,quantidade,item:itemid(custounitario)')
          .eq('receitaid', receitaId);

      num totalIng = 0;
      for (final r in (ingredienteRows as List)) {
        if (r is! Map) continue;
        num? custo = parsePtBrNumber(r['custoingrediente']);
        final storedIsZero = (custo != null && custo == 0);

        if (custo == null || storedIsZero) {
          final item = r['item'];
          num? custoUnit;
          if (item is Map) {
            final raw = item['custounitario'];
            custoUnit = parsePtBrNumber(raw);
          }
          final qtyRaw = r['quantidadegrama'];
          final qty = parsePtBrNumber(qtyRaw);
          if (custoUnit != null && qty != null) {
            final computed = custoUnit * qty;
            if (custo == null || (storedIsZero && computed > 0)) custo = computed;
          }
        }

        totalIng += custo ?? 0;
      }

      num totalMat = 0;
      for (final r in (materialRows as List)) {
        if (r is! Map) continue;
        num? custo = parsePtBrNumber(r['customaterial']);
        final storedIsZero = (custo != null && custo == 0);

        if (custo == null || storedIsZero) {
          final item = r['item'];
          num? custoUnit;
          if (item is Map) {
            final raw = item['custounitario'];
            custoUnit = parsePtBrNumber(raw);
          }
          final qtyRaw = r['quantidade'];
          final qty = parsePtBrNumber(qtyRaw);
          if (custoUnit != null && qty != null) {
            final computed = custoUnit * qty;
            if (custo == null || (storedIsZero && computed > 0)) custo = computed;
          }
        }

        totalMat += custo ?? 0;
      }

      totalIng = _round2(totalIng);
      totalMat = _round2(totalMat);
      final total = _round2(totalIng + totalMat);

      // IMPORTANT:
      // receitaid is the PK. Filtering by empresaid here can cause silent no-op
      // updates when the in-memory empresaId differs from the stored value (or
      // is typed differently). We keep empresaId as an optional diagnostic only.
      final result = await SupabaseService.update(
        table,
        {
          'custototalingrediente': totalIng,
          'custototalmaterial': totalMat,
          'custoreceita': total,
        },
        filters: {_pk: receitaId},
      );

      if (result.isEmpty) {
        debugPrint(
          'ReceitaService.syncTotalsForReceita: update returned 0 rows (receitaId=$receitaId, empresaId=$empresaId). Check RLS/filters.',
        );
      } else {
        if (kDebugMode) {
          debugPrint(
            'ReceitaService.syncTotalsForReceita OK receitaId=$receitaId -> ing=$totalIng mat=$totalMat total=$total',
          );
        }
      }
    } catch (e) {
      debugPrint('ReceitaService.syncTotalsForReceita failed receitaId=$receitaId: $e');
      rethrow;
    }
  }

  Future<List<Receita>> list({int limit = 50}) async {
    try {
      final rows = await SupabaseService.select(
        table,
        select: _selectWithUnidade,
        orderBy: 'nome',
        ascending: true,
        limit: limit,
      );
      final list = rows.map(Receita.fromJson).toList(growable: false);
      final sorted = [...list]..sort((a, b) => a.nome.toLowerCase().compareTo(b.nome.toLowerCase()));
      return sorted;
    } catch (e) {
      debugPrint('ReceitaService.list failed: $e');
      rethrow;
    }
  }

  /// Loads recipes and computes, for each recipe:
  /// - total ingredient cost: sum(ingrediente.custoingrediente)
  /// - total prep material cost: sum(material.customaterial)
  /// - total recipe cost: sum of the two totals
  ///
  /// It also persists the computed total into `receita.custoreceita`.
  Future<List<Receita>> listWithComputedCosts({int limit = 50}) async {
    try {
      final receitas = await list(limit: limit);
      if (receitas.isEmpty) return receitas;

      final receitaIds = receitas.map((r) => r.receitaId).toList(growable: false);

      // IMPORTANT:
      // Do not rely exclusively on stored custoingrediente/customaterial.
      // In some setups those fields can be null/0 (no DB trigger), while the
      // UI can still compute costs from item cost * quantity.
      final ingredienteRows = await SupabaseService.from(_ingredienteTable)
          .select('receitaid,custoingrediente,quantidadegrama,item:itemid(custounitario)')
          .inFilter('receitaid', receitaIds);
      final materialRows = await SupabaseService.from(_materialTable)
          .select('receitaid,customaterial,quantidade,item:itemid(custounitario)')
          .inFilter('receitaid', receitaIds);

      final totalIngredientes = <int, num>{};
      for (final r in (ingredienteRows as List)) {
        if (r is! Map) continue;
        final rid = (r['receitaid'] as num?)?.toInt();
        if (rid == null) continue;

        num c = parsePtBrNumber(r['custoingrediente']) ?? 0;
        if (c == 0) {
          final item = r['item'];
          num? custoUnit;
          if (item is Map) {
            final raw = item['custounitario'];
            custoUnit = parsePtBrNumber(raw);
          }
          final qty = parsePtBrNumber(r['quantidadegrama']);
          if (custoUnit != null && qty != null) c = custoUnit * qty;
        }

        totalIngredientes[rid] = (totalIngredientes[rid] ?? 0) + c;
      }

      final totalMateriais = <int, num>{};
      for (final r in (materialRows as List)) {
        if (r is! Map) continue;
        final rid = (r['receitaid'] as num?)?.toInt();
        if (rid == null) continue;

        num c = parsePtBrNumber(r['customaterial']) ?? 0;
        if (c == 0) {
          final item = r['item'];
          num? custoUnit;
          if (item is Map) {
            final raw = item['custounitario'];
            custoUnit = parsePtBrNumber(raw);
          }
          final qty = parsePtBrNumber(r['quantidade']);
          if (custoUnit != null && qty != null) c = custoUnit * qty;
        }

        totalMateriais[rid] = (totalMateriais[rid] ?? 0) + c;
      }

      final updates = <Map<String, dynamic>>[];
      final enriched = <Receita>[];
      for (final receita in receitas) {
        final ing = _round2(totalIngredientes[receita.receitaId] ?? 0);
        final mat = _round2(totalMateriais[receita.receitaId] ?? 0);
        final total = _round2(ing + mat);

        enriched.add(
          receita.copyWith(
            custoTotalIngredientes: ing,
            custoTotalMateriais: mat,
            custoReceita: total,
          ),
        );

        final current = receita.custoReceita;
        if (current == null || _round2(current) != total) {
          updates.add({
            _pk: receita.receitaId,
            'custototalingrediente': ing,
            'custototalmaterial': mat,
            'custoreceita': total,
          });
        }
      }

      if (updates.isNotEmpty) {
        // Persist in batch (upsert by PK).
        await SupabaseService.from(table).upsert(updates, onConflict: _pk);
      }

      return enriched;
    } catch (e) {
      debugPrint('ReceitaService.listWithComputedCosts failed: $e');
      rethrow;
    }
  }

  Future<Receita?> getById(int receitaId) async {
    try {
      final row = await SupabaseService.selectSingle(
        table,
        select: _selectWithUnidade,
        filters: {'receitaid': receitaId},
      );
      if (row == null) return null;
      return Receita.fromJson(row);
    } catch (e) {
      debugPrint('ReceitaService.getById failed: $e');
      rethrow;
    }
  }

  /// Deletes a receita and its dependent rows (ingrediente/material) to satisfy
  /// FK constraints.
  ///
  /// Note: this is a client-side cascade (multiple requests). If you need full
  /// atomicity, we can move this into a Postgres function (RPC) later.
  Future<void> deleteCascade(int receitaId) async {
    try {
      // Order matters: delete children first, then the parent.
      await SupabaseService.delete(_ingredienteTable, filters: {'receitaid': receitaId});
      await SupabaseService.delete(_materialTable, filters: {'receitaid': receitaId});
      await SupabaseService.delete(table, filters: {'receitaid': receitaId});
    } catch (e) {
      debugPrint('ReceitaService.deleteCascade failed receitaId=$receitaId: $e');
      rethrow;
    }
  }
}
