import 'package:bakepro/theme.dart';
import 'package:flutter/material.dart';

/// Texto da observação de um registro (coluna `obs`), ou null se vazia.
String? observacaoDe(Map<String, dynamic> row) {
  final t = row['obs']?.toString().trim();
  return (t == null || t.isEmpty || t == 'null') ? null : t;
}

/// Janela que mostra a observação de um registro (ex.: item), com quebras de linha.
///
/// Fundo azul-petróleo ([AppStatusColors.observacaoBackground]) nos dois temas,
/// texto branco e ícone/"Fechar" em dourado-mel (tom claro, para contraste).
Future<void> showObservacaoDialog(BuildContext context, {required String titulo, required String texto}) {
  final theme = Theme.of(context);
  const bg = AppStatusColors.observacaoBackground;
  const fg = Colors.white;
  const mel = AppStatusColors.observacaoActionDark;

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: bg,
      // Sem o tom de superfície do Material 3, para o azul-petróleo aparecer puro.
      surfaceTintColor: Colors.transparent,
      icon: const Icon(Icons.sticky_note_2_outlined, color: mel),
      title: Text(
        titulo,
        textAlign: TextAlign.center,
        style: theme.textTheme.headlineSmall?.copyWith(color: fg),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 360),
        child: SingleChildScrollView(
          child: SelectableText(
            texto,
            style: theme.textTheme.bodyMedium?.copyWith(color: fg.withValues(alpha: 0.92), height: 1.4),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          style: TextButton.styleFrom(foregroundColor: mel),
          child: const Text('Fechar'),
        ),
      ],
    ),
  );
}
