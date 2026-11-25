import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Base comum dos relatórios PDF do BakePro: fonte, logo, cabeçalho, rodapé
/// e uma tabela simples. Cada relatório só informa títulos, filtros e dados.
class RelatorioPdfBase {
  static Future<pw.ThemeData> _tema() async {
    try {
      // Fonte com acentuação completa; se não carregar (sem internet), usa a padrão.
      return pw.ThemeData.withFont(
        base: await PdfGoogleFonts.robotoRegular(),
        bold: await PdfGoogleFonts.robotoBold(),
      );
    } catch (e) {
      debugPrint('RelatorioPdfBase: falha ao carregar fonte, usando padrão: $e');
      return pw.ThemeData.base();
    }
  }

  static Future<String?> _logoSvg() async {
    try {
      // Mesmo SVG do topo do app.
      return await rootBundle.loadString('assets/images/BakePro_vetorial.svg');
    } catch (e) {
      debugPrint('RelatorioPdfBase: falha ao carregar logo: $e');
      return null;
    }
  }

  static String dataHoraAgora() {
    final agora = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(agora.day)}/${two(agora.month)}/${agora.year} ${two(agora.hour)}:${two(agora.minute)}';
  }

  /// Gera um relatório em tabela.
  /// [infoLinhas]: linhas de informação abaixo do título (empresa, filtros...).
  /// [colunasEsquerda]: índices das colunas de texto (as demais ficam à direita).
  static Future<Uint8List> gerarTabela({
    required PdfPageFormat format,
    required String titulo,
    required List<String> infoLinhas,
    required List<String> headers,
    required List<List<String>> data,
    Set<int> colunasEsquerda = const {0},
    Map<int, pw.TableColumnWidth>? larguras,
    String mensagemVazio = 'Nenhum registro encontrado para o filtro selecionado.',
    String? notaFinal,
    bool paisagem = true,
  }) async {
    final theme = await _tema();
    final logoSvg = await _logoSvg();

    final doc = pw.Document(theme: theme, title: titulo, author: 'BakePro');
    doc.addPage(
      pw.MultiPage(
        pageFormat: paisagem ? format.landscape : format.portrait,
        margin: const pw.EdgeInsets.all(28),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(titulo, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                logoSvg != null
                    ? pw.SvgImage(svg: logoSvg, height: 72)
                    : pw.Text('BakePro', style: pw.TextStyle(fontSize: 12, color: PdfColors.orange800, fontWeight: pw.FontWeight.bold)),
              ],
            ),
            pw.SizedBox(height: 4),
            for (final linha in infoLinhas)
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 2),
                child: pw.Text(linha, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
              ),
            pw.Divider(color: PdfColors.grey400),
          ],
        ),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 8),
          child: pw.Text('Página ${context.pageNumber} de ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
        ),
        build: (context) => [
          if (data.isEmpty)
            pw.Padding(padding: const pw.EdgeInsets.only(top: 24), child: pw.Text(mensagemVazio))
          else
            pw.TableHelper.fromTextArray(
              headers: headers,
              data: data,
              headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.brown700),
              cellStyle: const pw.TextStyle(fontSize: 9),
              oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
              cellAlignment: pw.Alignment.centerRight,
              cellAlignments: {for (final i in colunasEsquerda) i: pw.Alignment.centerLeft},
              // Toda coluna sem largura definida fica proporcional (Flex 1); misturar com
              // colunas "do tamanho do conteúdo" fazia colunas de texto sumirem.
              columnWidths: {
                for (var i = 0; i < headers.length; i++) i: larguras?[i] ?? const pw.FlexColumnWidth(1),
              },
            ),
          if (notaFinal != null) ...[
            pw.SizedBox(height: 10),
            pw.Text(notaFinal, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
          ],
        ],
      ),
    );
    return doc.save();
  }
}
