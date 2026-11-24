import 'package:bakepro/pages/cadastros/cadastro_definitions.dart';
import 'package:bakepro/pages/cadastros/generic_cadastro_form_sheet.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class ItemEditPage extends StatefulWidget {
  const ItemEditPage({super.key, required this.itemId, this.initialRow});

  final int itemId;
  final Map<String, dynamic>? initialRow;

  @override
  State<ItemEditPage> createState() => _ItemEditPageState();
}

class _ItemEditPageState extends State<ItemEditPage> {
  Map<String, dynamic>? _row;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _row = widget.initialRow;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final def = Cadastros.byKey('item');
      if (def == null) throw Exception('CadastroDefinition(item) não encontrada');

      final row = await SupabaseService.selectSingle(
        def.table,
        filters: {def.idColumn: widget.itemId},
      );

      if (!mounted) return;
      if (row == null) {
        setState(() => _error = 'Item ${widget.itemId} não encontrado.');
      } else {
        setState(() => _row = row);
      }
    } catch (e) {
      debugPrint('ItemEditPage load failed: $e');
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final def = Cadastros.byKey('item');

    // Rendered inside AppShell (ShellRoute). Avoid nesting another Scaffold/AppBar.
    final content = _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? _ErrorState(message: _error!, onRetry: _load)
        : def == null
        ? const Center(child: Text('CadastroDefinition(item) não encontrada'))
        : Padding(
            padding: const EdgeInsets.all(12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Material(
                color: theme.colorScheme.surface,
                child: GenericCadastroFormSheet(definition: def, initialRow: _row),
              ),
            ),
          );

    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => context.pop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: 'Voltar',
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(child: Text('Editar Item #${widget.itemId}', style: theme.textTheme.headlineSmall)),
                IconButton(
                  tooltip: 'Recarregar',
                  onPressed: _loading ? null : _load,
                  icon: Icon(Icons.refresh_rounded, color: cs.onSurface),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(child: content),
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
              Text('Falha ao carregar item', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
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
