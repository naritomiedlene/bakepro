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

    return RelatorioPdfBase.gerarTabela(
      format: format,
      titulo: 'Itens',
      infoLinhas: [
        'Empresa: $empresa   |   Gerado em: ${RelatorioPdfBase.dataHoraAgora()}',
        'Tipo: $filtroTipo   |   Nome contém: ${filtroNome.isEmpty ? '(sem filtro)' : '"$filtroNome"'}   |   Itens: ${itens.length}',
      ],
      headers: const ['Item', 'Tipo', 'Marca', 'Unidade', 'Custo unitário inicial', 'Custo unitário', 'Atualizado em'],
      data: [
        for (final r in itens)
          [
            (r['nome'] ?? '').toString().trim(),
            rel(r['tipoitem'], 'nome') ?? '-',
            rel(r['marca'], 'nome') ?? '-',
            rel(r['unidade'], 'unidade') ?? '-',
            custo(r['custounitarioinicial']),
            custo(r['custounitario']),
            data(r['dataatualizacao']),
          ],
      ],
      colunasEsquerda: const {0, 1, 2, 3},
      larguras: {0: const pw.FlexColumnWidth(3), 1: const pw.FlexColumnWidth(1.5), 2: const pw.FlexColumnWidth(1.5)},
      mensagemVazio: 'Nenhum item encontrado para o filtro selecionado.',
    );
  }
}
