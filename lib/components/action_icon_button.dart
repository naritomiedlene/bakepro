import 'package:bakepro/theme.dart';
import 'package:flutter/material.dart';

enum _ActionKind { edit, delete, ingredientes, materiais }

/// Botões de ação padrão do app.
///
/// Look and feel definido na tela de edição de Kit: botão quadrado com cantos
/// arredondados e fundo suave. Cada ação tem sua cor:
/// - editar (lápis): primária (terracota);
/// - excluir (lixeira): erro (vermelho);
/// - ingredientes da receita: terciária (verde-azulado);
/// - materiais da receita: âmbar.
/// Use sempre estes construtores em vez de `IconButton` solto.
class AppActionIconButton extends StatelessWidget {
  const AppActionIconButton._(this._kind, {required this.icon, required this.tooltip, required this.onPressed});

  /// Lápis: abre a edição do registro.
  const AppActionIconButton.edit({required VoidCallback? onPressed, String tooltip = 'Editar'})
      : this._(_ActionKind.edit, icon: Icons.edit_rounded, tooltip: tooltip, onPressed: onPressed);

  /// Lixeira: exclui o registro.
  const AppActionIconButton.delete({required VoidCallback? onPressed, String tooltip = 'Excluir'})
      : this._(_ActionKind.delete, icon: Icons.delete_outline_rounded, tooltip: tooltip, onPressed: onPressed);

  /// Receita: abre os ingredientes.
  const AppActionIconButton.ingredientes({required VoidCallback? onPressed, String tooltip = 'Ingredientes'})
      : this._(_ActionKind.ingredientes, icon: Icons.science_outlined, tooltip: tooltip, onPressed: onPressed);

  /// Receita: abre os materiais de preparo.
  const AppActionIconButton.materiais({required VoidCallback? onPressed, String tooltip = 'Materiais'})
      : this._(_ActionKind.materiais, icon: Icons.all_inbox_outlined, tooltip: tooltip, onPressed: onPressed);

  final _ActionKind _kind;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final (Color fg, Color bg) = switch (_kind) {
      _ActionKind.edit => (cs.primary, cs.primaryContainer.withValues(alpha: 0.55)),
      _ActionKind.delete => (cs.error, cs.errorContainer.withValues(alpha: 0.65)),
      // Sem tertiary/secondaryContainer no tema: fundo = a própria cor, translúcida.
      _ActionKind.ingredientes => (cs.tertiary, cs.tertiary.withValues(alpha: 0.20)),
      _ActionKind.materiais => () {
          final c = isDark ? AppStatusColors.materiaisActionDark : AppStatusColors.materiaisActionLight;
          return (c, c.withValues(alpha: 0.20));
        }(),
    };

    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: fg),
      style: IconButton.styleFrom(
        backgroundColor: bg,
        padding: const EdgeInsets.all(10),
        minimumSize: const Size(40, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        splashFactory: NoSplash.splashFactory,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      ),
    );
  }
}
