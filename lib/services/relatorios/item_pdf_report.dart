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
    // Qtde comprada na unidade de conteúdo (ex.: "2.000,00 Metro").
    String qtdeComprada(Map<String, dynamic> r) {
      final v = parsePtBrNumber(r['qtdecomprada']);
      if (v == null || v == 0) return '-';
      final q = formatPtBrMoneyThousands(v, decimalDigits: 2);
      final u = rel(r['conteudounidade'], 'unidade');
      return u == null ? q : '$q $u';
    }

    // Conteúdo de cada item na unidade de conteúdo (ex.: "100,00 Metro"),
    // com 2 a 4 casas (zeros finais além da 2ª casa removidos).
    String conteudoItem(Map<String, dynamic> r) {
      final v = parsePtBrNumber(r['conteudoitem']);
      if (v == null || v == 0) return '-';
      var q = formatPtBrMoneyThousands(v, decimalDigits: 4);
      while (q.endsWith('0') && q.length - q.lastIndexOf(',') - 1 > 2) {
        q = q.substring(0, q.length - 1);
      }
      final u = rel(r['conteudounidade'], 'unidade');
      return u == null ? q : '$q $u';
    }

    // Qtde comprada na unidade de uso (qtde × fator, ex.: "200.000,00 Cm").
    String qtdeCompradaItem(Map<String, dynamic> r) {
      final v = parsePtBrNumber(r['qtdecompradaitem']);
      if (v == null || v == 0) return '-';
      final q = formatPtBrMoneyThousands(v, decimalDigits: 2);
      final u = rel(r['unidade'], 'unidade');
      return u == null ? q : '$q $u';
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
        'Qtde de embalagens',
        'Itens por embalagem',
        'Qtde de conteúdo por item',
        'Qtde comprada',
        'Fator de conversão',
        'Qtde comprada na unidade de uso',
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
                  conteudoItem(r),
                  qtdeComprada(r),
                  fator(r['fatorconversao']),
                  qtdeCompradaItem(r),
                  valorCompra(r['valorcompra']),
                  rel(r['unidade'], 'unidade') ?? '-',
                  custo(r),
                  data(r['dataatualizacao']),
                ],
            ],
          ),
      ],
      // Texto à esquerda (Item, Marca, unidades); números à direita.
      colunasEsquerda: const {0, 1, 2, 10},
      // Larguras para caber em uma linha: custo ("R$ 0,1500/Grama"), data e
      // os cabeçalhos de embalagem; as demais colunas usam o padrão (1).
      larguras: {
        0: const pw.FlexColumnWidth(1.45),
        1: const pw.FlexColumnWidth(1.1),
        3: const pw.FlexColumnWidth(1.4),
        4: const pw.FlexColumnWidth(1.25),
        5: const pw.FlexColumnWidth(1.25),
        6: const pw.FlexColumnWidth(1.3),
        7: const pw.FlexColumnWidth(1.25),
        8: const pw.FlexColumnWidth(1.4),
        9: const pw.FlexColumnWidth(1.35),
        11: const pw.FlexColumnWidth(1.85),
        12: const pw.FlexColumnWidth(1.3),
      },
      mensagemVazio: 'Nenhum item encontrado para o filtro selecionado.',
    );
  }
}
