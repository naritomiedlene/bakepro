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

/// Versão para textos de várias linhas (ex.: Descrição): limpa espaços extras
/// dentro de cada linha, mas MANTÉM as quebras de linha. Remove linhas vazias
/// no início/fim e junta várias linhas vazias seguidas numa só.
String normalizeMultilineText(String input) {
  final linhas = input.replaceAll('\r\n', '\n').split('\n').map(normalizeCollapsedSpaces).toList();
  final out = <String>[];
  for (final l in linhas) {
    if (l.isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
    out.add(l);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
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
