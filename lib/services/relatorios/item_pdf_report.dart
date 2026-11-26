import 'package:bakepro/services/relatorios/relatorio_pdf_base.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Relatório "Itens" (mesmas informações da lista de itens, com os filtros aplicados).
class ItemPdfReport {
  static Future<Uint8List> build({
    required PdfPageFormat format,
    required String empresa,
    required String filtroTipo,
    required String filtroNome,
    required List<Map<String, dynamic>> itens,
  }) {
    String? rel(Object? related, String field) {
      final v = related is Map ? related[field]?.toString().trim() : null;
      return (v == null || v.isEmpty || v == 'null') ? null : v;
    }

    String custo(Object? raw) {
      final v = parsePtBrNumber(raw);
      return v == null ? '-' : formatPtBrCurrency(v, decimalDigits: 4);
    }

    String data(Object? raw) {
      final dt = raw == null ? null : DateTime.tryParse(raw.toString());
      if (dt == null) return '-';
      final l = dt.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(l.day)}/${two(l.month)}/${l.year}';
    }

    // Agrupa por tipo do item (ordem alfabética; "Sem tipo" por último).
    // Com um tipo filtrado, sai um único grupo.
    final porTipo = <String, List<Map<String, dynamic>>>{};
    for (final r in itens) {
      porTipo.putIfAbsent(rel(r['tipoitem'], 'nome') ?? '', () => []).add(r);
    }
    final tipos = porTipo.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty) return 1;
        if (b.isEmpty) return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    return RelatorioPdfBase.gerarTabela(
      format: format,
      titulo: 'Itens',
      infoLinhas: [
        'Empresa: $empresa   |   Gerado em: ${RelatorioPdfBase.dataHoraAgora()}',
        'Tipo: $filtroTipo   |   Nome contém: ${filtroNome.isEmpty ? '(sem filtro)' : '"$filtroNome"'}   |   Itens: ${itens.length}',
      ],
      // A coluna Tipo sai da tabela: o tipo é o título de cada grupo.
      headers: const ['Item', 'Marca', 'Unidade', 'Custo unitário inicial', 'Custo unitário', 'Atualizado em'],
      grupos: [
        for (final tipo in tipos)
          RelatorioPdfGrupo(
            titulo: tipo.isEmpty ? 'Sem tipo' : tipo,
            info: '${porTipo[tipo]!.length} item(ns)',
            data: [
              for (final r in porTipo[tipo]!)
                [
                  (r['nome'] ?? '').toString().trim(),
                  rel(r['marca'], 'nome') ?? '-',
                  rel(r['unidade'], 'unidade') ?? '-',
                  custo(r['custounitarioinicial']),
                  custo(r['custounitario']),
                  data(r['dataatualizacao']),
                ],
            ],
          ),
      ],
      colunasEsquerda: const {0, 1, 2},
      larguras: {0: const pw.FlexColumnWidth(3), 1: const pw.FlexColumnWidth(1.5)},
      mensagemVazio: 'Nenhum item encontrado para o filtro selecionado.',
    );
  }
}
