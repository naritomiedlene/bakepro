import 'package:bakepro/components/action_icon_button.dart';
import 'package:bakepro/pages/cadastros/cadastro_definitions.dart';
import 'package:bakepro/pages/cadastros/generic_cadastro_form_sheet.dart';
import 'package:bakepro/pages/compras/compra/compra_item_import_sheet.dart';
import 'package:bakepro/components/confirm_delete_sheet.dart';
import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

/// Editor em cascata de Compra:
/// Compra -> CompraItem
class CompraCascadePage extends StatefulWidget {
  const CompraCascadePage({super.key, required this.compraId});

  final int? compraId;

  @override
  State<CompraCascadePage> createState() => _CompraCascadePageState();
}

class _CompraCascadePageState extends State<CompraCascadePage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _compra;
  List<Map<String, dynamic>> _itens = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final compraId = widget.compraId;
    if (compraId == null) {
      setState(() {
        _loading = false;
        _error = 'Compra inválida (sem id).';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final compra = await SupabaseService.selectSingle(
        'compra',
        select: '*, fornecedor:fornecedorid(nomefantasia)',
        filters: {'compraid': compraId},
      );
      final itens = await SupabaseService.select(
        'compraitem',
        select: 'compraitemid,compraid,itemid,quantidade,valorunitario,datavalidade, item:itemid(nome)',
        filters: {'compraid': compraId},
        orderBy: 'compraitemid',
        ascending: true,
        limit: 1000,
      );

      itens.sort((a, b) {
        final ai = a['item'];
        final bi = b['item'];
        final an = (ai is Map ? (ai['nome']?.toString() ?? '') : '').toLowerCase();
        final bn = (bi is Map ? (bi['nome']?.toString() ?? '') : '').toLowerCase();
        return an.compareTo(bn);
      });

      if (!mounted) return;
      setState(() {
        _compra = compra;
        _itens = itens;
      });
    } catch (e) {
      debugPrint('Load compra cascade failed: $e');
      if (!mounted) return;
      setState(() => _error = 'Não foi possível carregar a compra.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editCompra() async {
    final def = Cadastros.byKey('compra');
    final row = _compra;
    if (def == null || row == null) return;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GenericCadastroFormSheet(definition: def, initialRow: row),
    );
    if (ok == true) await _load();
  }

  Future<void> _addItem() async {
    final compraId = widget.compraId;
    if (compraId == null) return;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CompraItemFormSheet(compraId: compraId),
    );
    if (ok == true) await _load();
  }

  Future<void> _importItems() async {
    final compraId = widget.compraId;
    if (compraId == null) return;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CompraItemImportSheet(compraId: compraId),
    );
    if (ok == true) await _load();
  }

  Future<void> _editItem(Map<String, dynamic> row) async {
    final compraId = widget.compraId;
    if (compraId == null) return;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CompraItemFormSheet(compraId: compraId, initialRow: row),
    );
    if (ok == true) await _load();
  }

  Future<void> _deleteItem(Map<String, dynamic> row) async {
    final cs = Theme.of(context).colorScheme;
    final id = row['compraitemid'];
    if (id is! num) return;

    final itemNome = ((row['item'] as Map?)?['nome'] ?? '').toString().trim();
    final identifier = itemNome.isNotEmpty ? 'Item • $itemNome' : 'Item • #${id.toInt()}';

    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ConfirmDeleteSheet(
        title: 'Excluir item?',
        recordIdentifier: identifier,
        message: 'Esta ação não poderá ser desfeita.',
        confirmLabel: 'Excluir',
        confirmColor: cs.error,
      ),
    );
    if (ok != true) return;

    try {
      await SupabaseService.delete('compraitem', filters: {'compraitemid': id});
      if (!mounted) return;
      await _load();
    } catch (e) {
      debugPrint('Delete compraitem failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível excluir.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final compra = _compra;
    final data = _formatBrDate(compra?['datacompra']);
    final fornecedorNome = ((compra?['fornecedor'] as Map?)?['nomefantasia'] ?? '').toString().trim();

    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(onPressed: () => context.pop(), icon: Icon(Icons.arrow_back_rounded, color: cs.onSurface), tooltip: 'Voltar'),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(data.isEmpty ? 'Compra' : data, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                      if (fornecedorNome.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(fornecedorNome, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.25), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _load,
                  icon: Icon(Icons.refresh_rounded, color: cs.primary),
                  label: Text('Atualizar', style: TextStyle(color: cs.primary)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? _ErrorPanel(message: _error!, onRetry: _load)
                  : ListView(
                      children: [
                        _CompraHeaderCard(compra: compra ?? const {}, onEdit: _editCompra),
                        const SizedBox(height: AppSpacing.lg),
                        _SectionHeader(
                          title: 'Itens da compra',
                          subtitle: 'Cadastre os itens comprados com validade e valores.',
                          primaryActionLabel: 'Adicionar',
                          primaryActionIcon: Icons.add_rounded,
                          onPrimaryAction: _addItem,
                          secondaryActionLabel: 'Importar',
                          secondaryActionIcon: Icons.upload_file_rounded,
                          onSecondaryAction: _importItems,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        if (_itens.isEmpty)
                          const _EmptyInlineCard(message: 'Nenhum item cadastrado para esta compra.')
                        else
                          ..._itens.map(
                            (it) => Padding(
                              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                              child: CompraItemCard(row: it, onEdit: () => _editItem(it), onDelete: () => _deleteItem(it)),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class CompraItemCard extends StatelessWidget {
  const CompraItemCard({super.key, required this.row, required this.onEdit, required this.onDelete});

  final Map<String, dynamic> row;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final itemNome = ((row['item'] as Map?)?['nome'] ?? row['itemid'] ?? 'Item').toString();
    final qtd = _formatPtBrDecimal(row['quantidade']);
    final unit = _formatPtBrCurrency(row['valorunitario']);
    final total = _formatPtBrCurrency((_num(row['quantidade']) ?? 0) * (_num(row['valorunitario']) ?? 0));
    final validade = _formatBrDate(row['datavalidade']);

    return DecoratedBox(
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
                  Text(itemNome, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text('Qtd: $qtd • Unit: $unit', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(child: Text('Total: $total', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurface, height: 1.25))),
                      if (validade.isNotEmpty)
                        Text('Val: $validade', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppActionIconButton.edit(onPressed: onEdit),
                const SizedBox(height: 6),
                AppActionIconButton.delete(onPressed: onDelete),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class CompraItemFormSheet extends StatefulWidget {
  const CompraItemFormSheet({super.key, required this.compraId, this.initialRow});

  final int compraId;
  final Map<String, dynamic>? initialRow;

  @override
  State<CompraItemFormSheet> createState() => _CompraItemFormSheetState();
}

class _CompraItemFormSheetState extends State<CompraItemFormSheet> {
  final _itemCtrl = TextEditingController();
  final _qtdCtrl = TextEditingController(text: '0,00');
  final _unitCtrl = TextEditingController(text: '0,00');
  final _validadeCtrl = TextEditingController();

  bool _loadingOptions = true;
  bool _saving = false;
  String? _error;
  List<Map<String, dynamic>> _itemOptions = const [];

  bool get _isEdit => widget.initialRow != null;

  @override
  void initState() {
    super.initState();

    final row = widget.initialRow;
    if (row != null) {
      final itemId = row['itemid'];
      if (itemId is num) _itemCtrl.text = itemId.toInt().toString();
      final qtd = _num(row['quantidade']);
      if (qtd != null) _qtdCtrl.text = _formatPtBrMoney(qtd);
      final unit = _num(row['valorunitario']);
      if (unit != null) _unitCtrl.text = _formatPtBrMoney(unit);
      _validadeCtrl.text = _formatBrDate(row['datavalidade']);
    }

    _qtdCtrl.addListener(_recalc);
    _unitCtrl.addListener(_recalc);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadItemOptions());
  }

  @override
  void dispose() {
    _itemCtrl.dispose();
    _qtdCtrl.dispose();
    _unitCtrl.dispose();
    _validadeCtrl.dispose();
    super.dispose();
  }

  void _recalc() => setState(() {});

  Future<void> _loadItemOptions() async {
    setState(() {
      _loadingOptions = true;
      _error = null;
    });

    try {
      final session = context.read<AppSessionController>();
      final empresaId = session.empresaId;
      final filters = <String, dynamic>{};
      if (empresaId != null && !session.isSuperAdmin) filters['empresaid'] = empresaId;

      final rows = await SupabaseService.select(
        'item',
        select: 'itemid,nome',
        filters: filters.isEmpty ? null : filters,
        orderBy: 'nome',
        ascending: true,
        limit: 1000,
      );
      if (!mounted) return;
      setState(() => _itemOptions = rows);
    } catch (e) {
      debugPrint('Load item options failed: $e');
      if (!mounted) return;
      setState(() => _error = 'Não foi possível carregar os itens.');
    } finally {
      if (mounted) setState(() => _loadingOptions = false);
    }
  }

  num? _parsePtBrNumber(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final normalized = t.replaceAll('.', '').replaceAll(',', '.');
    return num.tryParse(normalized);
  }

  DateTime? _parseBrDate(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    // dd/MM/yyyy (do NOT escape `$` end-of-string anchor)
    final m = RegExp(r'^(\d{2})\/(\d{2})\/(\d{4})$').firstMatch(t);
    if (m == null) return null;
    final dd = int.tryParse(m.group(1)!);
    final mm = int.tryParse(m.group(2)!);
    final yyyy = int.tryParse(m.group(3)!);
    if (dd == null || mm == null || yyyy == null) return null;
    final dt = DateTime(yyyy, mm, dd);
    if (dt.year != yyyy || dt.month != mm || dt.day != dd) return null;
    return dt;
  }

  Future<void> _pickValidade() async {
    if (_saving) return;

    DateTime initialDate;
    final parsed = _parseBrDate(_validadeCtrl.text);
    if (parsed != null) {
      initialDate = parsed;
    } else {
      initialDate = DateTime.now();
    }

    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000, 1, 1),
      lastDate: DateTime(now.year + 30, 12, 31),
      helpText: 'Selecione a data de validade',
    );
    if (picked == null) return;
    final dd = picked.day.toString().padLeft(2, '0');
    final mm = picked.month.toString().padLeft(2, '0');
    final yyyy = picked.year.toString().padLeft(4, '0');
    _validadeCtrl.text = '$dd/$mm/$yyyy';
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final itemId = int.tryParse(_itemCtrl.text.trim());
      if (itemId == null) {
        setState(() => _error = 'Preencha: Item');
        return;
      }
      final qtd = _parsePtBrNumber(_qtdCtrl.text) ?? 0;
      final unit = _parsePtBrNumber(_unitCtrl.text) ?? 0;
      final totalItem = qtd * unit;

      final validadeRaw = _validadeCtrl.text.trim();
      String? validadeIso;
      if (validadeRaw.isNotEmpty) {
        final dt = _parseBrDate(validadeRaw);
        if (dt == null) {
          setState(() => _error = 'Data inválida: Data de validade');
          return;
        }
        validadeIso = '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      }

      final data = <String, dynamic>{
        'compraid': widget.compraId,
        'itemid': itemId,
        'quantidade': qtd,
        'valorunitario': unit,
        'valortotalitem': totalItem,
        if (validadeIso != null) 'datavalidade': validadeIso,
      };

      if (_isEdit) {
        final id = widget.initialRow?['compraitemid'];
        if (id is! num) {
          setState(() => _error = 'Item inválido (sem id).');
          return;
        }
        await SupabaseService.update('compraitem', data, filters: {'compraitemid': id});
      } else {
        await SupabaseService.insert('compraitem', data);
      }

      if (!mounted) return;
      context.pop(true);
    } catch (e) {
      debugPrint('Save compraitem failed: $e');
      if (!mounted) return;
      setState(() => _error = kDebugMode ? 'Não foi possível salvar.\n$e' : 'Não foi possível salvar.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final total = (_parsePtBrNumber(_qtdCtrl.text) ?? 0) * (_parsePtBrNumber(_unitCtrl.text) ?? 0);

    return Padding(
      padding: EdgeInsets.only(left: AppSpacing.md, right: AppSpacing.md, bottom: viewInsets.bottom + AppSpacing.md, top: AppSpacing.md),
      child: DecoratedBox(
        decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(AppRadius.xl)),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(_isEdit ? 'Editar item' : 'Novo item', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
                  IconButton(onPressed: _saving ? null : () => context.pop(false), icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant), tooltip: 'Fechar'),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              if (_error != null) ...[
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: cs.error.withValues(alpha: 0.22)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline_rounded, color: cs.onErrorContainer),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(child: Text(_error!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onErrorContainer, height: 1.25))),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              DropdownButtonFormField<int>(
                // Cursor no primeiro campo ao abrir.
                autofocus: true,
                value: int.tryParse(_itemCtrl.text),
                isExpanded: true,
                icon: Icon(Icons.keyboard_arrow_down_rounded, color: cs.onSurfaceVariant),
                items: _itemOptions
                    .map((r) {
                      final id = r['itemid'];
                      if (id is! num) return null;
                      final label = (r['nome'] ?? id).toString();
                      return DropdownMenuItem<int>(value: id.toInt(), child: Text(label, overflow: TextOverflow.ellipsis));
                    })
                    .whereType<DropdownMenuItem<int>>()
                    .toList(growable: false),
                onChanged: (_loadingOptions || _saving)
                    ? null
                    : (v) {
                        _itemCtrl.text = v?.toString() ?? '';
                        setState(() {});
                      },
                decoration: InputDecoration(
                  labelText: 'Item *',
                  prefixIcon: _loadingOptions
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary)),
                        )
                      : Icon(Icons.inventory_2_outlined, color: cs.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qtdCtrl,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: false),
                      inputFormatters: const [PtBrDecimalThousands2Formatter(maxIntDigits: 5)],
                      decoration: const InputDecoration(labelText: 'Quantidade *'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: TextField(
                      controller: _unitCtrl,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: false),
                      inputFormatters: const [PtBrDecimalThousands2Formatter(maxIntDigits: 5)],
                      decoration: const InputDecoration(labelText: 'Valor unitário *'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              InputDecorator(
                decoration: const InputDecoration(labelText: 'Valor total'),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _formatPtBrMoney(total),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _validadeCtrl,
                readOnly: true,
                onTap: _pickValidade,
                decoration: InputDecoration(
                  labelText: 'Data de validade',
                  prefixIcon: Icon(Icons.event_rounded, color: cs.onSurfaceVariant),
                  suffixIcon: IconButton(
                    tooltip: 'Selecionar data',
                    onPressed: _saving ? null : _pickValidade,
                    icon: Icon(Icons.calendar_month_rounded, color: _saving ? cs.onSurfaceVariant.withValues(alpha: 0.5) : cs.primary),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : () => context.pop(false),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: Icon(Icons.check_rounded, color: cs.onPrimary),
                      label: Text('Salvar', style: TextStyle(color: cs.onPrimary)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BrDateFormatter extends TextInputFormatter {
  const BrDateFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final t = digits.length > 8 ? digits.substring(0, 8) : digits;

    final b = StringBuffer();
    for (int i = 0; i < t.length; i += 1) {
      b.write(t[i]);
      if (i == 1 || i == 3) {
        if (i != t.length - 1) b.write('/');
      }
    }
    final formatted = b.toString();
    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
  }
}

class PtBrDecimalThousands2Formatter extends TextInputFormatter {
  const PtBrDecimalThousands2Formatter({required this.maxIntDigits});

  final int maxIntDigits;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9,]'), '');
    final parts = cleaned.split(',');
    final intPartRaw = parts.isNotEmpty ? parts.first : '';
    final decPartRaw = parts.length > 1 ? parts.sublist(1).join() : '';

    var intDigits = intPartRaw.replaceAll(RegExp(r'\D'), '');
    if (intDigits.length > maxIntDigits) intDigits = intDigits.substring(0, maxIntDigits);

    var decDigits = decPartRaw.replaceAll(RegExp(r'\D'), '');
    if (decDigits.length > 2) decDigits = decDigits.substring(0, 2);

    String formattedInt;
    if (intDigits.isEmpty) {
      formattedInt = '';
    } else {
      final b = StringBuffer();
      for (int i = 0; i < intDigits.length; i += 1) {
        b.write(intDigits[i]);
        final remaining = intDigits.length - i - 1;
        if (remaining > 0 && remaining % 3 == 0) b.write('.');
      }
      formattedInt = b.toString();
    }

    final hasComma = cleaned.contains(',');
    final formatted = switch ((hasComma, decDigits.isNotEmpty)) {
      (true, true) => '$formattedInt,$decDigits',
      (true, false) => '$formattedInt,',
      _ => formattedInt,
    };

    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
  }
}

num? _num(dynamic v) {
  if (v is num) return v;
  if (v == null) return null;
  return num.tryParse(v.toString());
}

String _formatBrDate(dynamic v) {
  if (v == null) return '';
  final raw = v.toString().trim();
  if (raw.isEmpty) return '';
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(raw);
  if (m == null) return raw;
  return '${m.group(3)}/${m.group(2)}/${m.group(1)}';
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

class _CompraHeaderCard extends StatelessWidget {
  const _CompraHeaderCard({required this.compra, required this.onEdit});

  final Map<String, dynamic> compra;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final data = _formatBrDate(compra['datacompra']);
    final fornecedor = ((compra['fornecedor'] as Map?)?['nomefantasia'] ?? '').toString().trim();
    final nf = (compra['numeronf'] ?? '').toString().trim();
    final valor = _formatPtBrCurrency(compra['valorcompra']);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Dados da compra',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                FilledButton.icon(
                  onPressed: onEdit,
                  icon: Icon(Icons.edit_rounded, color: cs.onPrimary),
                  label: Text('Editar dados', style: TextStyle(color: cs.onPrimary)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.sm,
              children: [
                _InfoPill(icon: Icons.event_rounded, label: data.isEmpty ? '-' : data),
                _InfoPill(icon: Icons.storefront_rounded, label: fornecedor.isEmpty ? '-' : fornecedor),
                _InfoPill(icon: Icons.receipt_long_rounded, label: nf.isEmpty ? 'NF: -' : 'NF: $nf'),
                _InfoPill(icon: Icons.payments_rounded, label: valor),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatPtBrCurrency(dynamic v) => 'R\$ ${_formatPtBrMoney(v)}';

String _formatPtBrDecimal(dynamic v) => _formatPtBrMoney(v);

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: cs.primary, size: 18),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.primaryActionLabel,
    required this.primaryActionIcon,
    required this.onPrimaryAction,
    this.secondaryActionLabel,
    this.secondaryActionIcon,
    this.onSecondaryAction,
  });

  final String title;
  final String subtitle;
  final String primaryActionLabel;
  final IconData primaryActionIcon;
  final VoidCallback onPrimaryAction;
  final String? secondaryActionLabel;
  final IconData? secondaryActionIcon;
  final VoidCallback? onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final hasSecondary = secondaryActionLabel != null && onSecondaryAction != null;

    final secondaryBtn = !hasSecondary
        ? null
        : OutlinedButton.icon(
            onPressed: onSecondaryAction,
            icon: Icon(secondaryActionIcon ?? Icons.upload_file_rounded, color: cs.primary),
            label: Text(secondaryActionLabel!, style: TextStyle(color: cs.primary)),
          );

    final primaryBtn = FilledButton.icon(
      onPressed: onPrimaryAction,
      icon: Icon(primaryActionIcon, color: cs.onPrimary),
      label: Text(primaryActionLabel, style: TextStyle(color: cs.onPrimary)),
    );

    // Sempre usa Wrap para as ações: evita que o botão “Importar” fique fora da tela
    // dependendo da largura do Preview/containers.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25)),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            alignment: WrapAlignment.end,
            children: [
              if (secondaryBtn != null) secondaryBtn,
              primaryBtn,
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyInlineCard extends StatelessWidget {
  const _EmptyInlineCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
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
