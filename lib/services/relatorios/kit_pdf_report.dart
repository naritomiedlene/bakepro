import 'package:bakepro/services/relatorios/relatorio_pdf_base.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Delivery ativo da empresa, com o valor de lista calculado para um kit.
class KitPdfDelivery {
  const KitPdfDelivery({required this.nome, this.taxaPct, this.valorLista});
  final String nome;
  final num? taxaPct;
  final num? valorLista;
}

/// Uma linha (kit) do relatório.
class KitPdfLinha {
  const KitPdfLinha({
    required this.nome,
    this.classificacao,
    this.inativo = false,
    this.valorTotal,
    this.valorListaSite,
    this.deliveries = const [],
  });
  final String nome;
  final String? classificacao;
  final bool inativo;
  final num? valorTotal;
  final num? valorListaSite;
  final List<KitPdfDelivery> deliveries;
}

/// Valor de lista = valor / (1 - soma dos percentuais / 100).
/// Retorna null se algum percentual obrigatório faltar ou se o divisor ficar <= 0.
num? calcularValorDeLista(num? valor, List<num?> percentuais) {
  if (valor == null || percentuais.any((p) => p == null)) return null;
  final divisor = 1 - percentuais.fold<num>(0, (acc, p) => acc + p!) / 100;
  if (divisor <= 0) return null;
  return valor / divisor;
}

/// Relatório "Preços dos kits" (mesmas informações da lista de kits).
class KitPdfReport {
  static Future<Uint8List> build({
    required PdfPageFormat format,
    required String empresa,
    required String filtroClassificacao,
    required num? impostoPct,
    required num? taxaMotoboyPct,
    /// Deliveries ativos (nome + taxa), um por coluna.
    required List<KitPdfDelivery> deliveries,
    required List<KitPdfLinha> linhas,
  }) {
    String money(num? v) => v == null ? '-' : formatPtBrCurrency(v);
    String pct(num? v) => v == null ? '-' : '${formatPtBrMoney(v, decimalDigits: 2)}%';
    final deliveriesNomes = [for (final d in deliveries) d.nome];

    return RelatorioPdfBase.gerarTabela(
      format: format,
      titulo: 'Preços dos kits',
      infoLinhas: [
        'Empresa: $empresa   |   Classificação: $filtroClassificacao   |   Gerado em: ${RelatorioPdfBase.dataHoraAgora()}',
        'Imposto: ${pct(impostoPct)}   |   Taxa motoboy: ${pct(taxaMotoboyPct)}   |   Kits: ${linhas.length}',
      ],
      headers: [
        'Kit',
        'Classificação',
        'Valor total do kit',
        'Valor de lista do site',
        for (final d in deliveries) 'Valor de lista ${d.nome} (taxa ${pct(d.taxaPct)})',
      ],
      data: [
        for (final l in linhas)
          [
            l.inativo ? '${l.nome} (inativo)' : l.nome,
            l.classificacao ?? '-',
            money(l.valorTotal),
            money(l.valorListaSite),
            for (final d in deliveriesNomes)
              money(l.deliveries.where((x) => x.nome == d).map((x) => x.valorLista).firstOrNull),
          ],
      ],
      colunasEsquerda: const {0, 1},
      larguras: {0: const pw.FlexColumnWidth(3), 1: const pw.FlexColumnWidth(2)},
      mensagemVazio: 'Nenhum kit encontrado para o filtro selecionado.',
      notaFinal: 'Valor de lista do site = valor total / (1 - imposto/100 - taxa motoboy/100). '
          'Valor de lista do delivery = valor total / (1 - taxa do delivery/100 - imposto/100).',
    );
  }
}
