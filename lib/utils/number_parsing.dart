import 'package:flutter/foundation.dart';

/// Parses numbers that may come from the backend either as num, or as strings
/// formatted in pt-BR (e.g. "21,20", "1.234,56").
double? parsePtBrNumber(dynamic raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toDouble();

  final s0 = raw.toString().trim();
  if (s0.isEmpty) return null;

  // Pontos em grupos de 3 sem vírgula ("1.000") são milhar pt-BR, não decimal.
  final isPtBrThousandsOnly = RegExp(r'^-?\d{1,3}(\.\d{3})+$').hasMatch(s0);

  // Fast path: standard dot-decimal.
  final direct = isPtBrThousandsOnly ? null : double.tryParse(s0);
  if (direct != null) return direct;

  // pt-BR normalization: remove thousand separators '.' and swap ',' -> '.'
  // Examples:
  //  - 21,20 -> 21.20
  //  - 1.234,56 -> 1234.56
  final normalized = s0.replaceAll('.', '').replaceAll(',', '.');
  final n = double.tryParse(normalized);
  if (n == null) debugPrint('parsePtBrNumber: failed to parse raw="$s0" normalized="$normalized"');
  return n;
}

/// Formats a numeric value as pt-BR money (decimal comma).
/// Example: 10.12 -> "10,12"
String formatPtBrMoney(num value, {int decimalDigits = 2}) => value.toStringAsFixed(decimalDigits).replaceAll('.', ',');

/// Formata em pt-BR com separador de milhar (ponto) e decimal (vírgula).
/// Example: 1234567.891 -> "1.234.567,89"
String formatPtBrMoneyThousands(num value, {int decimalDigits = 2}) {
  final fixed = value.abs().toStringAsFixed(decimalDigits);
  // Evita "-0,00" quando o valor negativo arredonda para zero.
  final negative = value < 0 && RegExp(r'[1-9]').hasMatch(fixed);
  final parts = fixed.split('.');
  final intPart = parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write('.');
    buf.write(intPart[i]);
  }
  final decPart = parts.length > 1 ? ',${parts[1]}' : '';
  return '${negative ? '-' : ''}$buf$decPart';
}

/// Formats a numeric value as pt-BR currency, com separador de milhar.
/// Somente para exibição (não usar como valor inicial de campos editáveis).
/// Example: 1234.5 -> "R$ 1.234,50"
String formatPtBrCurrency(num value, {int decimalDigits = 2}) => 'R\$ ${formatPtBrMoneyThousands(value, decimalDigits: decimalDigits)}';
