import 'package:bakepro/pages/cadastros/cadastro_definitions.dart';
import 'package:bakepro/services/kit_service.dart';
import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

/// Cadastro de Setup (registro único).
///
/// Regras:
/// - Não existe lista.
/// - Não permite exclusão.
/// - Abre direto no formulário e faz insert/update conforme exista registro.
class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.definition});
  final CadastroDefinition definition;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _taxaAdmCtrl = TextEditingController();
  final _impostoCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  Map<String, dynamic>? _row;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _taxaAdmCtrl.dispose();
    _impostoCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final session = context.read<AppSessionController>();
      final empresaId = session.empresaId;
      Map<String, dynamic>? row;

      // Primeiro tenta carregar por empresa (se existir a coluna).
      if (empresaId != null && !session.isSuperAdmin) {
        try {
          row = await SupabaseService.selectSingle(widget.definition.table, filters: {'empresaid': empresaId});
        } catch (e) {
          debugPrint('Setup load by empresaid failed (will fallback): $e');
        }
      }

      // Fallback: pega o primeiro registro (tabela de registro único global).
      if (row == null) {
        final rows = await SupabaseService.select(widget.definition.table, orderBy: widget.definition.idColumn, ascending: true, limit: 1);
        row = rows.isNotEmpty ? rows.first : null;
      }

      _row = row;

      if (row != null) {
        _taxaAdmCtrl.text = _formatPtBrFixed(_asNum(row['taxaadm']), 2);
        _impostoCtrl.text = _formatPtBrFixed(_asNum(row['imposto']), 2);
      } else {
        _taxaAdmCtrl.text = '0,00';
        _impostoCtrl.text = '0,00';
      }
    } catch (e) {
      debugPrint('Setup load failed: $e');
      _error = 'Não foi possível carregar o Setup.';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  num? _asNum(dynamic v) {
    if (v == null) return null;
    if (v is num) return v;
    return _parsePtBrNumber(v.toString());
  }

  num? _parsePtBrNumber(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final normalized = trimmed.replaceAll('.', '').replaceAll(',', '.');
    return num.tryParse(normalized);
  }

  String _formatPtBrFixed(num? value, int fractionDigits) {
    if (value == null) return '';
    final s = value.toStringAsFixed(fractionDigits);
    final parts = s.split('.');
    final intPart = parts.first;
    final decPart = parts.length > 1 ? parts.last : '';
    return '$intPart,$decPart';
  }

  Map<String, dynamic> _buildUpdateFilters(Map<String, dynamic> row) {
    // Prefer: primary key; fallback to empresaid if available.
    if (row.containsKey(widget.definition.idColumn) && row[widget.definition.idColumn] != null) {
      return {widget.definition.idColumn: row[widget.definition.idColumn]};
    }
    if (row.containsKey('empresaid') && row['empresaid'] != null) return {'empresaid': row['empresaid']};
    // Best-effort: any *_id like column.
    for (final entry in row.entries) {
      final k = entry.key.toString();
      if (k.toLowerCase().endsWith('id') && entry.value != null) return {k: entry.value};
    }
    return const {};
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final taxaAdm = _parsePtBrNumber(_taxaAdmCtrl.text) ?? 0;
      final imposto = _parsePtBrNumber(_impostoCtrl.text) ?? 0;
      final data = <String, dynamic>{'taxaadm': taxaAdm, 'imposto': imposto};

      final session = context.read<AppSessionController>();
      final empresaId = session.empresaId;

      if (_row == null) {
        // Insert: tenta incluir empresaid quando disponível.
        Map<String, dynamic> insertData = {...data};
        if (empresaId != null) insertData['empresaid'] = empresaId;
        try {
          final inserted = await SupabaseService.insert(widget.definition.table, insertData);
          _row = inserted.isNotEmpty ? inserted.first : null;
        } catch (e) {
          debugPrint('Setup insert with empresaid failed (retry without): $e');
          final inserted = await SupabaseService.insert(widget.definition.table, data);
          _row = inserted.isNotEmpty ? inserted.first : null;
        }
      } else {
        final filters = _buildUpdateFilters(_row!);
        if (filters.isEmpty) {
          // If we cannot reliably update, fallback to insert.
          debugPrint('Setup update filters empty; falling back to insert');
          final inserted = await SupabaseService.insert(widget.definition.table, data);
          _row = inserted.isNotEmpty ? inserted.first : _row;
        } else {
          final updated = await SupabaseService.update(widget.definition.table, data, filters: filters);
          if (updated.isNotEmpty) _row = updated.first;
        }
      }
      KitService.clearEmpresaSetupCache();

      if (!mounted) return;
    } catch (e) {
      debugPrint('Setup save failed: $e');
      if (mounted) setState(() => _error = 'Não foi possível salvar o Setup.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = context.watch<AppSessionController>();
    final showEmpresaInTitle = !session.isSuperAdmin && (session.empresaId != null || (session.empresaNome ?? '').trim().isNotEmpty);
    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: () => context.go('/cadastros'),
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Voltar para Cadastros básico',
              ),
            ),
            Row(
              children: [
                Expanded(child: Text('Setup', style: Theme.of(context).textTheme.headlineSmall)),
                if (showEmpresaInTitle)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(AppRadius.xl),
                      border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.apartment_rounded, size: 16, color: cs.onPrimaryContainer),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 220),
                            child: Text(
                              session.empresaLabel,
                              style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onPrimaryContainer),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              session.isSuperAdmin ? 'Parâmetros globais do sistema.' : 'Parâmetros da sua empresa.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.35),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                  border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
                ),
                child: Padding(
                  padding: AppSpacing.paddingLg,
                  child: _loading
                      ? Center(child: CircularProgressIndicator(color: cs.primary))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_error != null) ...[
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: cs.errorContainer,
                                  borderRadius: BorderRadius.circular(AppRadius.lg),
                                  border: Border.all(color: cs.error.withValues(alpha: 0.35)),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(_error!, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onErrorContainer)),
                                ),
                              ),
                              const SizedBox(height: AppSpacing.md),
                            ],
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _taxaAdmCtrl,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: false),
                                    inputFormatters: const [
                                      _PtBrDecimalFormatter(maxIntDigits: 3, decimalDigits: 2, useThousandsSeparator: false),
                                    ],
                                    decoration: const InputDecoration(labelText: 'Taxa administrativo (%) *', hintText: '999,99'),
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.md),
                                Expanded(
                                  child: TextField(
                                    controller: _impostoCtrl,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: false),
                                    inputFormatters: const [
                                      _PtBrDecimalFormatter(maxIntDigits: 3, decimalDigits: 2, useThousandsSeparator: false),
                                    ],
                                    decoration: const InputDecoration(labelText: 'Imposto de renda (%) *', hintText: '999,99'),
                                  ),
                                ),
                              ],
                            ),
                            const Spacer(),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.icon(
                                    onPressed: _saving ? null : _save,
                                    icon: _saving
                                        ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary))
                                        : Icon(Icons.save_rounded, color: cs.onPrimary),
                                    label: Text('Salvar', style: TextStyle(color: cs.onPrimary)),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Formats pt-BR decimals while typing.
///
/// Rules:
/// - Digits only for integer part (and optional comma for decimals)
/// - Decimal separator: ','
/// - Limits integer/decimal digits
class _PtBrDecimalFormatter extends TextInputFormatter {
  const _PtBrDecimalFormatter({required this.maxIntDigits, required this.decimalDigits, required this.useThousandsSeparator});

  final int maxIntDigits;
  final int decimalDigits;
  final bool useThousandsSeparator;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text;

    // Keep only digits and comma.
    final cleaned = raw.replaceAll(RegExp(r'[^0-9,]'), '');
    final parts = cleaned.split(',');
    final intPartRaw = parts.isNotEmpty ? parts.first : '';
    final decPartRaw = parts.length > 1 ? parts.sublist(1).join() : '';

    var intDigits = intPartRaw.replaceAll(RegExp(r'\D'), '');
    if (intDigits.length > maxIntDigits) intDigits = intDigits.substring(0, maxIntDigits);

    var decDigits = decPartRaw.replaceAll(RegExp(r'\D'), '');
    if (decDigits.length > decimalDigits) decDigits = decDigits.substring(0, decimalDigits);

    String formattedInt;
    if (intDigits.isEmpty) {
      formattedInt = '';
    } else if (!useThousandsSeparator) {
      formattedInt = intDigits;
    } else {
      final b = StringBuffer();
      for (int i = 0; i < intDigits.length; i++) {
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
