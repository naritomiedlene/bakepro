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
    required this.margemLucroPct,
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
  final String categoria;
  final double margemLucroPct;
  final double custoUnitario;
  final double despesaFixaUn;
  final double despesaVariavelUn;
  final double precoCalculado;
  final double? precoDefinido;
  final double? lucroAtualPct;
  final DateTime? precoAtualizadoEm;
}

/// Relatório "Precificação de produtos" (filtros de categoria e nome aplicados).
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
    String data(DateTime? dt) {
      if (dt == null) return '-';
      final l = dt.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(l.day)}/${two(l.month)}/${l.year}';
    }

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
        'Categoria',
        'Margem de lucro',
        'Custo produção / un.',
        'Despesa fixa / un.',
        'Despesa variável / un.',
        'Preço venda calculado / un.',
        'Preço venda definido / un.',
        'Lucro atual',
        'Preço atualizado em',
      ],
      data: [
        for (final l in linhas)
          [
            l.codigo,
            l.nome,
            l.categoria.isEmpty ? '-' : l.categoria,
            pct(l.margemLucroPct),
            money(l.custoUnitario),
            money(l.despesaFixaUn),
            money(l.despesaVariavelUn),
            money(l.precoCalculado),
            money(l.precoDefinido),
            pctSinal(l.lucroAtualPct),
            data(l.precoAtualizadoEm),
          ],
      ],
      colunasEsquerda: const {0, 1, 2},
      // Todas as colunas proporcionais: com colunas "do tamanho do conteúdo" misturadas,
      // Produto e Categoria ficavam sem espaço e sumiam.
      larguras: {
        0: const pw.FlexColumnWidth(0.9),
        1: const pw.FlexColumnWidth(2.4),
        2: const pw.FlexColumnWidth(1.6),
        for (var i = 3; i <= 10; i++) i: const pw.FlexColumnWidth(1),
      },
      mensagemVazio: 'Nenhum produto encontrado para o filtro selecionado.',
      notaFinal: 'Preço venda calculado = (custo produção + despesa fixa + despesa variável por unidade) x (1 + margem de lucro/100). '
          'Lucro atual = preço definido / (custo + despesas por unidade) - 1.',
    );
  }
}
