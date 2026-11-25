import 'package:bakepro/pages/cadastros/generic_cadastro_list_page.dart';
import 'package:bakepro/pages/cadastros/cadastro_definitions.dart';
import 'package:bakepro/pages/cadastros/setup/setup_page.dart';
import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/theme.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

class CadastroRouterPage extends StatelessWidget {
  const CadastroRouterPage({super.key, this.entity, this.openForm = false});

  final String? entity;
  final bool openForm;

  @override
  Widget build(BuildContext context) {
    final resolved = (entity ?? '').trim();
    if (resolved.isEmpty) return const _CadastrosIndex();

    final def = Cadastros.byKey(resolved);
    if (def == null) {
      return _UnknownCadastro(entity: resolved);
    }

    if (def.keyName == 'setup') {
      return SetupPage(definition: def);
    }

    // Empresa + Usuário: somente administradores (A/E) podem acessar.
    if ((def.keyName == 'usuario' || def.keyName == 'empresa') && !context.watch<AppSessionController>().isAdminEmpresa) {
      return const _UnauthorizedCadastro();
    }

    // Delivery: somente Administrador geral (tipo 'A').
    if (def.keyName == 'delivery' && !context.watch<AppSessionController>().isSuperAdmin) {
      return const _UnauthorizedCadastro();
    }

    // Delivery da Empresa:
    // - Administrador geral (A): pode ver todas empresas
    // - Admin da empresa (E): pode ver somente a empresa logada (filtro aplicado na lista)
    if (def.keyName == 'empresadelivery' && !context.watch<AppSessionController>().isAdminEmpresa) {
      return const _UnauthorizedCadastro();
    }

    // Imposto e taxas da empresa:
    // - Administrador geral (A): vê todas as empresas
    // - Admin da empresa (E): vê somente a empresa logada (filtro aplicado na lista)
    if (def.keyName == 'empresataxas' && !context.watch<AppSessionController>().isAdminEmpresa) {
      return const _UnauthorizedCadastro();
    }

    return GenericCadastroListPage(definition: def, openCreateOnLoad: openForm);
  }
}

class _UnauthorizedCadastro extends StatelessWidget {
  const _UnauthorizedCadastro();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: cs.outline.withValues(alpha: 0.18)),
          ),
          child: Padding(
            padding: AppSpacing.paddingLg,
            child: Row(
              children: [
                Icon(Icons.lock_rounded, color: cs.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Você não tem permissão para acessar este cadastro.',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Página de índice para os cadastros operacionais.
///
/// Mantém as entidades no mesmo namespace de rotas (`/cadastros/<entity>`),
/// mas separa a navegação inicial (menu) do “Cadastro básico”.
class CadastroOperacionalIndexPage extends StatelessWidget {
  const CadastroOperacionalIndexPage({super.key});

  static const Set<String> _internalCadastros = {
    'produtoreceita',
    'material',
    'ingrediente',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = context.watch<AppSessionController>();

    const basicCadastros = <String>[
      'empresa',
      'usuario',
      'marca',
      'unidade',
      'rateiodespesa',
      'despesavariavel',
      'categoria',
      'delivery',
      'empresataxas',
      'setup',
    ];
    // Opção 1: “Produto com Receita” (produto) deve aparecer depois de Receita.
    const operationalCadastrosOrder = <String>[
      'item',
      'receita',
      'produto',
      'kit',
    ];

    final allVisibleCadastros = Cadastros.all
        .where((d) => d.visibleInMenu)
        .where((d) => !_internalCadastros.contains(d.keyName))
        .toList(growable: false);

    final operationalCadastros = allVisibleCadastros
        .where((d) => !basicCadastros.contains(d.keyName))
        .where((d) => d.keyName != 'usuario' || session.isAdminEmpresa)
        .where((d) => d.keyName != 'empresa' || session.isAdminEmpresa)
        .toList(growable: false)
      ..sort((a, b) {
        final ia = operationalCadastrosOrder.indexOf(a.keyName);
        final ib = operationalCadastrosOrder.indexOf(b.keyName);
        final aIn = ia != -1;
        final bIn = ib != -1;
        if (aIn && bIn) return ia.compareTo(ib);
        if (aIn) return -1;
        if (bIn) return 1;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });

    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: () => context.go('/'),
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Voltar para Home',
              ),
            ),
            Text('Cadastro operacional', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Selecione um cadastro para listar, incluir, editar ou excluir registros.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.35),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ..._CadastrosSection(
                    title: 'Operacional',
                    definitions: operationalCadastros,
                    basePath: '/cadastros-operacional',
                  ).buildChildren(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CadastrosIndex extends StatelessWidget {
  const _CadastrosIndex();

  static const Set<String> _internalCadastros = {
    'produtoreceita',
    'material',
    'ingrediente',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = context.watch<AppSessionController>();
    const basicCadastros = <String>[
      'empresa',
      'usuario',
      'marca',
      'unidade',
      'rateiodespesa',
      'despesavariavel',
      'categoria',
      'delivery',
      'empresadelivery',
      'empresataxas',
      'setup',
    ];
    // Extra safety: some entities are internal/nested and should never be shown here.
    final allVisibleCadastros = Cadastros.all
        .where((d) => d.visibleInMenu)
        .where((d) => !_internalCadastros.contains(d.keyName))
        .toList(growable: false);

    final basicCadastrosList = allVisibleCadastros
        .where((d) => basicCadastros.contains(d.keyName))
        .where((d) => d.keyName != 'usuario' || session.isAdminEmpresa)
        .where((d) => d.keyName != 'empresa' || session.isAdminEmpresa)
        .where((d) => d.keyName != 'delivery' || session.isSuperAdmin)
        .where((d) => d.keyName != 'empresadelivery' || session.isAdminEmpresa)
        .where((d) => d.keyName != 'empresataxas' || session.isAdminEmpresa)
        .toList(growable: false)
      ..sort((a, b) => basicCadastros.indexOf(a.keyName).compareTo(basicCadastros.indexOf(b.keyName)));
    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: () => context.go('/'),
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Voltar para Home',
              ),
            ),
            Text('Cadastros básico', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Selecione um cadastro para listar, incluir, editar ou excluir registros.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.35),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ..._CadastrosSection(
                    title: 'Básico',
                    definitions: basicCadastrosList,
                  ).buildChildren(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CadastrosSection {
  const _CadastrosSection({required this.title, required this.definitions, this.basePath = '/cadastros'});

  final String title;
  final List<CadastroDefinition> definitions;
  final String basePath;

  List<Widget> buildChildren(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return [
      Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(title, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
      ),
      const SizedBox(height: AppSpacing.sm),
      ...List.generate(definitions.length, (i) {
        final def = definitions[i];
        final icon = Cadastros.icons[def.keyName] ?? Icons.list_alt_rounded;
        return Padding(
          padding: EdgeInsets.only(bottom: i == definitions.length - 1 ? 0 : AppSpacing.sm),
          child: _CadastroCard(
            icon: icon,
            title: def.title,
            // Use push() so the system back button and our back arrow return
            // to the correct index screen (básico vs operacional) instead of
            // replacing the route.
            onTap: () => context.push('$basePath/${def.keyName}'),
            compact: true,
          ),
        );
      }),
    ];
  }
}

class _CadastroCard extends StatelessWidget {
  const _CadastroCard({required this.icon, required this.title, required this.onTap, this.compact = false});

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // The cadastros menu uses a compact card layout, but we still want it
    // comfortably tappable. Increase the compact height substantially.
    final hPad = compact ? AppSpacing.md * 1.2 : AppSpacing.lg;
    final vPad = compact ? AppSpacing.xs * 2.4 : AppSpacing.lg;
    final iconPad = compact ? AppSpacing.xs * 2.4 : AppSpacing.md;
    final iconSize = compact ? 28.0 : 24.0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
                ),
                child: Padding(
                  padding: EdgeInsets.all(iconPad),
                  child: Icon(icon, color: cs.primary, size: iconSize),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnknownCadastro extends StatelessWidget {
  const _UnknownCadastro({required this.entity});
  final String entity;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: AppSpacing.paddingLg,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: cs.outline.withValues(alpha: 0.18)),
          ),
          child: Padding(
            padding: AppSpacing.paddingLg,
            child: Text('Cadastro desconhecido: $entity', style: Theme.of(context).textTheme.bodyLarge),
          ),
        ),
      ),
    );
  }
}
