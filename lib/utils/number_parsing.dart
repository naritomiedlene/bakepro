import 'package:flutter/foundation.dart';

/// Parses numbers that may come from the backend either as num, or as strings
/// formatted in pt-BR (e.g. "21,20", "1.234,56").
double? parsePtBrNumber(dynamic raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toDouble();

  final s0 = raw.toString().trim();
  if (s0.isEmpty) return null;

  // Fast path: standard dot-decimal.
  final direct = double.tryParse(s0);
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

/// Formats a numeric value as pt-BR currency.
/// Example: 10.12 -> "R$ 10,12"
String formatPtBrCurrency(num value, {int decimalDigits = 2}) => 'R\$ ${formatPtBrMoney(value, decimalDigits: decimalDigits)}';
