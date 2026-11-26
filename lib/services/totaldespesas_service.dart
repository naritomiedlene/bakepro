import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:flutter/foundation.dart';

/// Utilities to update `totaldespesas` without relying on a UNIQUE constraint on `empresaid`.
///
/// In some schemas `totaldespesas.empresaid` is not UNIQUE, so PostgREST `upsert(..., onConflict: 'empresaid')`
/// fails with 42P10. This service performs a safe read-then-update/insert instead.
class TotalDespesasService {
  /// Soma `valormensal` de [tabela] (despesafixa ou despesavariavel) da empresa,
  /// considerando SOMENTE as ativas (status = 'A'). A soma é feita no Dart
  /// (o backend pode bloquear agregações), em páginas de 1000.
  static Future<double> _somarAtivas(String tabela, int empresaId) async {
    const pageSize = 1000;
    var from = 0;
    var total = 0.0;
    while (true) {
      final dynamic page = await SupabaseConfig.client
          .from(tabela)
          .select('valormensal')
          .eq('empresaid', empresaId)
          .eq('status', 'A')
          .range(from, from + pageSize - 1);
      if (page is! List || page.isEmpty) break;
      for (final r in page) {
        if (r is! Map) continue;
        total += parsePtBrNumber(r['valormensal']) ?? 0.0;
      }
      if (page.length < pageSize) break;
      from += pageSize;
    }
    return total;
  }

  /// Total das despesas fixas ativas da empresa.
  static Future<double> somarDespesaFixaAtiva(int empresaId) => _somarAtivas('despesafixa', empresaId);

  /// Total das despesas variáveis ativas da empresa.
  static Future<double> somarDespesaVariavelAtiva(int empresaId) => _somarAtivas('despesavariavel', empresaId);

  /// Recalcula o total de despesas fixas ativas e grava em `totaldespesas.totaldespesafixa`.
  /// Chamar após criar, editar ou excluir uma despesa fixa.
  static Future<double> recalcularDespesaFixa(int empresaId) async {
    final total = await somarDespesaFixaAtiva(empresaId);
    await setTotals(empresaId: empresaId, totalDespesaFixa: total);
    debugPrint('TotalDespesasService: totaldespesafixa recalculado empresaId=$empresaId total=$total');
    return total;
  }

  /// Recalcula o total de despesas variáveis ativas e grava em `totaldespesas.totaldespesavariavel`.
  /// Chamar após criar, editar ou excluir uma despesa variável.
  static Future<double> recalcularDespesaVariavel(int empresaId) async {
    final total = await somarDespesaVariavelAtiva(empresaId);
    await setTotals(empresaId: empresaId, totalDespesaVariavel: total);
    debugPrint('TotalDespesasService: totaldespesavariavel recalculado empresaId=$empresaId total=$total');
    return total;
  }

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

      final List<dynamic> gravadas;
      if (existing != null && existing['totaldespesasid'] != null) {
        final id = existing['totaldespesasid'];
        gravadas = await SupabaseConfig.client.from('totaldespesas').update(payload).eq('totaldespesasid', id).select();
      } else {
        gravadas = await SupabaseConfig.client.from('totaldespesas').insert(payload).select();
      }
      // Sem linhas retornadas = nada foi gravado (ex.: permissão/RLS bloqueou sem erro).
      if (gravadas.isEmpty) {
        throw StateError('Nenhuma linha de totaldespesas foi gravada (empresaId=$empresaId).');
      }
    } catch (e) {
      debugPrint('TotalDespesasService.setTotals failed (empresaId=$empresaId): $e');
      rethrow;
    }
  }
}
