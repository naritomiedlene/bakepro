import 'package:bakepro/nav.dart';
import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/theme.dart';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSessionController>();
    final user = session.profile;

    // Um AppBar um pouco mais alto ajuda MUITO na nitidez de logos com texto.
    // Se o logo for reduzido demais, o CanvasKit tende a suavizar/"borrar".
    // Ajuste pedido: aumentar o logo nas telas pós-login em +10px.
    const appBarHeight = 114.0;
    const targetLogoHeight = 110.0;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: appBarHeight,
        // Usamos flexibleSpace para garantir que o logo fique realmente centralizado na tela,
        // sem ser afetado pelo Drawer (leading) e pelo chip do usuário (direita).
        title: const SizedBox.shrink(),
        centerTitle: true,
        flexibleSpace: SafeArea(
          child: _AppBarBranding(
            targetLogoHeight: targetLogoHeight,
            profileChip: _ProfileChip(
              name: user?.fullName ?? user?.email ?? 'Usuário',
              subtitle: session.empresaLabel,
              logoUrl: session.empresaLogoUrl,
              logoBytes: session.empresaLogoBytes,
            ),
          ),
        ),
      ),
      drawer: const _AppDrawer(),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: child,
      ),
    );
  }
}

class _AppBarBranding extends StatelessWidget {
  const _AppBarBranding({required this.targetLogoHeight, required this.profileChip});

  final double targetLogoHeight;
  final Widget profileChip;

  static const double _svgAspect = 3.2;

  double _snapToPhysicalPixels(double logicalPx, double dpr) {
    if (logicalPx <= 0) return logicalPx;
    final snapped = (logicalPx * dpr).round() / dpr;
    return snapped <= 0 ? logicalPx : snapped;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // A altura real do logo depende da largura disponível (reserva do leading e do chip).
        // Para garantir “respiro” idêntico no topo, calculamos o inset a partir do
        // height efetivo que vamos renderizar.
        final dpr = MediaQuery.devicePixelRatioOf(context);
        const reservedLeft = 56.0; // largura típica do leading/menu
        const reservedRight = 240.0 + AppSpacing.sm * 2; // maxWidth do chip + padding lateral

        // Em telas estreitas o limite máximo pode ficar menor que o mínimo; clamp(min, max)
        // com min > max lança "Invalid argument". Por isso o mínimo nunca passa do máximo.
        final minWidth = constraints.maxWidth < 120.0 ? constraints.maxWidth : 120.0;
        final availableWidth = (constraints.maxWidth - reservedLeft - reservedRight).clamp(minWidth, constraints.maxWidth);
        final maxHeightFromWidth = availableWidth / _svgAspect;
        final minHeight = maxHeightFromWidth < 40.0 ? maxHeightFromWidth : 40.0;
        final computedHeight = _snapToPhysicalPixels(targetLogoHeight.clamp(minHeight, maxHeightFromWidth), dpr);

        final topInset = (constraints.maxHeight - computedHeight) / 2;
        // Pequeno “slack” para o chip não ficar visualmente mais alto que o respiro do logo.
        // Mantemos isso em AppSpacing para ajuste fino consistente.
        final chipTop = topInset + AppSpacing.sm;

        return Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            Center(child: RepaintBoundary(child: _AppLogoTitle(height: computedHeight))),
            Positioned(right: AppSpacing.sm, top: chipTop, child: profileChip),
          ],
        );
      },
    );
  }
}

class _AppLogoTitle extends StatelessWidget {
  const _AppLogoTitle({required this.height});

  final double height;

  static const List<String> _candidateAssetPaths = [
    // Preferir o SVG vetorial, que costuma ficar mais nítido em qualquer escala.
    'assets/images/BakePro_vetorial.svg',
    // Dreamflow costuma mostrar e organizar imagens em Assets > Images.
    // Se você fizer upload por lá, normalmente vira assets/images/<arquivo>.
    'assets/images/bakepro_logo.png',
    // Caminho alternativo (caso exista uma pasta icons no projeto).
    'assets/icons/bakepro_logo.png',
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.titleLarge?.copyWith(color: cs.onSurface);

    // Evita que uma Row com sizing “min” introduza qualquer nuance de layout;
    // aqui queremos o logo puramente centralizado dentro do Stack.
    return _AssetLogoOrText(assetPaths: _candidateAssetPaths, height: height, textStyle: textStyle);
  }
}

class _AssetLogoOrText extends StatelessWidget {
  const _AssetLogoOrText({required this.assetPaths, required this.height, required this.textStyle});

  final List<String> assetPaths;
  final double height;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    if (assetPaths.isEmpty) return Text('BakePro', style: textStyle);

     final assetPath = assetPaths.first;
     final isSvg = assetPath.toLowerCase().endsWith('.svg');

     if (isSvg) {
       final remaining = assetPaths.sublist(1);
       return _SvgAssetLogoOrFallback(assetPath: assetPath, remainingAssetPaths: remaining, height: height, textStyle: textStyle);
     }

    // Ajuda bastante no Web/CanvasKit: informa ao engine qual tamanho de rasterização
    // queremos em pixels físicos, reduzindo serrilhado/pixelização por reamostragem.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheHeight = (height * dpr).round();
    // Heurística: logos horizontais normalmente ficam bem com ~3.2x largura.
    final cacheWidth = (height * 3.2 * dpr).round();

    return Image.asset(
      assetPath,
      height: height,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      isAntiAlias: true,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      errorBuilder: (context, error, stackTrace) {
        debugPrint('App logo asset not found/failed ($assetPath): $error');
        final remaining = assetPaths.sublist(1);
        if (remaining.isEmpty) return Text('BakePro', style: textStyle);
        return _AssetLogoOrText(assetPaths: remaining, height: height, textStyle: textStyle);
      },
    );
  }
}

class _SvgAssetLogoOrFallback extends StatelessWidget {
  const _SvgAssetLogoOrFallback({required this.assetPath, required this.remainingAssetPaths, required this.height, required this.textStyle});

  final String assetPath;
  final List<String> remainingAssetPaths;
  final double height;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    // Mantém um aspecto razoável para logos “horizontais” sem depender do viewBox do SVG.
    // (Evita o engine aplicar um scale inesperado que pode ficar “soft” em alguns casos.)
    // Arredondar para pixels inteiros reduz suavização por escala fracionada (principalmente no Web).
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final snappedH = ((height * dpr).round() / dpr).roundToDouble();
    final snappedW = (((height * 3.2) * dpr).round() / dpr).roundToDouble();

    return FutureBuilder<String>(
      future: rootBundle.loadString(assetPath),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            height: snappedH,
            width: snappedW,
            child: const Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }

        if (snapshot.hasError) {
          debugPrint('Failed to load SVG asset ($assetPath): ${snapshot.error}');
          if (remainingAssetPaths.isEmpty) return Text('BakePro', style: textStyle);
          return _AssetLogoOrText(assetPaths: remainingAssetPaths, height: height, textStyle: textStyle);
        }

        final data = snapshot.data;
        if (data == null) {
          debugPrint('Failed to load SVG asset (data null): $assetPath');
          if (remainingAssetPaths.isEmpty) return Text('BakePro', style: textStyle);
          return _AssetLogoOrText(assetPaths: remainingAssetPaths, height: height, textStyle: textStyle);
        }

        return RepaintBoundary(
          child: SizedBox(
            height: snappedH,
            width: snappedW,
            child: SvgPicture.string(
              data,
              height: snappedH,
              width: snappedW,
              fit: BoxFit.contain,
              // Centraliza o conteúdo do SVG dentro do box. O centerLeft pode dar
              // a sensação de “desconto” da largura do chip, dependendo do viewBox.
              alignment: Alignment.center,
              clipBehavior: Clip.hardEdge,
            ),
          ),
        );
      },
    );
  }
}

class _ProfileChip extends StatelessWidget {
  const _ProfileChip({required this.name, required this.subtitle, required this.logoUrl, required this.logoBytes});

  final String name;
  final String subtitle;
  final String? logoUrl;
  final Uint8List? logoBytes;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        // Um pouco mais “leve”: menos contraste no fundo e na borda.
        color: cs.surfaceContainerHighest.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outline.withValues(alpha: 0.10)),
      ),
      child: Padding(
        // Mantém o chip discreto, mas com um pouco mais de “respiro” interno.
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.0),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.85), height: 1.0),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppDrawer extends StatelessWidget {
  const _AppDrawer();

  Future<void> _logout(BuildContext context) async {
    try {
      await context.read<AppSessionController>().signOut();
    } catch (e) {
      debugPrint('Logout failed: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível sair. Tente novamente.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loc = GoRouterState.of(context).matchedLocation;

    return Drawer(
      child: SafeArea(
        child: Padding(
          padding: AppSpacing.paddingMd,
          child: Column(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                  border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
                ),
                child: Padding(
                  padding: AppSpacing.paddingMd,
                  child: Row(
                    children: [
                      Icon(Icons.bakery_dining_rounded, color: cs.primary),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Menu', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cs.onSurface)),
                            const SizedBox(height: 2),
                            Text(
                              'Módulos do sistema',
                              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Expanded(
                child: ListView(
                  children: [
                    _DrawerItem(
                      icon: Icons.home_outlined,
                      label: 'Home',
                      selected: loc == AppRoutes.home,
                      onTap: () => context.go(AppRoutes.home),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    _DrawerItem(
                      icon: Icons.inventory_2_outlined,
                      label: 'Cadastros básico',
                      selected: loc == AppRoutes.cadastros || loc.startsWith('${AppRoutes.cadastros}/'),
                      onTap: () => context.go(AppRoutes.cadastros),
                    ),
                    _DrawerItem(
                      icon: Icons.workspaces_outline,
                      label: 'Cadastro operacional',
                      selected: loc.startsWith(AppRoutes.cadastrosOperacional),
                      onTap: () => context.go(AppRoutes.cadastrosOperacional),
                    ),
                    _DrawerItem(
                      icon: Icons.playlist_add_check_outlined,
                      label: 'Listas',
                      selected: loc.startsWith(AppRoutes.listas),
                      onTap: () => context.go(AppRoutes.listas),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _DrawerSectionTitle(title: 'Operação'),
                    _DrawerItem(
                      icon: Icons.shopping_cart_outlined,
                      label: 'Compras',
                      selected: loc.startsWith(AppRoutes.compras),
                      onTap: () => context.go(AppRoutes.compras),
                    ),
                    _DrawerItem(
                      icon: Icons.precision_manufacturing_outlined,
                      label: 'Estoque de Produção',
                      selected: loc.startsWith(AppRoutes.estoqueProducao),
                      onTap: () => context.go(AppRoutes.estoqueProducao),
                    ),
                    _DrawerItem(
                      icon: Icons.inventory_outlined,
                      label: 'Estoque de Produtos',
                      selected: loc.startsWith(AppRoutes.estoqueProdutos),
                      onTap: () => context.go(AppRoutes.estoqueProdutos),
                    ),
                    _DrawerItem(
                      icon: Icons.receipt_long_outlined,
                      label: 'Pedidos',
                      selected: loc.startsWith(AppRoutes.pedidos),
                      onTap: () => context.go(AppRoutes.pedidos),
                    ),
                    _DrawerItem(
                      icon: Icons.factory_outlined,
                      label: 'PCP',
                      selected: loc.startsWith(AppRoutes.pcp),
                      onTap: () => context.go(AppRoutes.pcp),
                    ),
                    _DrawerItem(
                      icon: Icons.point_of_sale_outlined,
                      label: 'Vendas',
                      selected: loc.startsWith(AppRoutes.vendas),
                      onTap: () => context.go(AppRoutes.vendas),
                    ),
                    _DrawerItem(
                      icon: Icons.bar_chart_outlined,
                      label: 'Relatórios',
                      selected: loc.startsWith(AppRoutes.relatorios),
                      onTap: () => context.go(AppRoutes.relatorios),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _logout(context),
                  icon: Icon(Icons.logout_rounded, color: cs.primary),
                  label: Text('Sair', style: TextStyle(color: cs.primary)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DrawerSectionTitle extends StatelessWidget {
  const _DrawerSectionTitle({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.sm, left: AppSpacing.sm),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: cs.onSurfaceVariant,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = selected ? cs.primary.withValues(alpha: 0.10) : Colors.transparent;
    final fg = selected ? cs.primary : cs.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: InkWell(
        onTap: () {
          context.pop();
          onTap();
        },
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: cs.outline.withValues(alpha: 0.10)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
          child: Row(
            children: [
              Icon(icon, color: fg),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: fg),
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
