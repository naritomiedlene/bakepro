import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:flutter/foundation.dart';

class KitTotals {
  const KitTotals({this.totalProdutos, this.totalEmbalagens});

  final num? totalProdutos;
  final num? totalEmbalagens;

  num? get totalKit {
    final a = totalProdutos;
    final b = totalEmbalagens;
    if (a == null && b == null) return null;
    return (a ?? 0) + (b ?? 0);
  }
}

class KitService {
  static const String table = 'kit';
  static const String _kitProdutoTable = 'kitproduto';
  static const String _kitEmbalagemTable = 'kitembalagem';

  Future<KitTotals> loadTotals(int kitId) async {
    try {
      final kps = await SupabaseService.select(
        _kitProdutoTable,
        select: 'kitprodutoid,kitid,quantidade, produto:produtoid(valorvenda)',
        filters: {'kitid': kitId},
        orderBy: 'kitprodutoid',
        ascending: true,
        limit: 500,
      );
      final kes = await SupabaseService.select(
        _kitEmbalagemTable,
        select: 'kitembalagemid,kitid,quantidade, item:itemid(custounitario,custounitarioinicial)',
        filters: {'kitid': kitId},
        orderBy: 'kitembalagemid',
        ascending: true,
        limit: 500,
      );

      num? totalProdutos;
      for (final row in kps) {
        final produto = row['produto'] is Map ? row['produto'] as Map : null;
        final unit = parsePtBrNumber(produto?['valorvenda']);
        final qty = parsePtBrNumber(row['quantidade']);
        if (unit == null || qty == null) continue;
        totalProdutos = (totalProdutos ?? 0) + (unit * qty);
      }

      num? totalEmbalagens;
      for (final row in kes) {
        final item = row['item'] is Map ? row['item'] as Map : null;
        final rawUnit = item?['custounitario'] ?? item?['custounitarioinicial'];
        final unit = parsePtBrNumber(rawUnit);
        final qty = parsePtBrNumber(row['quantidade']);
        if (unit == null || qty == null) continue;
        totalEmbalagens = (totalEmbalagens ?? 0) + (unit * qty);
      }

      return KitTotals(totalProdutos: totalProdutos, totalEmbalagens: totalEmbalagens);
    } catch (e) {
      debugPrint('KitService.loadTotals failed kitId=$kitId: $e');
      rethrow;
    }
  }

  /// Deletes a kit and its dependent rows (kitproduto/kitembalagem) to satisfy
  /// FK constraints.
  ///
  /// This is a client-side cascade (multiple requests).
  Future<void> deleteCascade(int kitId) async {
    try {
      await SupabaseService.delete(_kitProdutoTable, filters: {'kitid': kitId});
      await SupabaseService.delete(_kitEmbalagemTable, filters: {'kitid': kitId});
      await SupabaseService.delete(table, filters: {'kitid': kitId});
    } catch (e) {
      debugPrint('KitService.deleteCascade failed kitId=$kitId: $e');
      rethrow;
    }
  }
}
