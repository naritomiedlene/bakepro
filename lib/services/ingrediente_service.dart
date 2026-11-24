import 'package:bakepro/models/ingrediente.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:flutter/foundation.dart';

class IngredienteService {
  static const String table = 'ingrediente';

  Future<List<Ingrediente>> listForReceita(int receitaId) async {
    try {
      // Uses FK `ingrediente.itemid -> item.itemid` to embed the related item.
      final rows = await SupabaseService.select(
        table,
        // NOTE: ingrediente table does not contain `empresaid`.
        select: 'ingredienteid, receitaid, itemid, quantidadegrama, custoingrediente, item:itemid(itemid, empresaid, nome, custounitario, custounitarioinicial)',
        filters: {'receitaid': receitaId},
        orderBy: 'ingredienteid',
        ascending: true,
      );
      final list = rows.map(Ingrediente.fromJson).toList(growable: false);
      final sorted = [...list]
        ..sort((a, b) {
          final an = (a.item?.nome ?? '').toLowerCase();
          final bn = (b.item?.nome ?? '').toLowerCase();
          return an.compareTo(bn);
        });
      return sorted;
    } catch (e) {
      debugPrint('IngredienteService.listForReceita failed: $e');
      rethrow;
    }
  }
}
