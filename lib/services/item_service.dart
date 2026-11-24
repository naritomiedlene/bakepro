import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:flutter/foundation.dart';

class ItemService {
  const ItemService();

  Future<List<Map<String, dynamic>>> listForCompraImport({
    required AppSessionController session,
    required int tipoItemId,
  }) async {
    try {
      final empresaId = session.empresaId;
      final filters = <String, dynamic>{'tipoitemid': tipoItemId};
      if (empresaId != null && !session.isSuperAdmin) filters['empresaid'] = empresaId;

      return await SupabaseService.select(
        'item',
        select: 'itemid,nome,tipoitemid',
        filters: filters,
        orderBy: 'nome',
        ascending: true,
        limit: 2000,
      );
    } catch (e) {
      debugPrint('ItemService.listForCompraImport failed: $e');
      rethrow;
    }
  }
}
