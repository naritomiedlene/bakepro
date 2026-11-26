import 'package:bakepro/components/action_icon_button.dart';
import 'package:bakepro/pages/cadastros/cadastro_definitions.dart';
import 'package:bakepro/pages/cadastros/generic_cadastro_form_sheet.dart';
import 'package:bakepro/services/fk_delete_guard.dart';
import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/theme.dart';
import 'package:bakepro/components/stacked_list_actions.dart';
import 'package:bakepro/components/confirm_delete_sheet.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

class CompraListPage extends StatefulWidget {
  const CompraListPage({super.key});

  @override
  State<CompraListPage> createState() => _CompraListPageState();
}

class _CompraListPageState extends State<CompraListPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
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
      if (empresaId != null && !session.isSuperAdmin) {
        filters['empresaid'] = empresaId;
      }

      final rows = await SupabaseService.select(
        'compra',
        select: '*, fornecedor:fornecedorid(nomefantasia)',
        filters: filters.isEmpty ? null : filters,
        orderBy: 'datacompra',
        ascending: false,
        limit: 200,
      );

      if (!mounted) return;
      setState(() => _rows = rows);
    } catch (e) {
      debugPrint('Load compra list failed: $e');
      if (!mounted) return;
      setState(() => _error = 'Não foi possível carregar as compras.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final def = Cadastros.byKey('compra');
    if (def == null) return;

    final res = await showModalBottomSheet<dynamic>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(definition: def),
    );

    if (res is Map) {
      final id = res['compraid'];
      if (id is num && mounted) {
        context.push('/compras/compra/${id.toInt()}');
        return;
      }
    }

    if (res == true) await _load();
  }

  void _open(int compraId) => context.push('/compras/compra/$compraId');

  Future<void> _delete(Map<String, dynamic> row) async {
    final cs = Theme.of(context).colorScheme;
    final id = row['compraid'];
    if (id is! num) return;

    final decision = await FkDeleteGuard.checkBeforeDelete(keyName: 'compra', table: 'compra', id: id);
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
            'Não é possível excluir esta compra porque ela está associada a outro cadastro (${decision.block!.reference.referencingTitle}).',
          ),
        ),
      );
      return;
    }

    final fornecedorNome = ((row['fornecedor'] as Map?)?['nomefantasia'] ?? '').toString().trim();
    final identifier = fornecedorNome.isNotEmpty ? 'Compra • $fornecedorNome' : 'Compra • #${id.toInt()}';

    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ConfirmDeleteSheet(
        title: 'Excluir compra?',
        recordIdentifier: identifier,
        message: 'Esta ação excluirá também os itens da compra.\n\nEsta ação não poderá ser desfeita.',
        confirmLabel: 'Excluir',
        confirmColor: cs.error,
      ),
    );
    if (ok != true) return;

    try {
      await SupabaseService.delete('compra', filters: {'compraid': id});
      if (!mounted) return;
      await _load();
    } catch (e) {
      debugPrint('Delete compra failed: $e');
      if (!mounted) return;

      final msg = e.toString().toLowerCase();
      final isFkViolation = msg.contains('foreign key') || msg.contains('violates foreign key') || msg.contains('23503');
      if (isFkViolation) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não é possível excluir porque este registro está associado a outros dados.')),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível excluir.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(onPressed: () => context.go('/compras'), icon: Icon(Icons.arrow_back_rounded, color: cs.onSurface), tooltip: 'Voltar'),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text('Compras', style: Theme.of(context).textTheme.headlineSmall)),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                const Spacer(),
                StackedListActions(
                  isLoading: _loading,
                  onRefresh: _load,
                  onCreate: _create,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? _ErrorPanel(message: _error!, onRetry: _load)
                  : _rows.isEmpty
                  ? const _EmptyPanel()
                  : ListView.separated(
                      itemCount: _rows.length,
                      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.xs),
                      itemBuilder: (context, i) => _CompraCard(row: _rows[i], onOpen: _open, onDelete: () => _delete(_rows[i])),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompraCard extends StatelessWidget {
  const _CompraCard({required this.row, required this.onOpen, required this.onDelete});

  final Map<String, dynamic> row;
  final void Function(int compraId) onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final id = row['compraid'];
    final fornecedor = row['fornecedor'];
    final fornecedorNome = (fornecedor is Map ? fornecedor['nomefantasia'] : null)?.toString().trim();
    final numeroNf = row['numeronf']?.toString().trim();
    final data = _formatBrDate(row['datacompra']);
    final valor = _formatPtBrCurrency(row['valorcompra']);

    return InkWell(
      onTap: (id is num) ? () => onOpen(id.toInt()) : null,
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
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
                    Text(data, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    if (fornecedorNome != null && fornecedorNome.isNotEmpty)
                      Text(fornecedorNome, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurface)),
                    const SizedBox(height: 2),
                    if (numeroNf != null && numeroNf.isNotEmpty)
                      Text('NF: $numeroNf', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text(valor, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              AppActionIconButton.delete(onPressed: onDelete),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatBrDate(dynamic v) {
  if (v == null) return '';
  final raw = v.toString().trim();
  if (raw.isEmpty) return '';
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(raw);
  if (m == null) return raw;
  final yyyy = m.group(1)!;
  final mm = m.group(2)!;
  final dd = m.group(3)!;
  return '$dd/$mm/$yyyy';
}

String _formatPtBrMoney(dynamic v) {
  num? n;
  if (v is num) n = v;
  if (n == null) n = num.tryParse(v?.toString() ?? '');
  n ??= 0;

  final fixed = n.toStringAsFixed(2);
  final parts = fixed.split('.');
  final intPart = parts.first;
  final dec = parts.length > 1 ? parts.last : '00';

  final sb = StringBuffer();
  for (int i = 0; i < intPart.length; i += 1) {
    sb.write(intPart[i]);
    final remaining = intPart.length - i - 1;
    if (remaining > 0 && remaining % 3 == 0) sb.write('.');
  }
  return '${sb.toString()},$dec';
}

String _formatPtBrCurrency(dynamic v) => 'R\$ ${_formatPtBrMoney(v)}';

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
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text('Nenhuma compra cadastrada.', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
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
          color: cs.surface,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
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
