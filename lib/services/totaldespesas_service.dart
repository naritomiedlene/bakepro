import 'package:bakepro/supabase/supabase_config.dart';
import 'package:flutter/foundation.dart';

/// Utilities to update `totaldespesas` without relying on a UNIQUE constraint on `empresaid`.
///
/// In some schemas `totaldespesas.empresaid` is not UNIQUE, so PostgREST `upsert(..., onConflict: 'empresaid')`
/// fails with 42P10. This service performs a safe read-then-update/insert instead.
class TotalDespesasService {
  static Future<void> setTotals({required int empresaId, double? totalDespesaFixa, double? totalDespesaVariavel}) async {
    if (totalDespesaFixa == null && totalDespesaVariavel == null) return;

    try {
      // IMPORTANT:
      // `totaldespesas.totaldespesafixa` and `totaldespesas.totaldespesavariavel` are NOT NULL in the schema.
      // When callers recompute only one side (ex: fixas), we must keep the other side from DB (or default to 0)
      // to avoid violating constraints on insert/update.
      final existing = await SupabaseConfig.client
          .from('totaldespesas')
          .select('totaldespesasid, empresaid, totaldespesafixa, totaldespesavariavel')
          .eq('empresaid', empresaId)
          .maybeSingle();

      final existingFixa = (existing == null) ? null : existing['totaldespesafixa'];
      final existingVariavel = (existing == null) ? null : existing['totaldespesavariavel'];

      final mergedFixa = (totalDespesaFixa ?? (existingFixa as num?)?.toDouble() ?? 0.0);
      final mergedVariavel = (totalDespesaVariavel ?? (existingVariavel as num?)?.toDouble() ?? 0.0);

      final payload = <String, dynamic>{'empresaid': empresaId, 'totaldespesafixa': mergedFixa, 'totaldespesavariavel': mergedVariavel};

      if (existing != null && existing['totaldespesasid'] != null) {
        final id = existing['totaldespesasid'];
        await SupabaseConfig.client.from('totaldespesas').update(payload).eq('totaldespesasid', id).select();
      } else {
        await SupabaseConfig.client.from('totaldespesas').insert(payload).select();
      }
    } catch (e) {
      debugPrint('TotalDespesasService.setTotals failed (empresaId=$empresaId): $e');
      rethrow;
    }
  }
}
