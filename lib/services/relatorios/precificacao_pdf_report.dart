import 'package:bakepro/services/relatorios/relatorio_pdf_base.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Uma linha (produto) do relatório de precificação — mesmos valores da tela.
class PrecificacaoPdfLinha {
  const PrecificacaoPdfLinha({
    required this.codigo,
    required this.nome,
    required this.categoria,
    required this.producaoMensalPrevista,
    required this.rateioDespesaPct,
    required this.margemLucroPct,
    required this.custoProducao,
    required this.qtdProduzida,
    required this.custoUnitario,
    required this.despesaFixaUn,
    required this.despesaVariavelUn,
    required this.precoCalculado,
    this.precoDefinido,
    this.lucroAtualPct,
    this.precoAtualizadoEm,
  });
  final String codigo;
  final String nome;

  // Dados da categoria (exibidos no título do grupo).
  final String categoria;
  final double? producaoMensalPrevista;
  final double rateioDespesaPct;
  final double margemLucroPct;

  final double custoProducao;
  final double qtdProduzida;
  final double custoUnitario;
  final double despesaFixaUn;
  final double despesaVariavelUn;
  final double precoCalculado;
  final double? precoDefinido;
  final double? lucroAtualPct;
  final DateTime? precoAtualizadoEm;
}

/// Relatório "Precificação de produtos", agrupado por categoria
/// (com filtro de categoria, sai um único grupo).
class PrecificacaoPdfReport {
  static Future<Uint8List> build({
    required PdfPageFormat format,
    required String empresa,
    required String filtroCategoria,
    required String filtroNome,
    required List<PrecificacaoPdfLinha> linhas,
  }) {
    String money(num? v) => v == null ? '-' : formatPtBrCurrency(v);
    String pct(num? v) => v == null ? '-' : '${formatPtBrMoney(v)}%';
    String pctSinal(num? v) => v == null ? '-' : '${v >= 0 ? '+' : '-'}${formatPtBrMoney(v.abs())}%';
    String qtd(num? v) => v == null ? '-' : (v == v.roundToDouble() ? v.toInt().toString() : formatPtBrMoney(v));
    String data(DateTime? dt) {
      if (dt == null) return '-';
      final l = dt.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(l.day)}/${two(l.month)}/${l.year}';
    }

    // Agrupa por categoria (ordem alfabética; "Sem categoria" por último).
    final porCategoria = <String, List<PrecificacaoPdfLinha>>{};
    for (final l in linhas) {
      porCategoria.putIfAbsent(l.categoria.trim(), () => []).add(l);
    }
    final nomes = porCategoria.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty) return 1;
        if (b.isEmpty) return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    final grupos = [
      for (final nome in nomes)
        () {
          final itens = porCategoria[nome]!;
          final c = itens.first; // dados da categoria são iguais para todos os produtos dela
          return RelatorioPdfGrupo(
            titulo: nome.isEmpty ? 'Sem categoria' : nome,
            info: nome.isEmpty
                ? '${itens.length} produto(s)'
                : [
                    'Produção mensal prevista: ${qtd(c.producaoMensalPrevista)}',
                    '% Rateio de despesa: ${pct(c.rateioDespesaPct)}',
                    'Margem de lucro: ${pct(c.margemLucroPct)}',
                    '${itens.length} produto(s)',
                  ].join('   |   '),
            data: [
              for (final l in itens)
                [
                  l.codigo,
                  l.nome,
                  money(l.custoProducao),
                  qtd(l.qtdProduzida),
                  money(l.custoUnitario),
                  money(l.despesaFixaUn),
                  money(l.despesaVariavelUn),
                  money(l.precoCalculado),
                  money(l.precoDefinido),
                  pctSinal(l.lucroAtualPct),
                  data(l.precoAtualizadoEm),
                ],
            ],
          );
        }(),
    ];

    return RelatorioPdfBase.gerarTabela(
      format: format,
      titulo: 'Precificação de produtos',
      infoLinhas: [
        'Empresa: $empresa   |   Gerado em: ${RelatorioPdfBase.dataHoraAgora()}',
        'Categoria: $filtroCategoria   |   Produto contém: ${filtroNome.isEmpty ? '(sem filtro)' : '"$filtroNome"'}   |   Produtos: ${linhas.length}',
      ],
      headers: const [
        'Código',
        'Produto',
        'Custo de produção',
        'Qtd produzida',
        'Custo produção / un.',
        'Despesa fixa / un.',
        'Despesa variável / un.',
        'Preço venda calculado / un.',
        'Preço venda definido / un.',
        'Lucro atual',
        'Preço atualizado em',
      ],
      grupos: grupos,
      colunasEsquerda: const {0, 1},
      larguras: {0: const pw.FlexColumnWidth(0.9), 1: const pw.FlexColumnWidth(2.6)},
      mensagemVazio: 'Nenhum produto encontrado para o filtro selecionado.',
      notaFinal: 'Preço venda calculado = (custo produção + despesa fixa + despesa variável por unidade) x (1 + margem de lucro/100). '
          'Lucro atual = preço definido / (custo + despesas por unidade) - 1.',
    );
  }
}
