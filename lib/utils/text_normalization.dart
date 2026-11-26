import 'package:flutter/foundation.dart';

/// Text normalization helpers used across the app.
///
/// For cadastros we want to avoid accidental duplicates like:
/// - leading/trailing spaces
/// - multiple internal spaces ("Acucar  Refinado" vs "Acucar Refinado")
///
/// This helper:
/// - trims
/// - collapses any whitespace sequence (space/tab/newline) into a single space
String normalizeCollapsedSpaces(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return '';
  return trimmed.replaceAll(RegExp(r'\s+'), ' ');
}

/// Lowercased version of [normalizeCollapsedSpaces], useful for case-insensitive comparisons.
String normalizeCollapsedSpacesLower(String input) => normalizeCollapsedSpaces(input).toLowerCase();

/// Chave para ordenar nomes em ordem alfabética sem diferenciar maiúsculas,
/// minúsculas e acentos (ex.: "Água", "agua" e "Aluguel" ficam juntos no "a").
String chaveOrdenacaoAlfabetica(String input) {
  const comAcento = 'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ';
  const semAcento = 'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN';
  final buf = StringBuffer();
  for (final ch in normalizeCollapsedSpaces(input).split('')) {
    final i = comAcento.indexOf(ch);
    buf.write(i >= 0 ? semAcento[i] : ch);
  }
  return buf.toString().toLowerCase();
}

@visibleForTesting
bool isProbablySensitiveTextField(String column) {
  final c = column.toLowerCase();
  return c == 'senha' || c.contains('password');
}
