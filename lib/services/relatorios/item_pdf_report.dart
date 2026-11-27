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

    // Custo por unidade de uso (ex.: "R$ 4,0000/Un.").
    String custo(Map<String, dynamic> r) {
      final v = parsePtBrNumber(r['custounitario']);
      if (v == null) return '-';
      final c = formatPtBrCurrency(v, decimalDigits: 4);
      final u = rel(r['unidade'], 'unidade');
      return u == null ? c : '$c/$u';
    }

    // Dados da compra: "-" quando não informados (0 ou vazio).
    // A unidade de compra tem coluna própria.
    String qtdeComprada(Map<String, dynamic> r) {
      final v = parsePtBrNumber(r['qtdecomprada']);
      if (v == null || v == 0) return '-';
      return formatPtBrMoneyThousands(v, decimalDigits: 2);
    }

    // Embalagem: inteiros (default 1 no banco); "-" quando vazio.
    String inteiro(Object? raw) {
      final v = parsePtBrNumber(raw);
      return v == null ? '-' : v.toInt().toString();
    }

    String fator(Object? raw) {
      final v = parsePtBrNumber(raw);
      return (v == null || v == 0) ? '-' : formatPtBrMoneyThousands(v, decimalDigits: 4);
    }

    String valorCompra(Object? raw) {
      final v = parsePtBrNumber(raw);
      return (v == null || v == 0) ? '-' : formatPtBrCurrency(v);
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
      headers: const [
        'Item',
        'Marca',
        'Unidade de compra',
        'Qtde de embalagem',
        'Itens por embalagem',
        'Qtde comprada',
        'Fator de conversão',
        'Valor da compra',
        'Unidade de uso',
        'Custo unitário',
        'Atualizado em',
      ],
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
                  rel(r['compraunidade'], 'unidade') ?? '-',
                  inteiro(r['qtdembalagem']),
                  inteiro(r['qtditemporembalagem']),
                  qtdeComprada(r),
                  fator(r['fatorconversao']),
                  valorCompra(r['valorcompra']),
                  rel(r['unidade'], 'unidade') ?? '-',
                  custo(r),
                  data(r['dataatualizacao']),
                ],
            ],
          ),
      ],
      // Texto à esquerda (Item, Marca, unidades); números à direita.
      colunasEsquerda: const {0, 1, 2, 8},
      // Larguras para caber em uma linha: custo ("R$ 0,1500/Grama"), data e
      // os cabeçalhos de embalagem; as demais colunas usam o padrão (1).
      larguras: {
        0: const pw.FlexColumnWidth(2.5),
        1: const pw.FlexColumnWidth(1.4),
        3: const pw.FlexColumnWidth(1.15),
        4: const pw.FlexColumnWidth(1.15),
        9: const pw.FlexColumnWidth(1.8),
        10: const pw.FlexColumnWidth(1.25),
      },
      mensagemVazio: 'Nenhum item encontrado para o filtro selecionado.',
    );
  }
}
