import 'package:bakepro/pages/cadastros/cadastro_definitions.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:flutter/foundation.dart';

class FkReference {
  const FkReference({required this.referencingTable, required this.referencingColumn, required this.referencingTitle});
  final String referencingTable;
  final String referencingColumn;
  final String referencingTitle;
}

class FkBlockResult {
  const FkBlockResult({required this.reference});
  final FkReference reference;
}

enum FkDeleteDecisionType { allowed, blocked, unknown }

class FkDeleteDecision {
  const FkDeleteDecision._(this.type, {this.block, this.error});
  final FkDeleteDecisionType type;
  final FkBlockResult? block;
  final Object? error;

  const FkDeleteDecision.allowed() : this._(FkDeleteDecisionType.allowed);
  const FkDeleteDecision.blocked(FkBlockResult block) : this._(FkDeleteDecisionType.blocked, block: block);
  const FkDeleteDecision.unknown(Object error) : this._(FkDeleteDecisionType.unknown, error: error);
}

/// Centralized guard to prevent deleting a PK record that is still referenced
/// as FK in another table.
///
/// This uses the cadastro definitions as the source of truth for FK metadata,
/// so we don't need to hardcode checks per screen/table.
class FkDeleteGuard {
  /// Children that are intentionally deleted together with the parent (cascade
  /// at app level or DB level). References from these tables should not block
  /// deletion.
  static const Map<String, Set<String>> _cascadeChildrenByKeyName = {
    // Receitas: deleting a receita will also delete its ingredientes/materiais.
    'receita': {'ingrediente', 'material'},
    // Kits: deleting a kit will also delete its kitproduto/kitembalagem.
    'kit': {'kitproduto', 'kitembalagem'},
    // Compras: deleting a compra also deletes compraitem.
    'compra': {'compraitem'},
    // Produto cascade page maintains child links.
    'produto': {'produtoreceita'},
  };

  static List<FkReference> _buildInboundReferences({required String table}) {
    final refs = <FkReference>[];
    for (final def in Cadastros.all) {
      for (final f in def.fields) {
        final fk = f.fk;
        if (fk == null) continue;
        if (fk.table != table) continue;
        refs.add(FkReference(referencingTable: def.table, referencingColumn: f.column, referencingTitle: def.title));
      }
    }
    return refs;
  }

  static bool _isTableScopedByEmpresa(String table) {
    for (final def in Cadastros.all) {
      if (def.table == table) return def.scopedByEmpresa;
    }
    return false;
  }

  /// Returns a decision about whether deletion is allowed.
  ///
  /// [keyName] should be the cadastro keyName (e.g. 'empresa'). It's used to
  /// apply cascade exclusions.
  ///
  /// If this guard cannot validate references (RLS, missing table/view, network
  /// issues, etc.), it returns [FkDeleteDecisionType.unknown] so callers can
  /// fail-closed (block deletion) and avoid integrity breaches.
  static Future<FkDeleteDecision> checkBeforeDelete({
    required String keyName,
    required String table,
    required dynamic id,
    int? empresaId,
  }) async {
    try {
      final inbound = _buildInboundReferences(table: table);
      if (inbound.isEmpty) return const FkDeleteDecision.allowed();

      final ignoredChildren = _cascadeChildrenByKeyName[keyName] ?? const <String>{};

      for (final ref in inbound) {
        if (ignoredChildren.contains(ref.referencingTable)) continue;

        final filters = <String, dynamic>{ref.referencingColumn: id};
        // If the referencing table is scoped by empresa (e.g. item.empresaid), we
        // can strengthen the check to the current empresa to avoid cross-company
        // false positives while still preventing the real breach.
        // Exceção: quando a própria FK é `empresaid` (ex.: excluir Empresa), não
        // sobrescrever o filtro com a empresa logada.
        if (empresaId != null && ref.referencingColumn != 'empresaid' && _isTableScopedByEmpresa(ref.referencingTable)) {
          filters['empresaid'] = empresaId;
        }

        // Existence check (limit 1) for any referencing row.
        // OBS: PostgREST não aceita `select=1`; selecionamos a própria coluna da FK.
        final rows = await SupabaseService.select(
          ref.referencingTable,
          select: ref.referencingColumn,
          filters: filters,
          limit: 1,
        );
        if (rows.isNotEmpty) return FkDeleteDecision.blocked(FkBlockResult(reference: ref));
      }
      return const FkDeleteDecision.allowed();
    } catch (e) {
      debugPrint('FkDeleteGuard.checkBeforeDelete failed for $table($id): $e');
      return FkDeleteDecision.unknown(e);
    }
  }
}
