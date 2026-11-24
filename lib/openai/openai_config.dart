import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// OpenAI proxy configuration + helpers.
///
/// IMPORTANT (Dreamflow): values are injected at runtime via environment.
class OpenAiConfig {
  static const apiKey = String.fromEnvironment('OPENAI_PROXY_API_KEY');
  static const endpoint = String.fromEnvironment('OPENAI_PROXY_ENDPOINT');

  static Uri get _uri => Uri.parse(endpoint);

  static Map<String, String> get _headers => {
    'Content-Type': 'application/json; charset=utf-8',
    if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
  };

  /// Parses a purchase/invoice image or a plain-text (CSV/TXT) representation
  /// and returns a normalized list of items.
  ///
  /// Output fields per item:
  /// - descricao
  /// - quantidade
  /// - custo_unitario
  /// - custo_total
  static Future<List<ImportedCompraLine>> extractCompraItems({
    Uint8List? imageBytes,
    String? textContent,
  }) async {
    if ((imageBytes == null || imageBytes.isEmpty) && (textContent == null || textContent.trim().isEmpty)) {
      throw Exception('Arquivo inválido: sem conteúdo para ler.');
    }
    if (endpoint.isEmpty) {
      throw Exception('OPENAI_PROXY_ENDPOINT não configurado.');
    }

    final sys = {
      'role': 'system',
      'content':
          'Você é um extrator de itens de nota fiscal/compra. Responda SOMENTE com um JSON válido (objeto) no formato {"items": [...]}.'
    };

    final content = <Map<String, dynamic>>[
      {
        'type': 'text',
        'text':
            'Extraia os itens de compra do conteúdo abaixo e gere JSON no formato:\n\n{\n  "items": [\n    {"descricao": "...", "quantidade": 1, "custo_unitario": 12.34, "custo_total": 12.34}\n  ]\n}\n\nRegras:\n- "descricao" sempre string, sem preços embutidos.\n- "quantidade" número (pode ser decimal).\n- "custo_unitario" e "custo_total" em reais, números (use ponto como separador decimal no JSON).\n- Se o total não estiver explícito, calcule quantidade*custo_unitario.\n- Ignore cabeçalhos/rodapés.\n- Não invente itens: se estiver ilegível, omita.'
      },
      if (textContent != null && textContent.trim().isNotEmpty)
        {
          'type': 'text',
          'text': 'CONTEÚDO (texto/CSV):\n$textContent',
        },
      if (imageBytes != null && imageBytes.isNotEmpty)
        {
          'type': 'image_url',
          'image_url': {'url': r'data:image/jpeg;base64,' + base64Encode(imageBytes)},
        },
    ];

    final body = jsonEncode({
      'model': 'gpt-4o-mini',
      'temperature': 0.1,
      'response_format': {'type': 'json_object'},
      'messages': [
        sys,
        {'role': 'user', 'content': content},
      ],
    });

    http.Response resp;
    try {
      resp = await http.post(_uri, headers: _headers, body: body);
    } catch (e) {
      debugPrint('OpenAI request failed: $e');
      rethrow;
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final raw = utf8.decode(resp.bodyBytes);
      debugPrint('OpenAI bad status ${resp.statusCode}: $raw');
      throw Exception('Falha ao ler arquivo (OpenAI ${resp.statusCode}).');
    }

    final decoded = utf8.decode(resp.bodyBytes);
    Map<String, dynamic> root;
    try {
      final envelope = jsonDecode(decoded);
      final choices = envelope is Map ? envelope['choices'] : null;
      final first = (choices is List && choices.isNotEmpty) ? choices.first : null;
      final msg = (first is Map) ? first['message'] : null;
      final contentText = (msg is Map) ? msg['content'] : null;
      if (contentText is! String) throw const FormatException('Resposta sem content');
      root = jsonDecode(contentText) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('OpenAI JSON parse failed: $e\n$decoded');
      throw Exception('Falha ao interpretar a resposta do importador.');
    }

    final itemsAny = root['items'];
    if (itemsAny is! List) return const [];

    final out = <ImportedCompraLine>[];
    for (final it in itemsAny) {
      if (it is! Map) continue;
      final desc = (it['descricao'] ?? it['descrição'] ?? it['descricao_item'] ?? '').toString().trim();
      if (desc.isEmpty) continue;

      final qtd = _coerceNum(it['quantidade']) ?? 0;
      final unit = _coerceNum(it['custo_unitario']) ?? _coerceNum(it['unitario']) ?? 0;
      final totalRaw = _coerceNum(it['custo_total']) ?? _coerceNum(it['total']);
      final total = totalRaw ?? (qtd * unit);
      if (qtd <= 0) continue;

      out.add(
        ImportedCompraLine(
          descricao: desc,
          quantidade: qtd,
          custoUnitario: unit,
          custoTotal: total,
        ),
      );
    }
    return out;
  }

  static num? _coerceNum(dynamic v) {
    if (v == null) return null;
    if (v is num) return v;
    var s = v.toString().trim();
    if (s.isEmpty) return null;

    // Keep digits and decimal separators.
    s = s.replaceAll('R\$', '');
    s = s.replaceAll(RegExp(r'[^0-9,\.-]'), '');
    if (s.isEmpty) return null;

    // If there is a comma, treat it as decimal separator and remove thousand dots.
    if (s.contains(',')) {
      s = s.replaceAll('.', '').replaceAll(',', '.');
    }
    return num.tryParse(s);
  }
}

class ImportedCompraLine {
  ImportedCompraLine({required this.descricao, required this.quantidade, required this.custoUnitario, required this.custoTotal, this.itemId});

  final String descricao;
  final num quantidade;
  final num custoUnitario;
  final num custoTotal;
  int? itemId;
}
