import 'dart:convert';
import 'dart:typed_data';

import 'package:bakepro/pages/cadastros/cadastro_definitions.dart';
import 'package:bakepro/pages/cadastros/db_column_lengths.dart';
import 'package:bakepro/services/kit_service.dart';
import 'package:bakepro/services/totaldespesas_service.dart';
import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/theme.dart';
import 'package:bakepro/utils/picked_file_bytes.dart';
import 'package:bakepro/utils/text_normalization.dart';
import 'package:bakepro/utils/web_file_input.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:postgrest/postgrest.dart';
import 'package:provider/provider.dart';

class _DigitsOnlyMaxLengthFormatter extends TextInputFormatter {
  _DigitsOnlyMaxLengthFormatter(this.maxDigits);
  final int maxDigits;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final truncated = digits.length > maxDigits ? digits.substring(0, maxDigits) : digits;
    return TextEditingValue(text: truncated, selection: TextSelection.collapsed(offset: truncated.length));
  }
}

/// Formats Brazilian dates while typing: dd/MM/aaaa.
///
/// Keeps only digits and inserts `/` after day and month.
class _BrDateFormatter extends TextInputFormatter {
  const _BrDateFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final truncated = digits.length > 8 ? digits.substring(0, 8) : digits;

    final b = StringBuffer();
    for (int i = 0; i < truncated.length; i += 1) {
      b.write(truncated[i]);
      if (i == 1 || i == 3) {
        if (i != truncated.length - 1) b.write('/');
      }
    }

    final formatted = b.toString();
    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
  }
}

/// Formats pt-BR decimals while typing.
///
/// Rules:
/// - Digits only for integer part (and optional comma for decimals)
/// - Thousands separator: '.' (optional)
/// - Decimal separator: ','
/// - Limits integer/decimal digits
///
/// Note: this formatter is UI-only; saving still parses into a `num`.
class _PtBrDecimalFormatter extends TextInputFormatter {
  const _PtBrDecimalFormatter({
    required this.maxIntDigits,
    required this.decimalDigits,
    required this.useThousandsSeparator,
  });

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

/// Currency-like formatter that always keeps 2 decimal digits (pt-BR): `0,00`.
///
/// It treats the typed digits as "cents" and formats as: `<inteiro>,<2 dec>`.
/// Example inputs (digits only):
/// - `` -> `0,00`
/// - `1` -> `0,01`
/// - `12` -> `0,12`
/// - `123` -> `1,23`
class _PtBrCentsFormatter extends TextInputFormatter {
  const _PtBrCentsFormatter({required this.maxIntDigits});

  final int maxIntDigits;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      return const TextEditingValue(text: '0,00', selection: TextSelection.collapsed(offset: 4));
    }

    // Limit integer digits (excluding the 2 decimal digits).
    final maxTotalDigits = maxIntDigits + 2;
    final truncated = digits.length > maxTotalDigits ? digits.substring(digits.length - maxTotalDigits) : digits;

    final padded = truncated.padLeft(3, '0');
    final intPart = padded.substring(0, padded.length - 2);
    final decPart = padded.substring(padded.length - 2);

    final normalizedInt = intPart.replaceFirst(RegExp(r'^0+'), '');
    final formattedInt = normalizedInt.isEmpty ? '0' : normalizedInt;
    final formatted = '$formattedInt,$decPart';

    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
  }
}

/// Formats Brazilian phone numbers as:
/// - 9 digits: 99999-9999
/// - 8 digits: 9999-9999
///
/// (DDD is stored in a separate field in this app.)
class _BrPhoneNumberFormatter extends TextInputFormatter {
  const _BrPhoneNumberFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final truncated = digits.length > 9 ? digits.substring(0, 9) : digits;

    String formatted;
    if (truncated.length <= 4) {
      formatted = truncated;
    } else if (truncated.length <= 8) {
      // 8 digits: 9999-9999
      formatted = '${truncated.substring(0, 4)}-${truncated.substring(4)}';
    } else {
      // 9 digits: 99999-9999
      formatted = '${truncated.substring(0, 5)}-${truncated.substring(5)}';
    }

    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
  }
}

/// Formats Brazilian CPF while typing: 999.999.999-99
class _CpfFormatter extends TextInputFormatter {
  const _CpfFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final truncated = digits.length > 11 ? digits.substring(0, 11) : digits;

    String formatted;
    if (truncated.length <= 3) {
      formatted = truncated;
    } else if (truncated.length <= 6) {
      formatted = '${truncated.substring(0, 3)}.${truncated.substring(3)}';
    } else if (truncated.length <= 9) {
      formatted = '${truncated.substring(0, 3)}.${truncated.substring(3, 6)}.${truncated.substring(6)}';
    } else {
      formatted =
          '${truncated.substring(0, 3)}.${truncated.substring(3, 6)}.${truncated.substring(6, 9)}-${truncated.substring(9)}';
    }

    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
  }
}

/// Formats Brazilian CNPJ while typing: 99.999.999/9999-99
///
/// Stores only digits in the controller (formatting is UI-only).
class _CnpjFormatter extends TextInputFormatter {
  const _CnpjFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final truncated = digits.length > 14 ? digits.substring(0, 14) : digits;

    String formatted;
    if (truncated.length <= 2) {
      formatted = truncated;
    } else if (truncated.length <= 5) {
      formatted = '${truncated.substring(0, 2)}.${truncated.substring(2)}';
    } else if (truncated.length <= 8) {
      formatted = '${truncated.substring(0, 2)}.${truncated.substring(2, 5)}.${truncated.substring(5)}';
    } else if (truncated.length <= 12) {
      formatted =
          '${truncated.substring(0, 2)}.${truncated.substring(2, 5)}.${truncated.substring(5, 8)}/${truncated.substring(8)}';
    } else {
      formatted =
          '${truncated.substring(0, 2)}.${truncated.substring(2, 5)}.${truncated.substring(5, 8)}/${truncated.substring(8, 12)}-${truncated.substring(12)}';
    }

    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
  }
}

class GenericCadastroFormSheet extends StatefulWidget {
  const GenericCadastroFormSheet({
    super.key,
    required this.definition,
    this.initialRow,
    this.forcedValues,
    this.hiddenColumns = const <String>{},
    this.readOnlyColumns = const <String>{},
  });

  final CadastroDefinition definition;
  final Map<String, dynamic>? initialRow;

  /// Values that will always be applied on save (and can be used to prefill the UI).
  /// Useful for creating nested records like ingrediente where `receitaid` must be fixed.
  final Map<String, dynamic>? forcedValues;

  /// Columns to omit from the form UI.
  final Set<String> hiddenColumns;

  /// Columns that should render but not be editable.
  final Set<String> readOnlyColumns;

  @override
  State<GenericCadastroFormSheet> createState() => _GenericCadastroFormSheetState();
}

/// Detalhes do Item selecionado no cadastro de Despesas Variáveis.
class DespesaVariavelItemDetailsCard extends StatelessWidget {
  const DespesaVariavelItemDetailsCard({
    super.key,
    required this.itemRow,
    required this.marcaNome,
    required this.unidadeLabel,
    required this.isLoading,
    required this.formatCurrency4,
  });

  final Map<String, dynamic>? itemRow;
  final String? marcaNome;
  final String? unidadeLabel;
  final bool isLoading;
  final String Function(num value) formatCurrency4;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    final nome = itemRow?['nome']?.toString().trim();
    final custo = itemRow?['custounitario'];
    final custoNum = (custo is num) ? custo : num.tryParse(custo?.toString() ?? '');
    final unitSuffix = (unidadeLabel != null && unidadeLabel!.trim().isNotEmpty) ? '/${unidadeLabel!.trim()}' : '/un';

    Widget line(String label, String value) => Row(
          children: [
            Expanded(flex: 3, child: Text(label, style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant))),
            Expanded(flex: 5, child: Text(value, style: t.bodyMedium?.copyWith(color: cs.onSurface))),
          ],
        );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: DecoratedBox(
        key: ValueKey('${itemRow?['itemid']}-${isLoading ? 'loading' : 'ready'}'),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
        ),
        child: Padding(
          padding: AppSpacing.paddingMd,
          child: isLoading
              ? Row(
                  children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary)),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: Text('Carregando detalhes do item…', style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant))),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline_rounded, color: cs.primary),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(child: Text('Detalhes do Item', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (nome != null && nome.isNotEmpty) ...[line('Nome', nome), const SizedBox(height: AppSpacing.xs)],
                    if (marcaNome != null && marcaNome!.isNotEmpty) ...[
                      line('Marca', marcaNome!),
                      const SizedBox(height: AppSpacing.xs),
                    ],
                    if (unidadeLabel != null && unidadeLabel!.isNotEmpty) ...[
                      line('Unidade', unidadeLabel!),
                      const SizedBox(height: AppSpacing.xs),
                    ],
                    // Mesmo padrão do formulário de item: "Custo unitário (R$/gr)" e valor "R$ 0,0464/gr".
                    if (custoNum != null) line('Custo unitário (R\$$unitSuffix)', '${formatCurrency4(custoNum)}$unitSuffix'),
                    if (itemRow == null) Text('Selecione um item para ver os detalhes.', style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
        ),
      ),
    );
  }
}

class _GenericCadastroFormSheetState extends State<GenericCadastroFormSheet> {

  /// Campos de texto longo exibidos em várias linhas (hoje: Descrição de Kit, Produto e Receita).
  bool _isMultilineField(CadastroField f) =>
      f.type == CadastroFieldType.text && const {'descricao', 'obs'}.contains(f.column.toLowerCase());

  bool _shouldNormalizeCadastroText(CadastroField f) {
    // Only normalize free text fields.
    if (f.type != CadastroFieldType.text) return false;
    final c = f.column.toLowerCase();

    // Do not normalize sensitive/auth-like inputs.
    if (isProbablySensitiveTextField(c)) return false;

    // Do not normalize technical/blob-like fields.
    if (c.contains('base64') || c.contains('mime')) return false;

    // Email/site are handled separately and are expected to have no spaces.
    if (c == 'email' || c == 'site') return false;
    return true;
  }
  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, List<Map<String, dynamic>>> _fkOptions = {};
  final Set<String> _fkLoading = {};
  final Map<String, bool> _obscureByColumn = {};
  bool _isSaving = false;
  String? _error;
  bool _usuarioEmpresaAutoAssigned = false;
  bool _empresaDeliveryEmpresaAutoAssigned = false;

  void _clearErrorOnUserInteraction() {
    if (!mounted) return;
    if (_error == null) return;
    setState(() => _error = null);
  }

  Map<String, dynamic>? _dvItemRow;
  String? _dvMarcaNome;
  String? _dvUnidadeLabel;
  bool _dvLoadingDetails = false;

  bool _dvRecomputing = false;
  bool _dvValorMensalManualOverride = false;
  final FocusNode _dvValorMensalFocusNode = FocusNode(debugLabel: 'dv_valormensal');

  // Empresa logo (stored in DB as base64).
  Uint8List? _empresaLogoBytes;
  String? _empresaLogoMime;
  bool _empresaLogoDirty = false;

  bool get _isEdit => widget.initialRow != null;

  // Imposto e taxas da empresa (tabela `empresasetup`).
  bool get _isEmpresaTaxas => widget.definition.keyName == 'empresataxas';
  static const Set<String> _empresaTaxasValueColumns = {'imposto', 'taxaadm', 'taxamotoboy'};

  bool get _isUsuario => widget.definition.keyName == 'usuario';

  bool get _isProduto => widget.definition.keyName == 'produto';

  bool get _isItem => widget.definition.keyName == 'item';

  bool get _isRateioDespesa => widget.definition.keyName == 'rateiodespesa';

  bool get _isEmpresa => widget.definition.keyName == 'empresa';

  bool get _isFornecedor => widget.definition.keyName == 'fornecedor';

  bool get _isCompra => widget.definition.keyName == 'compra';

  bool get _isCompraItem => widget.definition.keyName == 'compraitem';

  bool get _isDespesaVariavel => widget.definition.keyName == 'despesavariavel';

  bool get _hasStatusField => _ctrls.containsKey('status');

  String? get _empresaTipoDocumento {
    if (!_isEmpresa) return null;
    final raw = _ctrls['tipodocumento']?.text.trim().toUpperCase();
    if (raw == 'J' || raw == 'F') return raw;
    return null;
  }

  String? get _fornecedorTipoDocumento {
    if (!_isFornecedor) return null;
    final raw = _ctrls['tipodocumento']?.text.trim().toUpperCase();
    if (raw == 'J' || raw == 'F') return raw;
    return null;
  }

  static bool _isValidCpf(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 11) return false;
    // Reject sequences like 00000000000, 11111111111, ...
    if (RegExp(r'^(\d)\1{10}\$').hasMatch(digits)) return false;

    final nums = digits.split('').map(int.parse).toList(growable: false);
    int sum1 = 0;
    for (int i = 0; i < 9; i += 1) {
      sum1 += nums[i] * (10 - i);
    }
    int dv1 = (sum1 * 10) % 11;
    if (dv1 == 10) dv1 = 0;
    if (dv1 != nums[9]) return false;

    int sum2 = 0;
    for (int i = 0; i < 10; i += 1) {
      sum2 += nums[i] * (11 - i);
    }
    int dv2 = (sum2 * 10) % 11;
    if (dv2 == 10) dv2 = 0;
    return dv2 == nums[10];
  }

  static bool _isValidCnpj(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 14) return false;
    if (RegExp(r'^(\d)\1{13}\$').hasMatch(digits)) return false;

    final nums = digits.split('').map(int.parse).toList(growable: false);
    const w1 = [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
    const w2 = [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];

    int sum1 = 0;
    for (int i = 0; i < 12; i += 1) {
      sum1 += nums[i] * w1[i];
    }
    int mod1 = sum1 % 11;
    final dv1 = (mod1 < 2) ? 0 : 11 - mod1;
    if (dv1 != nums[12]) return false;

    int sum2 = 0;
    for (int i = 0; i < 13; i += 1) {
      sum2 += nums[i] * w2[i];
    }
    int mod2 = sum2 % 11;
    final dv2 = (mod2 < 2) ? 0 : 11 - mod2;
    return dv2 == nums[13];
  }

  num? _parsePtBrNumber(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;

    // Pontos em grupos de 3 sem vírgula ("1.000", "12.345.678") são separador de
    // milhar das máscaras pt-BR — não decimal. Antes, "1.000" virava 1.
    final isPtBrThousandsOnly = RegExp(r'^-?\d{1,3}(\.\d{3})+$').hasMatch(t);

    // Fast path: accept standard dot-decimal input (e.g. "10.12").
    // This avoids turning decimals into thousands when users type '.' as decimal.
    final direct = isPtBrThousandsOnly ? null : num.tryParse(t);
    if (direct != null) return direct;

    // pt-BR normalization: remove thousand separators '.' and swap ',' -> '.'
    // Examples:
    //  - 21,20 -> 21.20
    //  - 1.234,56 -> 1234.56
    final normalized = t.replaceAll('.', '').replaceAll(',', '.');
    return num.tryParse(normalized);
  }

  String _formatPtBrFixed(num value, int decimalDigits) {
    final s = value.toStringAsFixed(decimalDigits);
    return s.replaceAll('.', ',');
  }

  String _formatPtBrThousands(num value, int decimalDigits) {
    final fixed = value.toStringAsFixed(decimalDigits);
    final parts = fixed.split('.');
    var intPart = parts.first;
    final decPart = parts.length > 1 ? parts.last : '';

    final sb = StringBuffer();
    for (int i = 0; i < intPart.length; i += 1) {
      sb.write(intPart[i]);
      final remaining = intPart.length - i - 1;
      if (remaining > 0 && remaining % 3 == 0) sb.write('.');
    }
    final formattedInt = sb.toString();
    return '$formattedInt,${decPart.padRight(decimalDigits, '0')}';
  }

  String _formatPtBrCurrencyThousands(num value, int decimalDigits) => 'R\$ ${_formatPtBrThousands(value, decimalDigits)}';

  void _recomputeDespesaVariavelValorMensal() {
    if (!_isDespesaVariavel) return;
    if (_dvRecomputing) return;
    // Se o usuário editou manualmente o valor mensal, não sobrescrever.
    // Ele pode tocar no ícone de recalcular para voltar ao automático.
    if (_dvValorMensalManualOverride) return;
    // Se o campo está com foco (usuário digitando), não recalcular no meio da edição.
    if (_dvValorMensalFocusNode.hasFocus) return;

    final totalCtrl = _ctrls['valormensal'];
    if (totalCtrl == null) return;

    final consumoRaw = _ctrls['consumomensal']?.text.trim() ?? '';
    final consumo = _parsePtBrNumber(consumoRaw);

    final custoRaw = _dvItemRow?['custounitario'];
    final custo = (custoRaw is num) ? custoRaw.toDouble() : double.tryParse(custoRaw?.toString() ?? '');

    if (consumo == null || custo == null) return;

    final total = consumo * custo;
    final formatted = _formatPtBrThousands(total, 2);
    if (totalCtrl.text.trim() == formatted) return;

    _dvRecomputing = true;
    try {
      totalCtrl.text = formatted;
    } finally {
      _dvRecomputing = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadDespesaVariavelItemDetails(int itemId) async {
    if (!_isDespesaVariavel) return;
    setState(() {
      _dvLoadingDetails = true;
      _dvItemRow = null;
      _dvMarcaNome = null;
      _dvUnidadeLabel = null;
    });

    try {
      final item = await SupabaseService.selectSingle(
        'item',
        select: 'itemid,nome,marcaid,unidadeid,custounitario',
        filters: {'itemid': itemId},
      );
      if (!mounted) return;

      if (item == null) {
        setState(() => _dvItemRow = null);
        return;
      }

      String? marcaNome;
      final marcaId = item['marcaid'];
      if (marcaId is num) {
        final marca = await SupabaseService.selectSingle('marca', select: 'marcaid,nome', filters: {'marcaid': marcaId.toInt()});
        marcaNome = marca?['nome']?.toString();
      }

      String? unidadeLabel;
      final unidadeId = item['unidadeid'];
      if (unidadeId is num) {
        final unidade = await SupabaseService.selectSingle('unidade', select: 'unidadeid,unidade', filters: {'unidadeid': unidadeId.toInt()});
        unidadeLabel = unidade?['unidade']?.toString();
      }

      if (!mounted) return;
      setState(() {
        _dvItemRow = item;
        _dvMarcaNome = marcaNome?.trim().isEmpty ?? true ? null : marcaNome?.trim();
        _dvUnidadeLabel = unidadeLabel?.trim().isEmpty ?? true ? null : unidadeLabel?.trim();
      });

      _recomputeDespesaVariavelValorMensal();
    } catch (e) {
      debugPrint('Failed to load DespesaVariavel item details itemId=$itemId: $e');
      if (!mounted) return;
      setState(() => _error = 'Não foi possível carregar detalhes do item.');
    } finally {
      if (!mounted) return;
      setState(() => _dvLoadingDetails = false);
    }
  }

  DateTime? _parseBrDate(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    // dd/MM/yyyy
    // NOTE: do NOT escape the `$` end-of-string anchor.
    final m = RegExp(r'^(\d{2})\/(\d{2})\/(\d{4})$').firstMatch(t);
    if (m == null) return null;
    final dd = int.tryParse(m.group(1)!);
    final mm = int.tryParse(m.group(2)!);
    final yyyy = int.tryParse(m.group(3)!);
    if (dd == null || mm == null || yyyy == null) return null;
    try {
      final dt = DateTime(yyyy, mm, dd);
      // Validate that DateTime didn't overflow (e.g., 32/01/2025 => Feb 1).
      if (dt.year != yyyy || dt.month != mm || dt.day != dd) return null;
      return dt;
    } catch (_) {
      return null;
    }
  }

  String _formatBrDate(dynamic initial) {
    if (initial == null) return '';
    if (initial is DateTime) {
      final dd = initial.day.toString().padLeft(2, '0');
      final mm = initial.month.toString().padLeft(2, '0');
      final yyyy = initial.year.toString().padLeft(4, '0');
      return '$dd/$mm/$yyyy';
    }
    final raw = initial.toString().trim();
    if (raw.isEmpty) return '';
    // Accept ISO date: yyyy-MM-dd or yyyy-MM-ddTHH:mm...
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(raw);
    if (iso != null) {
      final yyyy = iso.group(1)!;
      final mm = iso.group(2)!;
      final dd = iso.group(3)!;
      return '$dd/$mm/$yyyy';
    }
    // If already in dd/MM/yyyy, keep.
    if (RegExp(r'^\d{2}\/\d{2}\/\d{4}$').hasMatch(raw)) return raw;
    return raw;
  }

  String _formatBrDateTime(dynamic initial) {
    if (initial == null) return '';
    DateTime? dt;
    if (initial is DateTime) {
      dt = initial;
    } else {
      final raw = initial.toString().trim();
      if (raw.isEmpty) return '';
      dt = DateTime.tryParse(raw);
    }
    if (dt == null) return initial.toString();
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final yyyy = dt.year.toString().padLeft(4, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$dd/$mm/$yyyy $hh:$min';
  }

  String _formatCpfDigits(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';
    final v = digits.length > 11 ? digits.substring(0, 11) : digits;
    if (v.length <= 3) return v;
    if (v.length <= 6) return '${v.substring(0, 3)}.${v.substring(3)}';
    if (v.length <= 9) return '${v.substring(0, 3)}.${v.substring(3, 6)}.${v.substring(6)}';
    return '${v.substring(0, 3)}.${v.substring(3, 6)}.${v.substring(6, 9)}-${v.substring(9)}';
  }

  String _formatCnpjDigits(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';
    final v = digits.length > 14 ? digits.substring(0, 14) : digits;
    if (v.length <= 2) return v;
    if (v.length <= 5) return '${v.substring(0, 2)}.${v.substring(2)}';
    if (v.length <= 8) return '${v.substring(0, 2)}.${v.substring(2, 5)}.${v.substring(5)}';
    if (v.length <= 12) {
      return '${v.substring(0, 2)}.${v.substring(2, 5)}.${v.substring(5, 8)}/${v.substring(8)}';
    }
    return '${v.substring(0, 2)}.${v.substring(2, 5)}.${v.substring(5, 8)}/${v.substring(8, 12)}-${v.substring(12)}';
  }

  String _formatBrPhone9or8(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';
    final v = digits.length > 9 ? digits.substring(0, 9) : digits;
    if (v.length <= 4) return v;
    if (v.length <= 8) return '${v.substring(0, 4)}-${v.substring(4)}';
    return '${v.substring(0, 5)}-${v.substring(5)}';
  }

  String _formatInitialValueForField(CadastroField f, dynamic initial) {
    if (initial == null) return '';
    final rawText = initial.toString();

    if (f.column.toLowerCase() == 'dataatualizacao') return _formatBrDateTime(initial);

    // Documents (stored as digits on DB; shown masked in UI).
    if ((_isEmpresa || _isFornecedor) && f.column == 'cpf') return _formatCpfDigits(rawText);
    if ((_isEmpresa || _isFornecedor) && f.column == 'cnpj') return _formatCnpjDigits(rawText);

    // Empresa phone number (DDD is a separate field).
    if (_isEmpresa && f.column == 'celular') return _formatBrPhone9or8(rawText);

    // Numeric fields with pt-BR decimal mask should open already formatted.
    if (f.type == CadastroFieldType.number) {
      final parsed = (initial is num) ? initial : _parsePtBrNumber(rawText);
      if (parsed == null) return rawText;

      if (widget.definition.keyName == 'ingrediente' && f.column == 'quantidadegrama') {
        return _formatPtBrFixed(parsed, 4);
      }
      if (widget.definition.keyName == 'produtoreceita' && f.column == 'quantidadereceita') {
        return _formatPtBrFixed(parsed, 2);
      }
      if (_isProduto && f.column == 'valorvenda') {
        return _formatPtBrFixed(parsed, 2);
      }
      if (_isItem && (f.column == 'custounitario' || f.column == 'fatorconversao')) {
        return _formatPtBrFixed(parsed, 4);
      }
      if (_isItem && (f.column == 'qtdecomprada' || f.column == 'valorcompra')) {
        return _formatPtBrThousands(parsed, 2);
      }
      if (_isRateioDespesa && (f.column == 'totaldespesafixa' || f.column == 'valormensal')) {
        // Despesas Fixas agora usam `despesafixa.valormensal` (monetário).
        return _formatPtBrThousands(parsed, 2);
      }

      if (_isDespesaVariavel && f.column == 'consumomensal') {
        return _formatPtBrFixed(parsed, 4);
      }
      if (_isDespesaVariavel && f.column == 'valormensal') {
        return _formatPtBrThousands(parsed, 2);
      }

      if (_isCompra && f.column == 'valorcompra') {
        return _formatPtBrThousands(parsed, 2);
      }
      if (_isCompraItem && (f.column == 'quantidade' || f.column == 'valorunitario')) {
        return _formatPtBrThousands(parsed, 2);
      }
      if (widget.definition.keyName == 'empresadelivery' && f.column == 'taxadelivery') {
        return _formatPtBrThousands(parsed, 2);
      }
      if (_isEmpresaTaxas && _empresaTaxasValueColumns.contains(f.column)) {
        return _formatPtBrThousands(parsed, 2);
      }
      // Other numeric fields: keep as-is.
      return rawText;
    }

    // Date fields (stored as ISO date / DateTime on DB; shown as dd/MM/yyyy in UI).
    if ((_isCompra && f.column == 'datacompra') || (_isCompraItem && f.column == 'datavalidade')) {
      return _formatBrDate(initial);
    }

    return rawText;
  }

  bool get _hasUsuarioEmpresaSelected {
    if (!_isUsuario) return true;
    final raw = _ctrls['empresaid']?.text.trim() ?? '';
    return raw.isNotEmpty;
  }

  /// Coluna do primeiro campo editável: recebe o cursor ao abrir o formulário.
  /// Ignora campos ocultos, de auditoria, status na inclusão, empresa (fixa/automática)
  /// e campos calculados/bloqueados.
  String? _autoFocusColumnCache;
  bool _autoFocusResolved = false;
  String? get _autoFocusColumn {
    if (_autoFocusResolved) return _autoFocusColumnCache;
    _autoFocusResolved = true;
    for (final f in widget.definition.fields) {
      final c = f.column;
      if (widget.hiddenColumns.contains(c) || widget.readOnlyColumns.contains(c)) continue;
      if (c.toLowerCase() == 'dataatualizacao') continue;
      if (_isStatusField(f) && !_isEdit) continue;
      if (c == 'empresaid') continue;
      if (_isItem && (c == 'custounitario' || c == 'qtdecomprada')) continue;
      if (_isDespesaVariavel && c == 'valormensal') continue;
      // EmpresaDelivery: na edição a associação (empresa/delivery) não muda.
      if (_isEdit && widget.definition.keyName == 'empresadelivery' && c == 'deliveryid') continue;
      _autoFocusColumnCache = c;
      break;
    }
    return _autoFocusColumnCache;
  }

  bool _autoFocusFor(CadastroField f) => f.column == _autoFocusColumn;

  @override
  void initState() {
    super.initState();
    for (final f in widget.definition.fields) {
      // Never prefill password fields (even on edit) to avoid leaking hashes.
      if (_isSenhaField(f)) {
        _ctrls[f.column] = TextEditingController(text: '');
        _obscureByColumn[f.column] = true;
        continue;
      }

      final initial = widget.initialRow?[f.column];
      final initialText = _formatInitialValueForField(f, initial);
      _ctrls[f.column] = TextEditingController(text: initialText);
    }

    if (_isEmpresa) {
      _initEmpresaLogoFromRow(widget.initialRow);
    }

    // Default: any cadastro that has `status` should start as Ativo ('A') when inserting.
    if (!_isEdit && _hasStatusField) {
      final ctrl = _ctrls['status']!;
      if (ctrl.text.trim().isEmpty) ctrl.text = 'A';
    }

    if (_isDespesaVariavel) {
      _ctrls['consumomensal']?.addListener(_recomputeDespesaVariavelValorMensal);
      // `valormensal` é calculado (consumo × custo unitário) e não deve ser editável.
      // Mantemos o valor sempre derivado do consumo/item selecionado.
    }

    if (_isItem) {
      // `custounitario` é calculado e não editável: recalcula ao mudar qtde/fator/valor.
      for (final col in const ['qtdecomprada', 'fatorconversao', 'valorcompra']) {
        _ctrls[col]?.addListener(_recomputeItemCustoUnitario);
      }
      // `qtdecomprada` é calculada: embalagens × itens por embalagem.
      for (final col in _itemEmbalagemColumns) {
        _ctrls[col]?.addListener(_recomputeItemQtdeComprada);
      }
    }

    // Defaults: newly added numeric columns that are NOT NULL in the DB.
    // Keep this conservative and only apply on insert.
    if (!_isEdit) {
      for (final col in const ['custounitario', 'qtdestoqueinicial', 'taxadelivery', 'qtdembalagem', 'qtditemporembalagem']) {
        final ctrl = _ctrls[col];
        if (ctrl == null) continue;
        if (ctrl.text.trim().isEmpty) {
          ctrl.text = switch (col) {
            'custounitario' => '0,0000',
            'taxadelivery' => '0,00',
            'qtdembalagem' || 'qtditemporembalagem' => '1',
            _ => '0',
          };
        }
      }
      // Item novo: Qtde comprada já parte de 1 × 1.
      if (_isItem) _recomputeItemQtdeComprada();
    }

    // Apply forced values as initial UI state (without overriding existing edit values).
    final forced = widget.forcedValues;
    if (forced != null) {
      for (final entry in forced.entries) {
        final col = entry.key;
        if (!_ctrls.containsKey(col)) continue;
        final current = _ctrls[col]!.text.trim();
        if (current.isEmpty) {
          _ctrls[col]!.text = entry.value?.toString() ?? '';
        }
      }
    }

    // NOTE: empresa auto-assign/lock for Usuario is handled reactively in didChangeDependencies.

    // Kick off FK option loads (if any).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadForeignKeyOptions();

      // EmpresaDelivery: the available Delivery options depend on the selected empresa.
      // So we reload only the delivery combo whenever empresa changes.
      if (widget.definition.keyName == 'empresadelivery') {
        _ctrls['empresaid']?.addListener(_onEmpresaDeliveryEmpresaChanged);
      }

      if (_isDespesaVariavel) {
        final raw = _ctrls['itemid']?.text.trim() ?? '';
        final id = int.tryParse(raw);
        if (id != null) _loadDespesaVariavelItemDetails(id);
      }
    });
  }

  void _onEmpresaDeliveryEmpresaChanged() {
    if (!mounted) return;
    if (widget.definition.keyName != 'empresadelivery') return;
    // Debounce-ish: only reload if the value changed since last reload.
    // We keep it simple; the query is cheap and capped.
    _loadForeignKeyOptions(columns: const {'deliveryid'});
  }

  void _initEmpresaLogoFromRow(Map<String, dynamic>? row) {
    if (row == null) return;
    try {
      final b64 = (row['logo_base64'] ?? row['logobase64'] ?? row['imagemlogo_base64'] ?? row['imagem_logo_base64'] ?? row['logo'])?.toString().trim();
      final mime = (row['logo_mime'] ?? row['logomime'])?.toString().trim();
      if (mime != null && mime.isNotEmpty && mime.toLowerCase() != 'null') _empresaLogoMime = mime;
      if (b64 != null && b64.isNotEmpty && b64.toLowerCase() != 'null') {
        final lower = b64.toLowerCase();
        if (lower.startsWith('http://') || lower.startsWith('https://')) return;
        _empresaLogoBytes = base64Decode(b64);
      }
    } catch (e) {
      debugPrint('Failed to init empresa logo from row: $e');
      _empresaLogoBytes = null;
      _empresaLogoMime = null;
    }
  }

  Future<PickedFileBytes?> _pickImageBytes() async {
    try {
      if (webFileInputAvailable) {
        return pickWebFileBytes(accept: 'image/*');
      }
      final result = await FilePicker.pickFiles(type: FileType.image, withData: true, allowMultiple: false);
      if (result == null || result.files.isEmpty) return null;
      final f = result.files.first;
      final bytes = f.bytes;
      if (bytes == null) return null;
      return PickedFileBytes(bytes: bytes, name: f.name, mimeType: f.extension);
    } on MissingPluginException catch (e, st) {
      debugPrint('Image picker MissingPluginException: $e\n$st');
      return null;
    } catch (e, st) {
      debugPrint('Image picker failed: $e\n$st');
      return null;
    }
  }

  String? _inferImageMime(PickedFileBytes file) {
    final m = file.mimeType;
    if (m == null) return null;
    final lower = m.toLowerCase();
    if (lower.startsWith('image/')) return lower;
    if (lower == 'png') return 'image/png';
    if (lower == 'jpg' || lower == 'jpeg') return 'image/jpeg';
    if (lower == 'webp') return 'image/webp';
    return null;
  }

  Future<void> _onPickEmpresaLogo() async {
    final picked = await _pickImageBytes();
    if (!mounted) return;
    if (picked == null || picked.bytes.isEmpty) {
      debugPrint('Empresa logo pick returned null/empty (webFileInputAvailable=$webFileInputAvailable)');
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Não foi possível carregar a imagem selecionada. Tente novamente.'),
          behavior: SnackBarBehavior.floating,
          showCloseIcon: true,
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }
    setState(() {
      _empresaLogoBytes = picked.bytes;
      _empresaLogoMime = _inferImageMime(picked) ?? _empresaLogoMime ?? 'image/png';
      _empresaLogoDirty = true;
    });
  }

  void _onRemoveEmpresaLogo() {
    setState(() {
      _empresaLogoBytes = null;
      _empresaLogoMime = null;
      _empresaLogoDirty = true;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = context.watch<AppSessionController>();

    // EmpresaDelivery / Imposto e taxas: para usuário tipo E, travar/preencher a empresa logada.
    if (widget.definition.keyName == 'empresadelivery' || _isEmpresaTaxas) {
      if (session.isSuperAdmin) return;

      final tipo = (session.profile?.tipoUsuario ?? '').trim().toUpperCase();
      if (tipo != 'E') return;
      if (_empresaDeliveryEmpresaAutoAssigned) return;

      final empresaId = session.empresaId;
      if (empresaId == null) return;

      final ctrl = _ctrls['empresaid'];
      if (ctrl == null) return;
      if (ctrl.text.trim().isNotEmpty) {
        _empresaDeliveryEmpresaAutoAssigned = true;
        return;
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ctrl.text.trim().isNotEmpty) return;
        ctrl.text = empresaId.toString();
        _empresaDeliveryEmpresaAutoAssigned = true;
        setState(() {});
      });
      return;
    }

    if (!_isUsuario) return;

    // If the session profile loads after the sheet opens, we still need to:
    // - auto-assign empresa for non-admin users
    // - keep empresa editable for admin users
    // Apenas Admin geral (A) pode escolher empresa livremente.
    if (session.isSuperAdmin) return;
    if (_usuarioEmpresaAutoAssigned) return;

    final empresaId = session.empresaId;
    if (empresaId == null) return;

    final ctrl = _ctrls['empresaid'];
    if (ctrl == null) return;
    if (ctrl.text.trim().isNotEmpty) {
      _usuarioEmpresaAutoAssigned = true;
      return;
    }

    // Defer controller mutation to the end of the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ctrl.text.trim().isNotEmpty) return;
      ctrl.text = empresaId.toString();
      _usuarioEmpresaAutoAssigned = true;
      setState(() {});
    });
  }

  @override
  void dispose() {
    if (_isDespesaVariavel) {
      _ctrls['consumomensal']?.removeListener(_recomputeDespesaVariavelValorMensal);
    }

    if (_isItem) {
      for (final col in const ['qtdecomprada', 'fatorconversao', 'valorcompra']) {
        _ctrls[col]?.removeListener(_recomputeItemCustoUnitario);
      }
      for (final col in _itemEmbalagemColumns) {
        _ctrls[col]?.removeListener(_recomputeItemQtdeComprada);
      }
    }

    if (widget.definition.keyName == 'empresadelivery') {
      _ctrls['empresaid']?.removeListener(_onEmpresaDeliveryEmpresaChanged);
    }

    _dvValorMensalFocusNode.dispose();
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadForeignKeyOptions({Set<String>? columns}) async {
    final session = context.read<AppSessionController>();
    // For FK dropdowns that are scoped by empresa, prefer the empresa currently
    // selected/filled in the form (important for admin users that can change it),
    // falling back to the session empresa.
    int? resolveEmpresaIdForScopedQueries() {
      final raw = _ctrls['empresaid']?.text.trim();
      if (raw != null && raw.isNotEmpty) {
        final parsed = int.tryParse(raw);
        if (parsed != null) return parsed;
      }
      return session.empresaId;
    }

    final empresaIdForScopedQueries = resolveEmpresaIdForScopedQueries();

    final fkFields = widget.definition.fields.where((f) => f.fk != null).where((f) => columns == null || columns.contains(f.column)).toList();
    if (fkFields.isEmpty) return;

    setState(() {
      _error = null;
      _fkLoading.addAll(fkFields.map((f) => f.column));
    });

    try {
      await Future.wait(
        fkFields.map((f) => _loadForeignKeyOptionsForField(f, empresaIdForScopedQueries)),
      );
    } catch (e) {
      debugPrint('Load FK options failed (${widget.definition.table}): $e');
      if (!mounted) return;
      setState(() => _error = 'Não foi possível carregar listas de seleção.');
    } finally {
      if (!mounted) return;
      setState(() => _fkLoading.clear());
    }
  }

  Future<void> _loadForeignKeyOptionsForField(CadastroField f, int? empresaIdForScopedQueries) async {
    final fk = f.fk!;

    // Base filters that are supported by the generic FK loader.
    final filters = <String, dynamic>{};
    if (fk.scopedByEmpresa && empresaIdForScopedQueries != null) {
      filters['empresaid'] = empresaIdForScopedQueries;
    }

    // Ingrediente -> Item: somente itens do tipo "1" (ex.: insumo) devem aparecer no combo.
    // (Pedido: "No cadastro de ingredientes, somente mostrar no combo box itens com tipoitemid=1")
    if (widget.definition.keyName == 'ingrediente' && f.column == 'itemid' && fk.table == 'item') {
      filters['tipoitemid'] = 1;
    }

    // Material -> Item: somente itens do tipo "3" devem aparecer no combo.
    if (widget.definition.keyName == 'material' && f.column == 'itemid' && fk.table == 'item') {
      filters['tipoitemid'] = 3;
    }

    // Despesa Variável -> Item: somente itens do tipo "4" devem aparecer no combo.
    if (widget.definition.keyName == 'despesavariavel' && f.column == 'itemid' && fk.table == 'item') {
      filters['tipoitemid'] = 4;
    }

    // KitProduto -> Produto: somente produtos ativos (status='A') no combo.
    if (widget.definition.keyName == 'kitproduto' && f.column == 'produtoid' && fk.table == 'produto') {
      filters['status'] = 'A';
    }

    // KitEmbalagem -> Item: somente itens do tipo "2" (Embalagem) no combo.
    if (widget.definition.keyName == 'kitembalagem' && f.column == 'itemid' && fk.table == 'item') {
      filters['tipoitemid'] = 2;
    }

    // Compra -> Fornecedor: somente fornecedores ativos (status='A') no combo.
    if (widget.definition.keyName == 'compra' && f.column == 'fornecedorid' && fk.table == 'fornecedor') {
      filters['status'] = 'A';
    }

    var select = '${fk.idColumn},${fk.labelColumn}';

    // ProdutoReceita -> Receita: precisamos também da unidade da receita
    // para exibir no label do campo "Quantidade receita".
    if (widget.definition.keyName == 'produtoreceita' && f.column == 'receitaid' && fk.table == 'receita') {
      select = '${fk.idColumn},${fk.labelColumn}, unidade:unidadeid(unidade)';
    }

    // EmpresaDelivery -> Delivery: não exibir deliveries já cadastrados para a empresa selecionada.
    if (widget.definition.keyName == 'empresadelivery' && f.column == 'deliveryid' && fk.table == 'delivery') {
      final rawEmpresaId = _ctrls['empresaid']?.text.trim() ?? '';
      final empresaId = int.tryParse(rawEmpresaId);

      // If empresa isn't selected yet (admin users), fall back to the plain list.
      if (empresaId == null) {
        final rows = await SupabaseService.select(
          fk.table,
          select: select,
          filters: filters.isEmpty ? null : filters,
          orderBy: fk.labelColumn,
          ascending: true,
          limit: 500,
        );
        if (!mounted) return;
        setState(() => _fkOptions[f.column] = rows);
        return;
      }

      // Load existing associations to exclude them from the Delivery combo.
      final assoc = await SupabaseConfig.client
          .from('empresadelivery')
          .select('deliveryid')
          .eq('empresaid', empresaId)
          .limit(500);

      final excluded = <int>{};
      for (final row in assoc) {
        final id = row['deliveryid'];
        if (id is int) excluded.add(id);
        if (id is num) excluded.add(id.toInt());
      }

      // When editing, keep the current selected delivery available.
      final currentRaw = _ctrls['deliveryid']?.text.trim() ?? '';
      final currentDeliveryId = int.tryParse(currentRaw);
      if (currentDeliveryId != null) excluded.remove(currentDeliveryId);

      var query = SupabaseConfig.client.from('delivery').select(select);
      if (excluded.isNotEmpty) {
        final idsCsv = excluded.join(',');
        // In PostgREST, exclude values using NOT + IN.
        // (Supabase Dart supports this via `not(column, operator, value)`.)
        query = query.not('deliveryid', 'in', '($idsCsv)');
      }

      final rows = await query.order('nome', ascending: true).limit(500);
      if (!mounted) return;
      setState(() => _fkOptions[f.column] = List<Map<String, dynamic>>.from(rows));

      // If the currently selected delivery became unavailable (e.g. switched empresa), clear it.
      final stillValid = currentDeliveryId == null || rows.any((r) => (r['deliveryid'] is num) && (r['deliveryid'] as num).toInt() == currentDeliveryId);
      if (!stillValid) {
        _ctrls['deliveryid']?.clear();
      }
      return;
    }

    // Kit -> Classificação: somente classificações ativas da empresa logada.
    // Na edição, mantém a classificação atual mesmo se inativa (o combo precisa conter o valor selecionado).
    if (widget.definition.keyName == 'kit' && f.column == 'classificacaokitid' && fk.table == 'classificacaokit') {
      if (empresaIdForScopedQueries == null) {
        if (!mounted) return;
        setState(() => _fkOptions[f.column] = const []);
        return;
      }
      final currentId = int.tryParse(_ctrls['classificacaokitid']?.text.trim() ?? '');
      var query = SupabaseConfig.client.from('classificacaokit').select(select).eq('empresaid', empresaIdForScopedQueries);
      query = currentId == null ? query.eq('status', 'A') : query.or('status.eq.A,classificacaokitid.eq.$currentId');
      final rows = await query.order('nome', ascending: true).limit(500);
      if (!mounted) return;
      setState(() => _fkOptions[f.column] = List<Map<String, dynamic>>.from(rows));
      return;
    }

    // Imposto e taxas (novo) -> Empresa: não exibir empresas que já possuem cadastro.
    if (!_isEdit && _isEmpresaTaxas && f.column == 'empresaid' && fk.table == 'empresa') {
      final assoc = await SupabaseConfig.client.from('empresasetup').select('empresaid').limit(1000);
      final excluded = <int>{
        for (final row in assoc)
          if (row['empresaid'] is num) (row['empresaid'] as num).toInt(),
      };
      // Mantém a empresa já selecionada (ex.: tipo E com a empresa travada) para o combo
      // continuar válido; a duplicidade é barrada no salvamento.
      final currentEmpresaId = int.tryParse(_ctrls['empresaid']?.text.trim() ?? '');
      if (currentEmpresaId != null) excluded.remove(currentEmpresaId);

      var query = SupabaseConfig.client.from('empresa').select(select);
      if (excluded.isNotEmpty) {
        query = query.not('empresaid', 'in', '(${excluded.join(',')})');
      }
      final rows = await query.order(fk.labelColumn, ascending: true).limit(500);
      if (!mounted) return;
      setState(() => _fkOptions[f.column] = List<Map<String, dynamic>>.from(rows));
      return;
    }

    // Despesa Variável (novo) -> Item: não exibir itens já cadastrados para a empresa logada/selecionada.
    // (Pedido: no cadastro de nova despesa variável, o combo de Item não deve listar itens já usados.)
    if (!_isEdit && widget.definition.keyName == 'despesavariavel' && f.column == 'itemid' && fk.table == 'item') {
      // IMPORTANT: in most cadastros, `empresaid` is not explicitly shown/edited in the form.
      // In those cases, the controller can be empty; we must use the resolved empresaId
      // (form value if present, otherwise session.empresaId) provided by the caller.
      final empresaId = empresaIdForScopedQueries;
      if (empresaId == null) {
        debugPrint('FK options (despesavariavel.itemid): empresaId unavailable; using unfiltered item list');
        final rows = await SupabaseService.select(
          fk.table,
          select: select,
          filters: filters.isEmpty ? null : filters,
          orderBy: fk.labelColumn,
          ascending: true,
          limit: 500,
        );
        if (!mounted) return;
        setState(() => _fkOptions[f.column] = rows);
        return;
      }

      // Load existing DespesaVariavel records to exclude their itemid from the Item combo.
      final assoc = await SupabaseConfig.client
          .from('despesavariavel')
          .select('itemid')
          .eq('empresaid', empresaId)
          .limit(1000);

      final excluded = <int>{};
      for (final row in assoc) {
        final id = row['itemid'];
        if (id is int) excluded.add(id);
        if (id is num) excluded.add(id.toInt());
      }

      // Keep currently selected item available (defensive; should be empty in create mode).
      final currentRaw = _ctrls['itemid']?.text.trim() ?? '';
      final currentItemId = int.tryParse(currentRaw);
      if (currentItemId != null) excluded.remove(currentItemId);

      var query = SupabaseConfig.client.from('item').select(select);
      // Apply the same scoped filters (empresaid/tipoitemid/etc) via query.
      if (filters.isNotEmpty) {
        for (final entry in filters.entries) {
          query = query.eq(entry.key, entry.value);
        }
      }
      if (excluded.isNotEmpty) {
        final idsCsv = excluded.join(',');
        // Exclude items already used by despesavariavel for this empresa.
        // NOTE: `filter('col', 'not.in', ...)` is not reliably supported across versions.
        query = query.not('itemid', 'in', '($idsCsv)');
      }

      debugPrint(
        'FK options (despesavariavel.itemid): empresaId=$empresaId excluded=${excluded.length} filters=$filters',
      );

      final rows = await query.order('nome', ascending: true).limit(500);
      if (!mounted) return;
      setState(() => _fkOptions[f.column] = List<Map<String, dynamic>>.from(rows));

      // If the currently selected item became unavailable (e.g. switched empresa), clear it.
      final stillValid = currentItemId == null || rows.any((r) => (r['itemid'] is num) && (r['itemid'] as num).toInt() == currentItemId);
      if (!stillValid) {
        _ctrls['itemid']?.clear();
      }
      return;
    }

    final rows = await SupabaseService.select(
      fk.table,
      select: select,
      filters: filters.isEmpty ? null : filters,
      orderBy: fk.labelColumn,
      ascending: true,
      limit: 500,
    );

    if (!mounted) return;
    setState(() => _fkOptions[f.column] = rows);
  }

  bool _isStatusField(CadastroField f) => f.column.toLowerCase() == 'status';

  bool _isSenhaField(CadastroField f) {
    final c = f.column.toLowerCase();
    return c == 'senha' || c == 'password';
  }

  bool _isTipoUsuarioField(CadastroField f) {
    final c = f.column.toLowerCase();
    return c == 'tipousuario' || c == 'tipo_usuario';
  }

  bool _isTipoPessoaField(CadastroField f) {
    // Both Empresa and Fornecedor share the same business rule and helper label:
    // Juridica => CNPJ, Fisica => CPF.
    if (!_isEmpresa && !_isFornecedor) return false;
    final c = f.column.toLowerCase();
    return c == 'tipodocumento' || c == 'tipo_documento';
  }

  bool _isOptionField(CadastroField f) => f.type == CadastroFieldType.option && (f.options?.isNotEmpty ?? false);

  /// Item: rótulo da unidade de compra selecionada (ex.: "kg"), para o label da qtde.
  String? _itemCompraUnidadeLabel() => _itemUnidadeLabel('compraunidadeid');

  /// Item: rótulo da unidade selecionada em [column] (`unidadeid` ou `compraunidadeid`).
  String? _itemUnidadeLabel(String column) {
    if (!_isItem) return null;
    final id = num.tryParse(_ctrls[column]?.text.trim() ?? '');
    if (id == null) return null;
    for (final r in _fkOptions[column] ?? const <Map<String, dynamic>>[]) {
      final rid = r['unidadeid'];
      if (rid is num && rid == id) {
        final label = r['unidade']?.toString().trim();
        return (label == null || label.isEmpty) ? null : label;
      }
    }
    return null;
  }

  /// Item: custo unitário = valor da compra / (qtde comprada × fator de conversão),
  /// arredondado a 4 casas. Retorna null se qtde ou fator não forem > 0.
  double? _computeItemCustoUnitario() {
    final qtde = _parsePtBrNumber(_ctrls['qtdecomprada']?.text.trim() ?? '');
    final fator = _parsePtBrNumber(_ctrls['fatorconversao']?.text.trim() ?? '');
    final valor = _parsePtBrNumber(_ctrls['valorcompra']?.text.trim() ?? '') ?? 0;
    if (qtde == null || qtde <= 0 || fator == null || fator <= 0) return null;
    final custo = valor / (qtde * fator);
    return (custo * 10000).roundToDouble() / 10000;
  }

  void _recomputeItemCustoUnitario() {
    final ctrl = _ctrls['custounitario'];
    if (!_isItem || ctrl == null) return;
    final custo = _computeItemCustoUnitario();
    final formatted = custo == null ? '' : _formatPtBrThousands(custo, 4);
    if (ctrl.text != formatted) ctrl.text = formatted;
    // Atualiza o card "Qtde comprada (unidade no item)" ao lado da qtde.
    if (mounted) setState(() {});
  }

  static const _itemEmbalagemColumns = ['qtdembalagem', 'qtditemporembalagem'];

  /// Item: qtde comprada = qtde de embalagem × qtde de itens por embalagem.
  /// Null enquanto algum dos dois não for inteiro > 0.
  int? _computeItemQtdeComprada() {
    final emb = int.tryParse(_ctrls['qtdembalagem']?.text.trim() ?? '');
    final porEmb = int.tryParse(_ctrls['qtditemporembalagem']?.text.trim() ?? '');
    if (emb == null || emb <= 0 || porEmb == null || porEmb <= 0) return null;
    return emb * porEmb;
  }

  /// Atualiza o campo (bloqueado) Qtde comprada; o listener dele recalcula o custo.
  void _recomputeItemQtdeComprada() {
    final ctrl = _ctrls['qtdecomprada'];
    if (!_isItem || ctrl == null) return;
    final qtde = _computeItemQtdeComprada();
    final formatted = qtde == null ? '' : _formatPtBrThousands(qtde, 2);
    if (ctrl.text != formatted) ctrl.text = formatted;
  }

  /// Item: qtde comprada convertida para a unidade do item (qtde × fator).
  /// Null enquanto qtde ou fator não forem > 0.
  double? _computeItemQtdeConvertida() {
    final qtde = _parsePtBrNumber(_ctrls['qtdecomprada']?.text.trim() ?? '');
    final fator = _parsePtBrNumber(_ctrls['fatorconversao']?.text.trim() ?? '');
    if (qtde == null || qtde <= 0 || fator == null || fator <= 0) return null;
    return (qtde * fator).toDouble();
  }

  /// pt-BR com milhar e 2 a 4 casas (remove zeros finais além da 2ª casa).
  String _formatPtBrQtde(num value) {
    var s = _formatPtBrThousands(value, 4);
    while (s.endsWith('0') && s.length - s.lastIndexOf(',') - 1 > 2) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Linha do Valor da compra: campo + card ameixa do custo unitário ao lado,
  /// para ver o custo sem rolar o formulário.
  Widget _buildItemValorCompraRow(BuildContext context, CadastroField f) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Campo sempre como 1º filho, para não perder o foco ao reconstruir.
        Expanded(child: _buildField(context, f)),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: _buildItemCustoUnitarioCard(context)),
      ],
    );
  }

  /// Item: custo unitário calculado, exibido como card ameixa (não editável).
  /// O valor continua no controller `custounitario` e é recalculado no save.
  Widget _buildItemCustoUnitarioCard(BuildContext context) {
    final t = Theme.of(context).textTheme;
    const fg = AppStatusColors.onCalculatedValue;
    final unidade = _itemUnidadeLabel('unidadeid');
    final label = unidade == null ? 'Custo unitário (R\$)' : 'Custo unitário (R\$/$unidade)';
    // Sem dados de compra (ex.: item antigo na edição), mostra o custo gravado
    // que está no controller até o usuário mexer em qtde/fator/valor.
    final custo = _computeItemCustoUnitario() ?? _parsePtBrNumber(_ctrls['custounitario']?.text ?? '');

    // Compacto: divide a linha com o campo Valor da compra.
    // Total calculado (valor ÷ (qtde × fator)): ameixa com borda dourado-mel.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppStatusColors.calculatedValueBackground,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppStatusColors.totalCalculadoBorder, width: AppStatusColors.totalCalculadoBorderWidth),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: t.labelSmall?.copyWith(color: fg.withValues(alpha: 0.85)),
              ),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  custo == null ? '—' : _formatPtBrCurrencyThousands(custo, 4),
                  style: t.titleLarge?.copyWith(color: fg, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Linha da Qtde comprada: campo + card com a qtde na unidade do item (após informar o fator).
  Widget _buildItemQtdeCompradaRow(BuildContext context, CadastroField f) {
    final field = _buildField(context, f);
    final convertida = _computeItemQtdeConvertida();
    // Sempre um Row com o campo como 1º filho: trocar a estrutura faria o
    // TextField perder o foco enquanto o usuário digita.
    if (convertida == null) return Row(children: [Expanded(child: field)]);

    final t = Theme.of(context).textTheme;
    // Valor calculado (qtde × fator): card ameixa padrão, texto branco.
    const fg = AppStatusColors.onCalculatedValue;
    final unidade = _itemUnidadeLabel('unidadeid');
    final label = unidade == null ? 'Qtde comprada' : 'Qtde comprada ($unidade)';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: field),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppStatusColors.calculatedValueBackground,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              child: Column(
                // Rótulo e valor centralizados (mesmo padrão do card Custo unitário).
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, textAlign: TextAlign.center, style: t.labelSmall?.copyWith(color: fg.withValues(alpha: 0.85)), overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(_formatPtBrQtde(convertida), textAlign: TextAlign.center, style: t.bodyLarge?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String? _produtoReceitaSelectedUnidade() {
    if (widget.definition.keyName != 'produtoreceita') return null;
    final rawId = _ctrls['receitaid']?.text.trim();
    if (rawId == null || rawId.isEmpty) return null;
    final id = num.tryParse(rawId);
    if (id == null) return null;

    final options = _fkOptions['receitaid'];
    if (options == null || options.isEmpty) return null;

    Map<String, dynamic>? row;
    for (final r in options) {
      final rid = r['receitaid'];
      if (rid is num && rid == id) {
        row = r;
        break;
      }
    }
    final unidade = (row?['unidade'] as Map?)?['unidade']?.toString();
    final trimmed = unidade?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  Widget _buildOptionField(BuildContext context, CadastroField f) {
    // Keep the specialized behavior for Empresa/Tipo de Pessoa.
    if (_isTipoPessoaField(f)) return _buildTipoPessoaField(context, f);

    final cs = Theme.of(context).colorScheme;
    final readOnly = widget.readOnlyColumns.contains(f.column);
    final raw = _ctrls[f.column]!.text.trim();
    final options = f.options ?? const [];
    final isValid = options.any((o) => o.value == raw);
    final value = isValid ? raw : null;

    return DropdownButtonFormField<String>(
             // Menu de opções delimitado (fundo de card + cantos arredondados).
             dropdownColor: AppDropdownStyle.menuColor(context),
             borderRadius: AppDropdownStyle.menuRadius,
             style: AppDropdownStyle.menuTextStyle(context),
      autofocus: _autoFocusFor(f),
      value: value,
      isExpanded: true,
      icon: Icon(Icons.keyboard_arrow_down_rounded, color: cs.onSurfaceVariant),
      hint: const Text('Selecione...'),
      items: options
          .map((o) => DropdownMenuItem<String>(value: o.value, child: Text(o.label, overflow: TextOverflow.ellipsis)))
          .toList(growable: false),
      onChanged: readOnly
          ? null
          : (v) {
              _clearErrorOnUserInteraction();
              _ctrls[f.column]!.text = v ?? '';
              setState(() {});
            },
      decoration: InputDecoration(
        labelText: f.required ? '${f.label} *' : f.label,
        prefixIcon: Icon(Icons.list_alt_rounded, color: cs.onSurfaceVariant),
        suffixIcon: readOnly ? const Icon(Icons.lock_rounded) : null,
      ),
    );
  }

  Widget _buildTipoPessoaField(BuildContext context, CadastroField f) {
    final cs = Theme.of(context).colorScheme;
    final readOnly = widget.readOnlyColumns.contains(f.column);

    final raw = _ctrls[f.column]!.text.trim().toUpperCase();
    String? value;
    if (raw == 'J' || raw == 'F') value = raw;

    return DropdownButtonFormField<String>(
             // Menu de opções delimitado (fundo de card + cantos arredondados).
             dropdownColor: AppDropdownStyle.menuColor(context),
             borderRadius: AppDropdownStyle.menuRadius,
             style: AppDropdownStyle.menuTextStyle(context),
      autofocus: _autoFocusFor(f),
      value: value,
      isExpanded: true,
      icon: Icon(Icons.keyboard_arrow_down_rounded, color: cs.onSurfaceVariant),
      hint: const Text('Selecione...'),
      items: const [
        DropdownMenuItem(value: 'J', child: Text('Jurídica')),
        DropdownMenuItem(value: 'F', child: Text('Física')),
      ],
      onChanged: readOnly
          ? null
          : (v) {
              _clearErrorOnUserInteraction();
              final next = (v ?? '').toUpperCase();
              _ctrls[f.column]!.text = next;

              // Limpa o documento não aplicável para evitar salvar ambos.
              if (next == 'J') {
                _ctrls['cpf']?.clear();
              } else if (next == 'F') {
                _ctrls['cnpj']?.clear();
              }

              setState(() {});
            },
      decoration: InputDecoration(
        labelText: f.required ? '${f.label} *' : f.label,
        prefixIcon: Icon(Icons.person_rounded, color: cs.onSurfaceVariant),
        helperText: 'Jurídica = CNPJ | Física = CPF',
        suffixIcon: readOnly ? const Icon(Icons.lock_rounded) : null,
      ),
    );
  }

  bool _empresaFieldEnabled(String column) {
    if (!_isEmpresa) return true;
    final tipo = _empresaTipoDocumento;
    if (tipo == null) {
      // Sem tipo selecionado: deixa os documentos desabilitados para guiar o fluxo.
      return column != 'cnpj' && column != 'cpf';
    }
    if (column == 'cnpj') return tipo == 'J';
    if (column == 'cpf') return tipo == 'F';
    return true;
  }

  bool _fornecedorFieldEnabled(String column) {
    if (widget.definition.keyName != 'fornecedor') return false;
    final tipo = _fornecedorTipoDocumento;
    if (tipo == null) return true;
    if (tipo == 'J') {
      if (column == 'cnpj') return true;
      if (column == 'cpf') return false;
    }
    if (tipo == 'F') {
      if (column == 'cpf') return true;
      if (column == 'cnpj') return false;
    }
    return true;
  }

  Widget _buildTipoUsuarioField(BuildContext context, CadastroField f) {
    final cs = Theme.of(context).colorScheme;
    final readOnly = widget.readOnlyColumns.contains(f.column);

    final raw = _ctrls[f.column]!.text.trim().toUpperCase();
    String? value;
    if (raw == 'A' || raw == 'E' || raw == 'U') value = raw;

    return DropdownButtonFormField<String>(
             // Menu de opções delimitado (fundo de card + cantos arredondados).
             dropdownColor: AppDropdownStyle.menuColor(context),
             borderRadius: AppDropdownStyle.menuRadius,
             style: AppDropdownStyle.menuTextStyle(context),
      autofocus: _autoFocusFor(f),
      value: value,
      items: const [
        DropdownMenuItem(value: 'A', child: Text('Administrador')),
        DropdownMenuItem(value: 'E', child: Text('Administrador da Empresa')),
        DropdownMenuItem(value: 'U', child: Text('Usuário')),
      ],
      onChanged: readOnly
          ? null
          : (v) {
              _clearErrorOnUserInteraction();
              _ctrls[f.column]!.text = v ?? '';
              setState(() {});
            },
      decoration: InputDecoration(
        labelText: f.required ? '${f.label} *' : f.label,
        prefixIcon: Icon(Icons.admin_panel_settings_rounded, color: cs.onSurfaceVariant),
        suffixIcon: readOnly ? const Icon(Icons.lock_rounded) : null,
      ),
    );
  }

  Widget _buildStatusField(BuildContext context, CadastroField f) {
    final cs = Theme.of(context).colorScheme;
    final readOnly = widget.readOnlyColumns.contains(f.column);

    final raw = _ctrls[f.column]!.text.trim().toUpperCase();
    String? value;
    if (raw == 'A' || raw == 'I') value = raw;

    return DropdownButtonFormField<String>(
             // Menu de opções delimitado (fundo de card + cantos arredondados).
             dropdownColor: AppDropdownStyle.menuColor(context),
             borderRadius: AppDropdownStyle.menuRadius,
             style: AppDropdownStyle.menuTextStyle(context),
      autofocus: _autoFocusFor(f),
      value: value,
      items: const [
        DropdownMenuItem(value: 'A', child: Text('Ativo')),
        DropdownMenuItem(value: 'I', child: Text('Inativo')),
      ],
      onChanged: readOnly
          ? null
          : (v) {
              _clearErrorOnUserInteraction();
              _ctrls[f.column]!.text = v ?? '';
              setState(() {});
            },
      decoration: InputDecoration(
        labelText: f.required ? '${f.label} *' : f.label,
        prefixIcon: Icon(Icons.toggle_on_rounded, color: cs.onSurfaceVariant),
        suffixIcon: readOnly ? const Icon(Icons.lock_rounded) : null,
      ),
    );
  }

  Widget _buildForeignKeyField(BuildContext context, CadastroField f) {
    final cs = Theme.of(context).colorScheme;
    final fk = f.fk!;
    // Watch here so the form reacts if the profile loads after opening the sheet.
    final session = context.watch<AppSessionController>();
    // No cadastro de usuário, somente Admin geral (A) escolhe empresa.
    final lockedEmpresaId = _isUsuario && f.column == 'empresaid' && !session.isSuperAdmin;
    // EmpresaDelivery: usuário tipo E deve manter sempre a empresa logada.
    final lockedEmpresaDeliveryEmpresa = widget.definition.keyName == 'empresadelivery' && f.column == 'empresaid' && !session.isSuperAdmin;
    // EmpresaDelivery: when editing, the association (empresa/delivery) must not change.
    // Only taxa/status are allowed to be edited.
    final lockedEmpresaDeliveryFk =
        _isEdit && widget.definition.keyName == 'empresadelivery' && (f.column == 'empresaid' || f.column == 'deliveryid');

    // Imposto e taxas: tipo E fica com a empresa logada; na edição a empresa não pode mudar
    // (somente imposto, taxaadm e taxamotoboy são editáveis).
    final lockedEmpresaTaxasEmpresa = _isEmpresaTaxas && f.column == 'empresaid' && (_isEdit || !session.isSuperAdmin);

    final readOnly = widget.readOnlyColumns.contains(f.column) ||
        lockedEmpresaId ||
        lockedEmpresaDeliveryEmpresa ||
        lockedEmpresaDeliveryFk ||
        lockedEmpresaTaxasEmpresa;

    final options = _fkOptions[f.column] ?? const <Map<String, dynamic>>[];
    final isLoading = _fkLoading.contains(f.column);

    final showNoAvailableItemsHint =
        !_isEdit && _isDespesaVariavel && f.column == 'itemid' && !isLoading && options.isEmpty;

    num? value;
    final raw = _ctrls[f.column]!.text.trim();
    if (raw.isNotEmpty) {
      value = num.tryParse(raw);
    }

    return DropdownButtonFormField<num>(
             // Menu de opções delimitado (fundo de card + cantos arredondados).
             dropdownColor: AppDropdownStyle.menuColor(context),
             borderRadius: AppDropdownStyle.menuRadius,
             style: AppDropdownStyle.menuTextStyle(context),
      autofocus: _autoFocusFor(f),
      value: value,
      hint: Text(showNoAvailableItemsHint ? 'Nenhum item disponível' : 'Selecione...'),
      items: options
          .map((row) {
            final id = row[fk.idColumn];
            if (id is! num) return null;
            final label = (row[fk.labelColumn] ?? id).toString();
            return DropdownMenuItem<num>(value: id, child: Text(label, overflow: TextOverflow.ellipsis));
          })
          .whereType<DropdownMenuItem<num>>()
          .toList(growable: false),
      onChanged: (isLoading || readOnly || showNoAvailableItemsHint)
          ? null
          : (v) {
              _clearErrorOnUserInteraction();
              _ctrls[f.column]!.text = v?.toString() ?? '';

              if (_isDespesaVariavel && f.column == 'itemid') {
                final nextId = (v is num) ? v.toInt() : null;
                if (nextId != null) {
                  _loadDespesaVariavelItemDetails(nextId);
                } else {
                  setState(() {
                    _dvItemRow = null;
                    _dvMarcaNome = null;
                    _dvUnidadeLabel = null;
                  });
                }
              }
              setState(() {});
            },
      decoration: InputDecoration(
        labelText: f.required ? '${f.label} *' : f.label,
        prefixIcon: isLoading
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary)),
              )
            : Icon(Icons.arrow_drop_down_circle_rounded, color: cs.onSurfaceVariant),
        helperText: showNoAvailableItemsHint
            ? 'Todos os itens já foram cadastrados como despesa variável para ${session.empresaLabel}.'
            : null,
        suffixIcon: readOnly ? const Icon(Icons.lock_rounded) : null,
      ),
    );
  }

  /// Limite de caracteres do campo de texto: o da definição ou o tamanho da
  /// coluna varchar no banco. Campos com máscara (CPF, CNPJ etc.) e números já
  /// têm o tamanho controlado pelo formatter e ficam sem contador.
  int? _textMaxLength(CadastroField f, {required bool hasMask}) {
    if (f.maxLength != null) return f.maxLength;
    if (f.type != CadastroFieldType.text || hasMask) return null;
    return dbColumnMaxLength(widget.definition.table, f.column) ??
        // Observação sem tamanho no banco: mantém o limite de 500.
        (f.column.toLowerCase() == 'obs' ? 500 : null);
  }

  Widget _buildDefaultField(BuildContext context, CadastroField f) {
    final enabled = (!_isEmpresa || _empresaFieldEnabled(f.column)) && (!_isFornecedor || _fornecedorFieldEnabled(f.column));
    final isCalculatedDespesaVariavelValorMensal = _isDespesaVariavel && f.column == 'valormensal';
    // Item: custo unitário = valor da compra / (qtde comprada × fator de conversão).
    final isCalculatedItemCustoUnitario = _isItem && f.column == 'custounitario';
    // Item: qtde comprada = qtde de embalagem × qtde de itens por embalagem.
    final isCalculatedItemQtdeComprada = _isItem && f.column == 'qtdecomprada';
    final readOnly = widget.readOnlyColumns.contains(f.column) ||
        !enabled ||
        isCalculatedDespesaVariavelValorMensal ||
        isCalculatedItemCustoUnitario ||
        isCalculatedItemQtdeComprada;

    final isSenha = _isSenhaField(f);
    final obscure = isSenha ? (_obscureByColumn[f.column] ?? true) : false;

    final isEmail = f.column.toLowerCase() == 'email';

     List<TextInputFormatter>? inputFormatters;
     TextInputType keyboardType = TextInputType.text;

     if ((_isEmpresa || _isFornecedor) && f.column == 'cnpj') {
       keyboardType = const TextInputType.numberWithOptions(decimal: false, signed: false);
       inputFormatters = const [_CnpjFormatter()];
     }

     if ((_isEmpresa || _isFornecedor) && f.column == 'cpf') {
       keyboardType = const TextInputType.numberWithOptions(decimal: false, signed: false);
       inputFormatters = const [_CpfFormatter()];
     }

       // Compra: prefer calendar picker to avoid typing issues.
       if (_isCompra && f.column == 'datacompra') {
         return _buildCompraDateField(context, f);
       }

        // CompraItem: keep the exact same behavior as Compra date (calendar picker).
        if (_isCompraItem && f.column == 'datavalidade') {
          return _buildCompraItemDateField(context, f);
        }

      if (isEmail) {
        keyboardType = TextInputType.emailAddress;
      } else if (f.type == CadastroFieldType.number) {
        keyboardType = const TextInputType.numberWithOptions(decimal: true, signed: false);

        if (widget.definition.table == 'categoria' && f.column == 'percentualrateiodespesa') {
          // Mask: 0,00 .. 999,99 (pt-BR). Limite >100 é validado no _save().
          inputFormatters = const [
            _PtBrDecimalFormatter(maxIntDigits: 3, decimalDigits: 2, useThousandsSeparator: false),
          ];
        } else
         if (widget.definition.keyName == 'receita' && f.column == 'qtdreceita') {
           keyboardType = const TextInputType.numberWithOptions(decimal: false, signed: false);
           // Limit to 5 digits (max 99999)
           inputFormatters = [
             _DigitsOnlyMaxLengthFormatter(5),
           ];
         } else
          if (widget.definition.keyName == 'material' && f.column == 'quantidade') {
            keyboardType = const TextInputType.numberWithOptions(decimal: false, signed: false);
            // Limit to 5 digits (max 99999)
            inputFormatters = [
              _DigitsOnlyMaxLengthFormatter(5),
            ];
          } else
          if (widget.definition.keyName == 'ingrediente' && f.column == 'quantidadegrama') {
            // Mask: up to 99999,9999 (pt-BR)
            inputFormatters = const [
              _PtBrDecimalFormatter(maxIntDigits: 5, decimalDigits: 4, useThousandsSeparator: false),
            ];
           } else if (widget.definition.keyName == 'produtoreceita' && f.column == 'quantidadereceita') {
             // Mask: up to 99999,99 (pt-BR)
             inputFormatters = const [
               _PtBrDecimalFormatter(maxIntDigits: 5, decimalDigits: 2, useThousandsSeparator: false),
             ];
          } else if ((widget.definition.keyName == 'kitproduto' || widget.definition.keyName == 'kitembalagem') && f.column == 'quantidade') {
            keyboardType = const TextInputType.numberWithOptions(decimal: false, signed: false);
            // Limit to 5 digits (max 99999)
            inputFormatters = [
              _DigitsOnlyMaxLengthFormatter(5),
            ];
          } else
           if (_isCompra && f.column == 'valorcompra') {
             inputFormatters = const [_PtBrDecimalFormatter(maxIntDigits: 5, decimalDigits: 2, useThousandsSeparator: true)];
           } else if (_isCompraItem && (f.column == 'quantidade' || f.column == 'valorunitario')) {
             inputFormatters = const [_PtBrDecimalFormatter(maxIntDigits: 5, decimalDigits: 2, useThousandsSeparator: true)];
          } else if (_isEmpresaTaxas && _empresaTaxasValueColumns.contains(f.column)) {
            // Mask: up to 9.999,99 (pt-BR) -> numeric(6,2)
            inputFormatters = const [_PtBrDecimalFormatter(maxIntDigits: 4, decimalDigits: 2, useThousandsSeparator: true)];
          } else if (widget.definition.keyName == 'empresadelivery' && f.column == 'taxadelivery') {
            // Mask: up to 9.999,99 (pt-BR) -> numeric(6,2)
            inputFormatters = const [_PtBrDecimalFormatter(maxIntDigits: 4, decimalDigits: 2, useThousandsSeparator: true)];
        } else if (_isItem && f.column == 'custounitario') {
          // Mask: up to 9.999.999,9999 (pt-BR)
          inputFormatters = const [
            _PtBrDecimalFormatter(maxIntDigits: 7, decimalDigits: 4, useThousandsSeparator: true),
          ];
        } else if (_isItem && _itemEmbalagemColumns.contains(f.column)) {
          // Inteiros (integer no banco); até 5 dígitos (máx. 99999).
          keyboardType = const TextInputType.numberWithOptions(decimal: false, signed: false);
          inputFormatters = [_DigitsOnlyMaxLengthFormatter(5)];
        } else if (_isItem && f.column == 'qtdecomprada') {
          // Mask: até 99.999.999,99 (pt-BR) -> numeric(10,2)
          inputFormatters = const [
            _PtBrDecimalFormatter(maxIntDigits: 8, decimalDigits: 2, useThousandsSeparator: true),
          ];
        } else if (_isItem && f.column == 'fatorconversao') {
          // Mask: até 9.999.999,9999 (pt-BR) -> numeric(11,4)
          inputFormatters = const [
            _PtBrDecimalFormatter(maxIntDigits: 7, decimalDigits: 4, useThousandsSeparator: true),
          ];
        } else if (_isItem && f.column == 'valorcompra') {
          // Mask: até 9.999.999.999,99 (pt-BR) -> numeric(12,2)
          inputFormatters = const [
            _PtBrDecimalFormatter(maxIntDigits: 10, decimalDigits: 2, useThousandsSeparator: true),
          ];
		 } else if (_isRateioDespesa && (f.column == 'valormensal' || f.column == 'totaldespesafixa')) {
		   // Mask: 0,00 (monetário)
		   inputFormatters = const [_PtBrCentsFormatter(maxIntDigits: 7)];
         } else
        if (_isProduto && (f.column == 'qtdestoqueinicial' || f.column == 'qtdproduzida' || f.column == 'estoqueminimo')) {
         keyboardType = const TextInputType.numberWithOptions(decimal: false, signed: false);
         inputFormatters = [
            // Limit to 5 digits (max 99999)
            _DigitsOnlyMaxLengthFormatter(5),
         ];
       } else if (_isProduto && f.column == 'valorvenda') {
         inputFormatters = const [
            // Mask: up to 99999,99 (pt-BR)
            _PtBrDecimalFormatter(maxIntDigits: 5, decimalDigits: 2, useThousandsSeparator: false),
         ];
       }
     }

    final cs = Theme.of(context).colorScheme;

    Widget? suffix;
    if (isCalculatedDespesaVariavelValorMensal) {
      suffix = IconButton(
        tooltip: 'Recalcular (consumo × custo unitário)',
        onPressed: () {
          _dvValorMensalManualOverride = false;
          _recomputeDespesaVariavelValorMensal();
          if (mounted) setState(() {});
        },
        style: IconButton.styleFrom(splashFactory: NoSplash.splashFactory),
        icon: Icon(Icons.calculate_rounded, color: cs.primary),
      );
    } else if (readOnly) {
      suffix = const Icon(Icons.lock_rounded);
    } else if (isSenha) {
      suffix = IconButton(
        onPressed: () => setState(() => _obscureByColumn[f.column] = !obscure),
        style: IconButton.styleFrom(splashFactory: NoSplash.splashFactory),
        tooltip: obscure ? 'Mostrar senha' : 'Ocultar senha',
        icon: Icon(obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded),
      );
    }

    // Descrição: começa com 3 linhas e cresce até 6 (depois rola). Enter cria nova linha.
    final multiline = _isMultilineField(f) && !isSenha;

    return TextField(
      controller: _ctrls[f.column],
      focusNode: (_isDespesaVariavel && f.column == 'valormensal') ? _dvValorMensalFocusNode : null,
      autofocus: _autoFocusFor(f),
      readOnly: readOnly,
      obscureText: isSenha ? obscure : false,
      minLines: multiline ? 3 : null,
      maxLines: multiline ? 6 : 1,
      // Observação: coluna varchar(500) no banco; o contador mostra o limite.
      maxLength: _textMaxLength(f, hasMask: inputFormatters != null),
      textInputAction: multiline ? TextInputAction.newline : null,
      keyboardType: multiline ? TextInputType.multiline : keyboardType,
      textCapitalization: isEmail ? TextCapitalization.none : TextCapitalization.sentences,
      autocorrect: !isEmail,
      enableSuggestions: !isEmail,
      inputFormatters: inputFormatters,
      onTap: _clearErrorOnUserInteraction,
      onChanged: (_) => _clearErrorOnUserInteraction(),
      decoration: InputDecoration(
        labelText: (_isEmpresa && (f.column == 'cnpj' || f.column == 'cpf'))
            ? _empresaDocumentoLabel(f)
            : (_isFornecedor && (f.column == 'cnpj' || f.column == 'cpf'))
                ? _fornecedorDocumentoLabel(f)
                : (widget.definition.keyName == 'produtoreceita' && f.column == 'quantidadereceita')
                    ? () {
                        final unidade = _produtoReceitaSelectedUnidade();
                        final base = unidade == null ? f.label : '${f.label} ($unidade)';
                        return f.required ? '$base *' : base;
                      }()
                    : (_isDespesaVariavel && f.column == 'consumomensal')
                        ? () {
                            // Unidade do item selecionado (ex.: "Consumo mensal (gr)").
                            final unidade = _dvUnidadeLabel;
                            final base = unidade == null ? f.label : '${f.label} ($unidade)';
                            return f.required ? '$base *' : base;
                          }()
                    : (_isItem && f.column == 'qtdecomprada')
                        ? () {
                            final unidade = _itemCompraUnidadeLabel();
                            final base = unidade == null ? f.label : '${f.label} ($unidade)';
                            return f.required ? '$base *' : base;
                          }()
                        : (_isItem && f.column == 'fatorconversao')
                            ? () {
                                // "Fator de conversão de <unidade de compra> -> <unidade no item>"
                                final unidade = _itemUnidadeLabel('unidadeid') ?? '?';
                                final compra = _itemCompraUnidadeLabel() ?? '?';
                                final base = '${f.label} de $compra -> $unidade';
                                return f.required ? '$base *' : base;
                              }()
                            : (_isItem && f.column == 'custounitario')
                                ? () {
                                    final unidade = _itemUnidadeLabel('unidadeid');
                                    return unidade == null ? '${f.label} (R\$)' : '${f.label} (R\$/$unidade)';
                                  }()
                                : (f.required ? '${f.label} *' : f.label),
        suffixIcon: suffix,
      ),
    );
  }

  Widget _buildCompraDateField(BuildContext context, CadastroField f) {
    final cs = Theme.of(context).colorScheme;
    final ctrl = _ctrls[f.column]!;
    final readOnly = widget.readOnlyColumns.contains(f.column);

    DateTime initialDate;
    final parsed = _parseBrDate(ctrl.text);
    if (parsed != null) {
      initialDate = parsed;
    } else {
      initialDate = DateTime.now();
    }

    Future<void> pick() async {
      if (readOnly) return;
      _clearErrorOnUserInteraction();
      final now = DateTime.now();
      final picked = await showDatePicker(
        context: context,
        initialDate: initialDate,
        firstDate: DateTime(2000, 1, 1),
        lastDate: DateTime(now.year + 20, 12, 31),
        helpText: 'Selecione a data da compra',
      );
      if (picked == null) return;
      final dd = picked.day.toString().padLeft(2, '0');
      final mm = picked.month.toString().padLeft(2, '0');
      final yyyy = picked.year.toString().padLeft(4, '0');
      ctrl.text = '$dd/$mm/$yyyy';
      if (mounted) setState(() {});
    }

    return TextField(
      controller: ctrl,
      readOnly: true,
      onTap: pick,
      decoration: InputDecoration(
        labelText: f.required ? '${f.label} *' : f.label,
        prefixIcon: Icon(Icons.event_rounded, color: cs.onSurfaceVariant),
        suffixIcon: IconButton(
          tooltip: 'Selecionar data',
          onPressed: readOnly ? null : pick,
          icon: Icon(Icons.calendar_month_rounded, color: readOnly ? cs.onSurfaceVariant.withValues(alpha: 0.5) : cs.primary),
        ),
      ),
    );
  }

  Widget _buildCompraItemDateField(BuildContext context, CadastroField f) {
    final cs = Theme.of(context).colorScheme;
    final ctrl = _ctrls[f.column]!;
    final readOnly = widget.readOnlyColumns.contains(f.column);

    DateTime initialDate;
    final parsed = _parseBrDate(ctrl.text);
    if (parsed != null) {
      initialDate = parsed;
    } else {
      initialDate = DateTime.now();
    }

    Future<void> pick() async {
      if (readOnly) return;
      _clearErrorOnUserInteraction();
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
      ctrl.text = '$dd/$mm/$yyyy';
      if (mounted) setState(() {});
    }

    return TextField(
      controller: ctrl,
      readOnly: true,
      onTap: pick,
      decoration: InputDecoration(
        labelText: f.required ? '${f.label} *' : f.label,
        prefixIcon: Icon(Icons.event_rounded, color: cs.onSurfaceVariant),
        suffixIcon: IconButton(
          tooltip: 'Selecionar data',
          onPressed: readOnly ? null : pick,
          icon: Icon(Icons.calendar_month_rounded, color: readOnly ? cs.onSurfaceVariant.withValues(alpha: 0.5) : cs.primary),
        ),
      ),
    );
  }

  String _empresaDocumentoLabel(CadastroField f) {
    final tipo = _empresaTipoDocumento;
    final requiredNow = (tipo == 'J' && f.column == 'cnpj') || (tipo == 'F' && f.column == 'cpf');
    return requiredNow ? '${f.label} *' : f.label;
  }

  String _fornecedorDocumentoLabel(CadastroField f) {
    final tipo = _fornecedorTipoDocumento;
    final requiredNow = (tipo == 'J' && f.column == 'cnpj') || (tipo == 'F' && f.column == 'cpf');
    return requiredNow ? '${f.label} *' : f.label;
  }

  Widget _buildEmpresaDddField(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final readOnly = widget.readOnlyColumns.contains('dddcelular');
    return TextField(
      controller: _ctrls['dddcelular'],
      readOnly: readOnly,
      keyboardType: TextInputType.phone,
      onTap: _clearErrorOnUserInteraction,
      onChanged: (_) => _clearErrorOnUserInteraction(),
      inputFormatters: [
        _DigitsOnlyMaxLengthFormatter(2),
      ],
      decoration: InputDecoration(
        labelText: 'DDD',
        hintText: '11',
        prefixText: '(',
        suffixText: ')',
        prefixIcon: Icon(Icons.phone_iphone_rounded, color: cs.onSurfaceVariant),
        suffixIcon: readOnly ? const Icon(Icons.lock_rounded) : null,
      ),
    );
  }

  Widget _buildEmpresaCelularNumeroField(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final readOnly = widget.readOnlyColumns.contains('celular');
    return TextField(
      controller: _ctrls['celular'],
      readOnly: readOnly,
      keyboardType: TextInputType.phone,
      onTap: _clearErrorOnUserInteraction,
      onChanged: (_) => _clearErrorOnUserInteraction(),
      inputFormatters: const [
        _BrPhoneNumberFormatter(),
      ],
      decoration: InputDecoration(
        labelText: 'Número',
        hintText: '99999-9999',
        suffixIcon: readOnly ? const Icon(Icons.lock_rounded) : null,
      ),
    );
  }

  Widget _buildAuditDateTimeField(BuildContext context, CadastroField f) {
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: _ctrls[f.column],
      readOnly: true,
      decoration: InputDecoration(
        labelText: f.required ? '${f.label} *' : f.label,
        prefixIcon: Icon(Icons.schedule_rounded, color: cs.onSurfaceVariant),
        suffixIcon: const Icon(Icons.lock_rounded),
      ),
    );
  }

  Widget _buildField(BuildContext context, CadastroField f) {
    if (widget.hiddenColumns.contains(f.column)) return const SizedBox.shrink();

    if (f.column.toLowerCase() == 'dataatualizacao') {
      return _buildAuditDateTimeField(context, f);
    }

    final gatedByEmpresa = _isUsuario && f.column != 'empresaid' && !_hasUsuarioEmpresaSelected;
    final child = switch (true) {
      _ when f.fk != null => _buildForeignKeyField(context, f),
      _ when _isStatusField(f) => _buildStatusField(context, f),
      _ when _isTipoUsuarioField(f) => _buildTipoUsuarioField(context, f),
      _ when _isTipoPessoaField(f) => _buildTipoPessoaField(context, f),
      _ when _isOptionField(f) => _buildOptionField(context, f),
      _ => _buildDefaultField(context, f),
    };

    if (!gatedByEmpresa) return child;

    final cs = Theme.of(context).colorScheme;
    return AbsorbPointer(
      child: Opacity(
        opacity: 0.55,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: cs.outline.withValues(alpha: 0.12)),
          ),
          child: Padding(padding: const EdgeInsets.all(2), child: child),
        ),
      ),
    );
  }

  bool _isValidEmail(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    // Simple, practical email validation:
    // - requires exactly one "@"
    // - requires at least one dot in the domain
    // - forbids trailing dot (e.g. "gmail.")
    // - forbids spaces
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');
    if (!emailRegex.hasMatch(v)) return false;
    if (v.endsWith('.')) return false;
    return true;
  }

  bool _isEmpresaCelularPairAt(int index) {
    if (widget.definition.keyName != 'empresa') return false;
    final fields = widget.definition.fields;
    if (index < 0 || index >= fields.length - 1) return false;
    return fields[index].column == 'dddcelular' && fields[index + 1].column == 'celular';
  }

  Widget _buildEmpresaCelularRow(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Celular', style: textTheme.labelLarge),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(flex: 2, child: _buildEmpresaDddField(context)),
            const SizedBox(width: AppSpacing.md),
            Expanded(flex: 5, child: _buildEmpresaCelularNumeroField(context)),
          ],
        ),
      ],
    );
  }

  Widget _buildEmpresaLogoCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final bytes = _empresaLogoBytes;
    final hasLogo = bytes != null && bytes.isNotEmpty;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: AppSpacing.paddingMd,
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: DecoratedBox(
                decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: 0.55)),
                child: hasLogo
                    ? Image.memory(
                        bytes!,
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          debugPrint('Failed to render empresa logo preview: $error');
                          return SizedBox(
                            width: 44,
                            height: 44,
                            child: Center(child: Icon(Icons.image_not_supported_outlined, color: cs.onSurfaceVariant)),
                          );
                        },
                      )
                    : SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(child: Icon(Icons.image_outlined, color: cs.onSurfaceVariant)),
                      ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Logo da empresa', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    hasLogo ? 'Será exibido no topo no lugar do ícone do usuário.' : 'Nenhum logo carregado (mantém o ícone atual).',
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Column(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _isSaving ? null : _onPickEmpresaLogo,
                  icon: Icon(Icons.upload_rounded, color: cs.onSecondaryContainer, size: 18),
                  label: Text('Upload', style: TextStyle(color: cs.onSecondaryContainer)),
                ),
                if (hasLogo) ...[
                  const SizedBox(height: AppSpacing.xs),
                  OutlinedButton.icon(
                    onPressed: _isSaving ? null : _onRemoveEmpresaLogo,
                    icon: Icon(Icons.delete_outline_rounded, color: cs.error, size: 18),
                    label: Text('Remover', style: TextStyle(color: cs.error)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildFormChildren(BuildContext context) {
    final children = <Widget>[];

    if (_isEmpresa) {
      children.add(_buildEmpresaLogoCard(context));
      children.add(const SizedBox(height: AppSpacing.md));
    }

    int i = 0;
    while (i < widget.definition.fields.length) {
      if (_isEmpresaCelularPairAt(i)) {
        if (!widget.hiddenColumns.contains('dddcelular') && !widget.hiddenColumns.contains('celular')) {
          children.add(_buildEmpresaCelularRow(context));
          children.add(const SizedBox(height: AppSpacing.md));
        }
        i += 2;
        continue;
     }

      final f = widget.definition.fields[i];

      // UI rule: for cadastros with status, auto-load 'A' on insert and only allow changing
      // status when editing.
      final omitFromUi =
          widget.hiddenColumns.contains(f.column) ||
          // Item: o custo unitário aparece no card ao lado do Valor da compra.
          (_isItem && f.column == 'custounitario') ||
          (_isStatusField(f) && !_isEdit) ||
          // Pedido: no cadastramento de uma nova despesa fixa, não exibir a data de atualização.
          // Porém, o campo continua sendo preenchido automaticamente no save via `updatedAtColumn`.
          (_isRateioDespesa && !_isEdit && f.column.toLowerCase() == 'dataatualizacao');
      if (!omitFromUi) {
        children.add(switch (f.column) {
          'qtdecomprada' when _isItem => _buildItemQtdeCompradaRow(context, f),
          'valorcompra' when _isItem => _buildItemValorCompraRow(context, f),
          _ => _buildField(context, f),
        });

        // Despesa Variável: após selecionar o Item, exibir detalhes derivados.
        if (_isDespesaVariavel && f.column == 'itemid') {
          children.add(const SizedBox(height: AppSpacing.sm));
          children.add(DespesaVariavelItemDetailsCard(
            itemRow: _dvItemRow,
            marcaNome: _dvMarcaNome,
            unidadeLabel: _dvUnidadeLabel,
            isLoading: _dvLoadingDetails,
            formatCurrency4: (num v) => _formatPtBrCurrencyThousands(v, 4),
          ));
        }

        children.add(const SizedBox(height: AppSpacing.md));
      }
      i += 1;
    }
    return children;
  }

  Future<void> _save() async {
    debugPrint('GenericCadastroFormSheet: save pressed table=${widget.definition.table} isEdit=$_isEdit');
    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final session = context.read<AppSessionController>();
      final empresaId = session.empresaId;

      // Empresa/Fornecedor: validações condicionais.
      if (_isEmpresa || _isFornecedor) {
        final tipo = _isEmpresa ? _empresaTipoDocumento : _fornecedorTipoDocumento;
        if (tipo == null) {
          debugPrint('${widget.definition.keyName} validation failed: tipodocumento is null');
          _failSave('Preencha: Tipo de Pessoa');
          return;
        }
        final cnpj = _ctrls['cnpj']?.text.trim() ?? '';
        final cpf = _ctrls['cpf']?.text.trim() ?? '';
        if (tipo == 'J' && cnpj.isEmpty) {
          debugPrint('${widget.definition.keyName} validation failed: CNPJ empty');
          _failSave('Preencha: CNPJ');
          return;
        }
        if (tipo == 'J' && cnpj.isNotEmpty && !_isValidCnpj(cnpj)) {
          debugPrint('${widget.definition.keyName} validation failed: CNPJ DV invalid');
          _failSave('CNPJ inválido (dígito verificador)');
          return;
        }
        if (tipo == 'F' && cpf.isEmpty) {
          debugPrint('${widget.definition.keyName} validation failed: CPF empty');
          _failSave('Preencha: CPF');
          return;
        }
        if (tipo == 'F' && cpf.isNotEmpty && !_isValidCpf(cpf)) {
          debugPrint('${widget.definition.keyName} validation failed: CPF DV invalid');
          _failSave('CPF inválido (dígito verificador)');
          return;
        }
      }

      final data = <String, dynamic>{};
      for (final f in widget.definition.fields) {
        if (widget.hiddenColumns.contains(f.column)) {
          // Hidden fields may still be enforced via [forcedValues].
          continue;
        }

        // Campos de auditoria: são exibidos apenas para leitura na UI.
        // Para evitar enviar um valor formatado (dd/MM...) no payload, ignoramos
        // o texto do input e deixamos a lógica de updatedAt preencher o ISO.
        if (f.column.toLowerCase() == 'dataatualizacao') {
          continue;
        }
        final rawInput = _ctrls[f.column]!.text;
        final raw = _isMultilineField(f)
            ? normalizeMultilineText(rawInput) // mantém as quebras de linha
            : (_shouldNormalizeCadastroText(f) ? normalizeCollapsedSpaces(rawInput) : rawInput.trim());

        // Compra / CompraItem: date parsing (dd/MM/yyyy -> yyyy-MM-dd)
        if (_isCompra && f.column == 'datacompra') {
          if (raw.isEmpty) {
            _failSave('Preencha: ${f.label}');
            return;
          }
          final dt = _parseBrDate(raw);
          if (dt == null) {
            _failSave('Data inválida: ${f.label}');
            return;
          }
          data[f.column] = '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
          continue;
        }

        if (_isCompraItem && f.column == 'datavalidade') {
          if (raw.isEmpty) continue;
          final dt = _parseBrDate(raw);
          if (dt == null) {
            _failSave('Data inválida: ${f.label}');
            return;
          }
          data[f.column] = '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
          continue;
        }

        // Usuário: `senha` é NOT NULL no BD, mas na edição deve ser opcional.
        // Se estiver vazio na edição, não valida nem envia.
        if (_isUsuario && _isSenhaField(f) && _isEdit && raw.isEmpty) {
          continue;
        }

        // Para Empresa/Fornecedor, CNPJ/CPF são validados acima (condicional) e não usam o flag `required`.
        if (f.required && raw.isEmpty) {
          _failSave('Preencha: ${f.label}');
          return;
        }
        // Texto longo opcional (Observação/Descrição) apagado na edição: grava null,
        // senão o texto antigo continuaria no banco.
        if (raw.isEmpty && _isEdit && _isMultilineField(f)) {
          data[f.column] = null;
          continue;
        }
        if (raw.isEmpty) continue;

        if ((_isEmpresa || _isFornecedor) && f.column == 'cnpj') {
          data[f.column] = raw.replaceAll(RegExp(r'\D'), '');
          continue;
        }

        if ((_isEmpresa || _isFornecedor) && f.column == 'cpf') {
          data[f.column] = raw.replaceAll(RegExp(r'\D'), '');
          continue;
        }

        if (f.type == CadastroFieldType.number) {
          final parsed = _parsePtBrNumber(raw);

          // Regra: quantidade produzida não pode ser <= 0.
          // Produto: `qtdproduzida` (rotulado como "Qtde produzida na receita")
          // Receita: `qtdreceita`
          if ((widget.definition.keyName == 'produto' && f.column == 'qtdproduzida') ||
              (widget.definition.keyName == 'receita' && f.column == 'qtdreceita')) {
            if (parsed == null) {
              _failSave('Valor inválido: ${f.label}');
              return;
            }
            if (parsed <= 0) {
              _failSave('O campo "${f.label}" deve ser maior que zero.');
              return;
            }
          }

          // Categoria: percentuais não podem exceder 100,00.
          // (Regra solicitada: percentualrateiodespesa <= 100,00)
          if (widget.definition.table == 'categoria' && f.column == 'percentualrateiodespesa') {
            if (parsed == null) {
              _failSave('Valor inválido: ${f.label}');
              return;
            }
            if (parsed > 100) {
              _failSave('O campo "${f.label}" não pode ser maior que 100,00.');
              return;
            }
          }

          // Imposto e taxas: percentuais (imposto/taxa adm) devem ficar entre 0 e 100.
          // Imposto = 100% inviabiliza o cálculo do "Valor de lista do site".
          if (_isEmpresaTaxas && (f.column == 'imposto' || f.column == 'taxaadm')) {
            if (parsed == null) {
              _failSave('Valor inválido: ${f.label}');
              return;
            }
            if (parsed < 0 || parsed >= 100) {
              _failSave('O campo "${f.label}" deve estar entre 0 e 99,99.');
              return;
            }
          }

          // Item: qtde comprada e fator de conversão entram no divisor do custo: > 0.
          if (_isItem && (f.column == 'qtdecomprada' || f.column == 'fatorconversao' || f.column == 'valorcompra')) {
            if (parsed == null) {
              _failSave('Valor inválido: ${f.label}');
              return;
            }
            if (parsed <= 0) {
              _failSave('O campo "${f.label}" deve ser maior que zero.');
              return;
            }
          }

          // Item: embalagens e itens por embalagem são inteiros > 0 (integer no banco).
          if (_isItem && _itemEmbalagemColumns.contains(f.column)) {
            if (parsed == null || parsed <= 0 || parsed != parsed.truncate()) {
              _failSave('O campo "${f.label}" deve ser um número inteiro maior que zero.');
              return;
            }
            data[f.column] = parsed.toInt();
            continue;
          }

          data[f.column] = parsed;
        } else {
          data[f.column] = raw;
        }
      }

      // Item: custo unitário sempre recalculado a partir dos dados da compra.
      if (_isItem && !widget.hiddenColumns.contains('custounitario')) {
        final custo = _computeItemCustoUnitario();
        if (custo == null) {
          _failSave('Não foi possível calcular o custo unitário.');
          return;
        }
        data['custounitario'] = custo;
      }

      // Imposto e taxas da empresa: regras de inclusão/edição.
      if (_isEmpresaTaxas) {
        if (_isEdit) {
          // Na edição só imposto, taxaadm e taxamotoboy podem ser alterados.
          data.removeWhere((k, _) => !_empresaTaxasValueColumns.contains(k));
          for (final col in _empresaTaxasValueColumns) {
            data.putIfAbsent(col, () => null);
          }
        } else {
          if (!session.isSuperAdmin) {
            if (empresaId == null) {
              _failSave('Não foi possível identificar a empresa do usuário logado.');
              return;
            }
            data['empresaid'] = empresaId;
          }
          final novaEmpresaId = data['empresaid'];
          if (novaEmpresaId == null) {
            _failSave('Selecione: Empresa');
            return;
          }
          // Não permitir cadastrar uma empresa que já possui registro.
          final existing = await SupabaseService.select(
            'empresasetup',
            select: 'empresasetupid',
            filters: {'empresaid': novaEmpresaId},
            limit: 1,
          );
          if (existing.isNotEmpty) {
            _failSave('Esta empresa já possui imposto e taxas cadastrados. Edite o registro existente.');
            return;
          }
        }
      }

      // Despesa Variável
      if (_isDespesaVariavel) {
        final rawItemId = _ctrls['itemid']?.text.trim() ?? '';
        final itemId = int.tryParse(rawItemId);
        if (itemId == null) {
          _failSave('Selecione: Item');
          return;
        }
        // IMPORTANTE: não gravamos `nome` aqui.
        // A tabela `despesavariavel` (no seu schema) não possui essa coluna,
        // e a listagem já consegue exibir o nome via join em `item:itemid(nome)`.

        // Campo calculado (valor mensal): garante coerência antes de salvar.
        _recomputeDespesaVariavelValorMensal();

        // Auditoria: sempre atualizar a data/hora de atualização no BD.
        // Coluna usada no BD: dataatualizacao.
        data['dataatualizacao'] = DateTime.now().toIso8601String();

        // Status: respeita o valor vindo do formulário (default 'A' no insert).
        final s = (data['status']?.toString() ?? '').trim().toUpperCase();
        if (s.isNotEmpty) data['status'] = s;
      }

      // Empresa/Fornecedor: garante que só um documento vá para o BD.
      if (_isEmpresa || _isFornecedor) {
        final tipo = _isEmpresa ? _empresaTipoDocumento : _fornecedorTipoDocumento;
        if (tipo == 'J') {
          data.remove('cpf');
        } else if (tipo == 'F') {
          data.remove('cnpj');
        }
      }

      // Forced values always win.
      if (widget.forcedValues != null) {
        data.addAll(widget.forcedValues!);
      }

      // Empresa: if logo was changed in the UI, persist as base64.
      if (_isEmpresa && _empresaLogoDirty) {
        final bytes = _empresaLogoBytes;
        if (bytes == null || bytes.isEmpty) {
          // Clear.
          data['logo_base64'] = null;
          data['logo_mime'] = null;
          // Back-compat: some schemas store in `logo`.
          data['logo'] = null;
        } else {
          final b64 = base64Encode(bytes);
          data['logo_base64'] = b64;
          data['logo_mime'] = (_empresaLogoMime ?? 'image/png').trim();
          // Back-compat: some schemas store in `logo`.
          data['logo'] = b64;
        }
      }

      // Material: `customaterial` is computed in the database (trigger).
      // Never send it from the app to avoid overriding the server-calculated value.
      if (widget.definition.table == 'material') {
        data.remove('customaterial');
      }

      // Produto: `difpercentualvalor` will be computed in the database.
      // Keep it server-owned and let the DB default (0) apply on insert.
      if (widget.definition.table == 'produto') {
        data.remove('difpercentualvalor');
      }

      debugPrint('GenericCadastroFormSheet: payload for ${widget.definition.table} => $data');

      // Categoria: normalize name to avoid accidental duplicates (e.g., trailing spaces).
      // Case-insensitive uniqueness is enforced in DB via uk_categoria_nome (empresaid, lower(nome)).
      if (widget.definition.table == 'categoria') {
        final rawNome = data['nome'];
        if (rawNome is String) {
          final normalized = normalizeCollapsedSpaces(rawNome);
          if (normalized.isNotEmpty) data['nome'] = normalized;
        }
      }

      // Delivery: normalize + enforce unique name (case-insensitive).
      // Observação: como o cadastro é global (scopedByEmpresa=false), a unicidade deve
      // ser garantida no app e idealmente no BD com um UNIQUE em lower(nome).
      if (widget.definition.table == 'delivery') {
        final rawNome = data['nome'];
        if (rawNome is String) {
          final normalized = normalizeCollapsedSpaces(rawNome);
          if (normalized.isEmpty) {
            _failSave('Informe um nome válido.');
            return;
          }

          data['nome'] = normalized;
          try {
            final existing = await SupabaseConfig.client
                .from('delivery')
                .select('deliveryid,nome')
                .ilike('nome', normalized)
                .maybeSingle();

            if (existing != null) {
              final existingId = existing['deliveryid'];
              final rawId = widget.initialRow?[widget.definition.idColumn];
              final currentId = (rawId is num) ? rawId.toInt() : rawId;
              final isSame = currentId != null && existingId != null && existingId.toString() == currentId.toString();
              if (!isSame) {
                _failSave('Já existe um delivery cadastrado com este nome. Informe um nome diferente.');
                return;
              }
            }
          } catch (e) {
            // Se o pre-check falhar por permissão/RLS/rede, não bloqueia o salvamento;
            // deixe o BD rejeitar caso exista constraint.
            debugPrint('Failed to pre-check delivery.nome uniqueness: $e');
          }
        }
      }

      // Classificação de Kit: nome único por empresa (sem diferenciar maiúsculas/minúsculas).
      if (widget.definition.keyName == 'classificacaokit') {
        final normalized = normalizeCollapsedSpaces(data['nome']?.toString() ?? '');
        if (normalized.isEmpty) {
          _failSave('Informe um nome válido.');
          return;
        }
        data['nome'] = normalized;
        if (empresaId == null) {
          _failSave('Não foi possível identificar a empresa do usuário logado.');
          return;
        }
        final existentes = await SupabaseService.select(
          'classificacaokit',
          select: 'classificacaokitid,nome',
          filters: {'empresaid': empresaId},
          limit: 1000,
        );
        final rawId = widget.initialRow?[widget.definition.idColumn];
        final currentId = rawId?.toString();
        final duplicado = existentes.any((r) =>
            normalizeCollapsedSpaces(r['nome']?.toString() ?? '').toLowerCase() == normalized.toLowerCase() &&
            r['classificacaokitid']?.toString() != currentId);
        if (duplicado) {
          _failSave('Já existe uma classificação de kit com este nome para esta empresa.');
          return;
        }
      }

      // Usuario: normalize email and enforce uniqueness (client-side guard).
      if (_isUsuario) {
        final rawEmail = data['email'];
        if (rawEmail is String) {
          final normalizedEmail = rawEmail.trim().toLowerCase();
          data['email'] = normalizedEmail;
          if (normalizedEmail.isNotEmpty) {
            if (!_isValidEmail(normalizedEmail)) {
              _failSave('Informe um email válido.');
              return;
            }
            try {
              final existing = await SupabaseService.selectSingle(
                'usuario',
                select: 'usuarioid,email',
                filters: {'email': normalizedEmail},
              );
              if (existing != null) {
                final existingId = existing['usuarioid'];
                final rawId = widget.initialRow?[widget.definition.idColumn];
                final currentId = (rawId is num) ? rawId.toInt() : rawId;
                final isSame = currentId != null && existingId != null && existingId.toString() == currentId.toString();
                if (!isSame) {
                  _failSave('Já existe um usuário cadastrado com este email.');
                  return;
                }
              }
            } catch (e) {
              // If uniqueness check fails (RLS/network), don't block save silently;
              // let DB constraints catch it if present.
              debugPrint('Failed to pre-check usuario.email uniqueness: $e');
            }
          }
        }
      }

      // Usuario: empresa rules
      // - Administrador: must choose empresa in the form (already required + gating)
      // - Non-admin: empresa is auto-set to logged-in user's empresa and cannot be changed
      if (_isUsuario && !session.isSuperAdmin) {
        if (empresaId == null) {
          _failSave('Não foi possível identificar a empresa do usuário logado.');
          return;
        }
        data['empresaid'] = empresaId;
      }

      if (widget.definition.scopedByEmpresa && empresaId != null) {
        // If the form explicitly collected empresaid (e.g. Usuario), don't override.
        data['empresaid'] ??= empresaId;
      }
      // IMPORTANT: never force `empresaid` when inserting/updating Empresa itself.
      // `empresaid` is PK generated by SEQUENCE; sending it can cause duplicate key errors.

      final nowIso = DateTime.now().toIso8601String();
      if (widget.definition.updatedAtColumn != null && (data[widget.definition.updatedAtColumn!] == null)) {
        data[widget.definition.updatedAtColumn!] = nowIso;
      }
      if (!_isEdit && widget.definition.createdAtColumn != null && (data[widget.definition.createdAtColumn!] == null)) {
        data[widget.definition.createdAtColumn!] = nowIso;
      }

      if (_isEdit) {
        final rawId = widget.initialRow![widget.definition.idColumn];
        final id = (rawId is num) ? rawId.toInt() : rawId;
        if (id == null) {
          _failSave('Registro inválido (sem id).');
          return;
        }
        debugPrint('GenericCadastroFormSheet: updating ${widget.definition.table} where ${widget.definition.idColumn}=$id');
        final updated = await SupabaseService.update(
          widget.definition.table,
          data,
          filters: {widget.definition.idColumn: id},
        );
        debugPrint('GenericCadastroFormSheet: updated rows => ${updated.length}');
        if (updated.isEmpty) {
          // This usually indicates: wrong id type/value, filters not matching any
          // record, or a security policy preventing updates.
          _failSave('Nenhuma linha foi atualizada. Verifique permissões/filtro (id).');
          return;
        }

        // Kits usam imposto/taxa adm do empresasetup em cache.
        if (widget.definition.table == 'empresasetup') KitService.clearEmpresaSetupCache();

        if (_isEmpresa) {
          try {
            await context.read<AppSessionController>().reloadProfile();
          } catch (e) {
            debugPrint('Failed to reload profile after updating empresa: $e');
          }
        }

        // Pós-salvamento: Despesa Variável -> atualizar total agregado da empresa.
        if (_isDespesaVariavel) {
          final resolvedEmpresaId = _resolveEmpresaIdForAfterSave(data, session);
          if (resolvedEmpresaId != null) {
            await _syncTotalDespesasVariavel(resolvedEmpresaId);
          } else {
            debugPrint('DespesaVariavel: skipped total sync (empresaId unresolved).');
          }
        }

        // Pós-salvamento: Despesas Fixas (rateiodespesa) -> atualizar total agregado da empresa.
        if (_isRateioDespesa) {
          final resolvedEmpresaId = _resolveEmpresaIdForAfterSave(data, session);
          if (resolvedEmpresaId != null) {
            await _syncTotalDespesasFixas(resolvedEmpresaId);
          } else {
            debugPrint('RateioDespesa: skipped total sync (empresaId unresolved).');
          }
        }

      } else {
        debugPrint('GenericCadastroFormSheet: inserting into ${widget.definition.table}');
        final inserted = await SupabaseService.insert(widget.definition.table, data);
        final first = inserted.isNotEmpty ? inserted.first : null;
        if (widget.definition.table == 'empresasetup') KitService.clearEmpresaSetupCache();

        if (_isEmpresa) {
          try {
            await context.read<AppSessionController>().reloadProfile();
          } catch (e) {
            debugPrint('Failed to reload profile after inserting empresa: $e');
          }
        }

        // Pós-salvamento: Despesa Variável -> atualizar total agregado da empresa.
        if (_isDespesaVariavel) {
          final resolvedEmpresaId = _resolveEmpresaIdForAfterSave(data, session);
          if (resolvedEmpresaId != null) {
            await _syncTotalDespesasVariavel(resolvedEmpresaId);
          } else {
            debugPrint('DespesaVariavel: skipped total sync (empresaId unresolved).');
          }
        }

        // Pós-salvamento: Despesas Fixas (rateiodespesa) -> atualizar total agregado da empresa.
        if (_isRateioDespesa) {
          final resolvedEmpresaId = _resolveEmpresaIdForAfterSave(data, session);
          if (resolvedEmpresaId != null) {
            await _syncTotalDespesasFixas(resolvedEmpresaId);
          } else {
            debugPrint('RateioDespesa: skipped total sync (empresaId unresolved).');
          }
        }

        if (!mounted) return;
        context.pop(first ?? true);
        return;
      }

      if (!mounted) return;
      context.pop(true);
    } catch (e) {
      debugPrint('Save ${widget.definition.table} failed: $e');
      if (!mounted) return;
      final friendly = _mapSaveErrorToFriendlyMessage(e);
      final msg = kDebugMode && friendly == null ? 'Não foi possível salvar.\n$e' : (friendly ?? 'Não foi possível salvar.');
      _failSave(msg);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  String? _mapSaveErrorToFriendlyMessage(Object error) {
    // Supabase duplicate key (Postgres code 23505) is typically surfaced as:
    // "duplicate key value violates unique constraint \"constraint_name\""
    // When possible, we read the structured fields from PostgrestException.
    var raw = error.toString();
    String? pgCode;
    String? details;

    if (error is PostgrestException) {
      pgCode = error.code?.toString();
      details = error.details?.toString();
      raw = '${error.message} ${error.details ?? ''} ${error.hint ?? ''}'.trim();
    }

    bool containsConstraint(String name) => raw.contains(name) || (details?.contains(name) ?? false);

    final isUniqueViolation = pgCode == '23505' || raw.contains('duplicate key value violates unique constraint');
    if (!isUniqueViolation) return null;

    // Usuario: email duplicado
    if (widget.definition.table == 'usuario' && (containsConstraint('uk_usuario_email') || containsConstraint('usuario_email_key'))) {
      return 'Já existe um usuário cadastrado com este email.';
    }

    // Unicidade por nome (normalizado) — constraints novas.
    if (widget.definition.table == 'delivery' && (containsConstraint('delivery_nome_unique') || containsConstraint('uk_delivery_nome') || containsConstraint('delivery_nome_key'))) {
      return 'Já existe um delivery cadastrado com este nome. Informe um nome diferente.';
    }

    if (widget.definition.table == 'categoria' && (containsConstraint('categoria_nome_unique') || containsConstraint('uk_categoria_nome'))) {
      return 'Já existe uma categoria com este nome para esta empresa. Informe um nome diferente.';
    }

    if (widget.definition.table == 'marca' && containsConstraint('marca_nome_unique')) {
      return 'Já existe uma marca com este nome para esta empresa. Informe um nome diferente.';
    }

    if (widget.definition.table == 'item' && containsConstraint('item_nome_unique')) {
      return 'Já existe um item com este nome para esta empresa. Informe um nome diferente.';
    }

    if (widget.definition.table == 'despesafixa' && containsConstraint('despesafixa_nome_unique')) {
      return 'Já existe uma despesa fixa com este nome para esta empresa. Informe um nome diferente.';
    }

    if (widget.definition.table == 'produto' && containsConstraint('produto_nome_unique')) {
      return 'Já existe um produto com este nome para esta empresa. Informe um nome diferente.';
    }

    if (widget.definition.table == 'kit' && containsConstraint('kit_nome_unique')) {
      return 'Já existe um kit com este nome para esta empresa. Informe um nome diferente.';
    }

    // Receita não usa o cadastro genérico hoje, mas se cair aqui, já fica amigável.
    if (widget.definition.table == 'receita' && containsConstraint('receita_nome_unique')) {
      return 'Já existe uma receita com este nome para esta empresa. Informe um nome diferente.';
    }

    if (widget.definition.table == 'tipoitem' && containsConstraint('tipoitem_nome_unique')) {
      return 'Já existe um tipo de item com este nome. Informe um nome diferente.';
    }

    if (widget.definition.table == 'unidade' && containsConstraint('unidade_unidade_unique')) {
      return 'Já existe uma unidade com este nome. Informe um nome diferente.';
    }

    // Chave primária duplicada no insert: a sequência do id ficou atrás do maior id
    // (ex.: registros inseridos com id explícito). Não é dado repetido do usuário.
    if (!_isEdit && containsConstraint('_pkey')) {
      return 'Não foi possível gerar o código do novo registro (sequência de IDs do banco desatualizada). '
          'Avise o administrador para ressincronizar a sequência da tabela ${widget.definition.table}.';
    }

    // Generic duplicate-key fallback
    return 'Já existe um registro com essas informações (duplicado). Verifique os campos e tente novamente.';
  }

  int? _resolveEmpresaIdForAfterSave(Map<String, dynamic> data, AppSessionController session) {
    final raw = data['empresaid'];
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return session.empresaId;
  }

  Future<void> _syncTotalDespesasVariavel(int empresaId) async {
    // Regra: após criar/editar uma despesa variável, recalcular o total das despesas
    // variáveis ATIVAS da empresa e gravar em `totaldespesas.totaldespesavariavel`.
    // Capturado antes do await: o aviso aparece na tela da lista mesmo após o formulário fechar.
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await TotalDespesasService.recalcularDespesaVariavel(empresaId);
    } catch (e) {
      // Não bloqueia o salvamento do item, mas avisa o usuário.
      debugPrint('Failed to sync totaldespesas.totaldespesavariavel (empresaId=$empresaId): $e');
      _avisarFalhaRecalculo(messenger, 'despesas variáveis');
    }
  }

  Future<void> _syncTotalDespesasFixas(int empresaId) async {
    // Regra: após criar/editar uma despesa fixa, recalcular o total das despesas
    // fixas ATIVAS da empresa e gravar em `totaldespesas.totaldespesafixa`.
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await TotalDespesasService.recalcularDespesaFixa(empresaId);
    } catch (e) {
      debugPrint('Failed to sync totaldespesas.totaldespesafixa (empresaId=$empresaId): $e');
      _avisarFalhaRecalculo(messenger, 'despesas fixas');
    }
  }

  void _avisarFalhaRecalculo(ScaffoldMessengerState? messenger, String oQue) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          'A despesa foi salva, mas não foi possível atualizar o total de $oQue. '
          'Abra a lista novamente ou clique em Atualizar para recalcular.',
        ),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        duration: const Duration(seconds: 8),
      ),
    );
  }

  void _failSave(String message) {
    if (!mounted) return;
    debugPrint('GenericCadastroFormSheet: failSave => $message');
    // Only show the in-sheet error banner.
    // SnackBar here caused duplicate messages (banner + snackbar) and could
    // momentarily render an empty snackbar during quick consecutive errors.
    setState(() => _error = message.trim());
  }

  /// Cadastros com título feminino: "Nova Marca" em vez de "Novo Marca".
  static const _feminineKeyNames = {
    'receita',
    'marca',
    'unidade',
    'empresa',
    'compra',
    'uf',
    'categoria',
    'classificacaokit',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final newPrefix = _feminineKeyNames.contains(widget.definition.keyName) ? 'Nova' : 'Novo';
    final title = _isEdit ? 'Editar ${widget.definition.title}' : '$newPrefix ${widget.definition.title}';

    return Padding(
      padding: EdgeInsets.only(left: AppSpacing.md, right: AppSpacing.md, bottom: viewInsets.bottom + AppSpacing.md, top: AppSpacing.md),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: cs.outline.withValues(alpha: 0.16)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
                  IconButton(
                    tooltip: 'Fechar',
                    onPressed: _isSaving ? null : () => context.pop(false),
                    icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              const SizedBox(height: AppSpacing.md),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      ..._buildFormChildren(context),
                    ],
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: cs.errorContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: cs.error.withValues(alpha: 0.25)),
                  ),
                  child: Padding(
                    padding: AppSpacing.paddingMd,
                    child: Row(
                      children: [
                        Icon(Icons.error_outline_rounded, color: cs.onErrorContainer),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            _error!,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isSaving ? null : () => context.pop(false),
                      child: Text('Cancelar', style: TextStyle(color: cs.primary)),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _isSaving ? null : _save,
                      icon: _isSaving
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary),
                            )
                          : Icon(Icons.save_rounded, color: cs.onPrimary),
                      label: Text(_isSaving ? 'Salvando…' : 'Salvar', style: TextStyle(color: cs.onPrimary)),
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
