import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

/// Abre, em tela cheia, a pré-visualização de um relatório PDF com os botões
/// Imprimir e Salvar (no navegador, "compartilhar" baixa o arquivo).
/// [arquivo] é o prefixo do nome do arquivo; a data (AAAAMMDD) é acrescentada.
Future<void> showPdfPreviewDialog(
  BuildContext context, {
  required String titulo,
  required String arquivo,
  required Future<Uint8List> Function(PdfPageFormat format) build,
}) {
  final hoje = DateTime.now();
  final fileName = '${arquivo}_${hoje.year}${hoje.month.toString().padLeft(2, '0')}${hoje.day.toString().padLeft(2, '0')}.pdf';
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(titulo),
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            tooltip: 'Fechar',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: PdfPreview(
          build: build,
          pdfFileName: fileName,
          allowPrinting: true,
          allowSharing: true,
          canChangePageFormat: false,
          canChangeOrientation: false,
          canDebug: false,
        ),
      ),
    ),
  );
}
