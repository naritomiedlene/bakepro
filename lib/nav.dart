import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:bakepro/pages/home_page.dart';
import 'package:bakepro/pages/auth/login_page.dart';
import 'package:bakepro/pages/auth/force_password_change_page.dart';
import 'package:bakepro/pages/shell/app_shell.dart';
import 'package:bakepro/pages/placeholder/placeholder_page.dart';
import 'package:bakepro/pages/cadastros/cadastro_router_page.dart';
import 'package:bakepro/pages/cadastros/cadastro_definitions.dart';
import 'package:bakepro/pages/cadastros/generic_cadastro_list_page.dart';
import 'package:bakepro/pages/cadastros/produto/produto_cascade_page.dart';
import 'package:bakepro/pages/cadastros/kit/kit_cascade_page.dart';
import 'package:bakepro/pages/compras/compras_router_page.dart';
import 'package:bakepro/pages/compras/compra/compra_cascade_page.dart';
import 'package:bakepro/pages/listas/itens/item_edit_page.dart';
import 'package:bakepro/pages/listas/itens/itens_table_page.dart';
import 'package:bakepro/pages/listas/listas_page.dart';
import 'package:bakepro/pages/listas/precificacao/precificacao_produtos_page.dart';
import 'package:bakepro/pages/listas/precificacao/preco_venda_produto_page.dart';
import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/route_observer.dart';

/// GoRouter configuration for app navigation
///
/// This uses go_router for declarative routing, which provides:
/// - Type-safe navigation
/// - Deep linking support (web URLs, app links)
/// - Easy route parameters
/// - Navigation guards and redirects
///
/// To add a new route:
/// 1. Add a route constant to AppRoutes below
/// 2. Add a GoRoute to the routes list
/// 3. Navigate using context.go() or context.push()
/// 4. Use context.pop() to go back.
class AppRouter {
  static GoRouter router(AppSessionController session) => GoRouter(
    initialLocation: AppRoutes.home,
    refreshListenable: session,
    observers: [appRouteObserver],
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final loggingIn = loc == AppRoutes.login;
      final forcing = loc == AppRoutes.forcePasswordChange;

      if (!session.isInitialized) return AppRoutes.login;
      if (!session.isSignedIn) return loggingIn ? null : AppRoutes.login;
      if (session.mustChangePassword) {
        return forcing ? null : AppRoutes.forcePasswordChange;
      }
      if (loggingIn || forcing) return AppRoutes.home;
      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.login,
        name: 'login',
        pageBuilder: (context, state) => const NoTransitionPage(child: LoginPage()),
      ),
      GoRoute(
        path: AppRoutes.forcePasswordChange,
        name: 'forcePasswordChange',
        pageBuilder: (context, state) => const NoTransitionPage(child: ForcePasswordChangePage()),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.home,
            name: 'home',
            pageBuilder: (context, state) => const NoTransitionPage(child: HomePage()),
          ),
          GoRoute(
            path: AppRoutes.cadastros,
            name: 'cadastros',
            pageBuilder: (context, state) => const NoTransitionPage(child: CadastroRouterPage()),
            routes: [
              GoRoute(
                path: 'receita/:id/ingredientes',
                name: 'receitaIngredientes',
                pageBuilder: (context, state) {
                  final raw = state.pathParameters['id'] ?? '';
                  final receitaId = int.tryParse(raw);
                  final def = Cadastros.byKey('ingrediente');
                  if (def == null || receitaId == null) {
                    return const NoTransitionPage(child: CadastroRouterPage());
                  }
                  return NoTransitionPage(
                    child: GenericCadastroListPage(
                      definition: def,
                      extraFilters: {'receitaid': receitaId},
                      createForcedValues: {'receitaid': receitaId},
                      createHiddenColumns: {'receitaid'},
                    ),
                  );
                },
              ),
              GoRoute(
                path: 'receita/:id/materiais',
                name: 'receitaMateriais',
                pageBuilder: (context, state) {
                  final raw = state.pathParameters['id'] ?? '';
                  final receitaId = int.tryParse(raw);
                  final def = Cadastros.byKey('material');
                  if (def == null || receitaId == null) {
                    return const NoTransitionPage(child: CadastroRouterPage());
                  }
                  return NoTransitionPage(
                    child: GenericCadastroListPage(
                      definition: def,
                      extraFilters: {'receitaid': receitaId},
                      createForcedValues: {'receitaid': receitaId},
                      createHiddenColumns: {'receitaid'},
                    ),
                  );
                },
              ),
              GoRoute(
                path: 'produto/:id',
                name: 'produtoCascade',
                pageBuilder: (context, state) {
                  final raw = state.pathParameters['id'] ?? '';
                  final id = int.tryParse(raw);
                  return NoTransitionPage(child: ProdutoCascadePage(produtoId: id));
                },
              ),
              GoRoute(
                path: 'kit/:id',
                name: 'kitCascade',
                pageBuilder: (context, state) {
                  final raw = state.pathParameters['id'] ?? '';
                  final id = int.tryParse(raw);
                  return NoTransitionPage(child: KitCascadePage(kitId: id));
                },
              ),
              GoRoute(
                path: ':entity',
                name: 'cadastroEntity',
                pageBuilder: (context, state) {
                  final entity = state.pathParameters['entity'] ?? '';
                  return NoTransitionPage(child: CadastroRouterPage(entity: entity));
                },
              ),
              GoRoute(
                path: ':entity/form',
                name: 'cadastroEntityForm',
                pageBuilder: (context, state) {
                  final entity = state.pathParameters['entity'] ?? '';
                  return NoTransitionPage(child: CadastroRouterPage(entity: entity, openForm: true));
                },
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.cadastrosOperacional,
            name: 'cadastrosOperacional',
            pageBuilder: (context, state) => const NoTransitionPage(child: CadastroOperacionalIndexPage()),
            routes: [
              // Important: keep operational cadastros under this route so the
              // system back button returns to the operational index instead of
              // falling back to /cadastros (básico).
              GoRoute(
                path: ':entity',
                name: 'cadastrosOperacionalEntity',
                pageBuilder: (context, state) {
                  final entity = state.pathParameters['entity'] ?? '';
                  return NoTransitionPage(child: CadastroRouterPage(entity: entity));
                },
              ),
              GoRoute(
                path: ':entity/form',
                name: 'cadastrosOperacionalEntityForm',
                pageBuilder: (context, state) {
                  final entity = state.pathParameters['entity'] ?? '';
                  return NoTransitionPage(child: CadastroRouterPage(entity: entity, openForm: true));
                },
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.compras,
            name: 'compras',
            pageBuilder: (context, state) => const NoTransitionPage(child: ComprasRouterPage()),
            routes: [
              GoRoute(
                path: 'compra/:id',
                name: 'compraCascade',
                pageBuilder: (context, state) {
                  final raw = state.pathParameters['id'] ?? '';
                  final id = int.tryParse(raw);
                  return NoTransitionPage(child: CompraCascadePage(compraId: id));
                },
              ),
              GoRoute(
                path: ':entity',
                name: 'comprasEntity',
                pageBuilder: (context, state) {
                  final entity = state.pathParameters['entity'] ?? '';
                  return NoTransitionPage(child: ComprasRouterPage(entity: entity));
                },
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.estoqueProducao,
            name: 'estoqueProducao',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: PlaceholderPage(title: 'Estoque de Produção'),
            ),
          ),
          GoRoute(
            path: AppRoutes.estoqueProdutos,
            name: 'estoqueProdutos',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: PlaceholderPage(title: 'Estoque de Produtos'),
            ),
          ),
          GoRoute(
            path: AppRoutes.pedidos,
            name: 'pedidos',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: PlaceholderPage(title: 'Pedidos'),
            ),
          ),
          GoRoute(
            path: AppRoutes.pcp,
            name: 'pcp',
            pageBuilder: (context, state) => const NoTransitionPage(child: PlaceholderPage(title: 'PCP')),
          ),
          GoRoute(
            path: AppRoutes.vendas,
            name: 'vendas',
            pageBuilder: (context, state) => const NoTransitionPage(child: PlaceholderPage(title: 'Vendas')),
          ),
          GoRoute(
            path: AppRoutes.relatorios,
            name: 'relatorios',
            pageBuilder: (context, state) => const NoTransitionPage(child: PlaceholderPage(title: 'Relatórios')),
          ),
          GoRoute(
            path: AppRoutes.listas,
            name: 'listas',
            pageBuilder: (context, state) => const NoTransitionPage(child: ListasPage()),
            routes: [
              GoRoute(
                path: 'itens',
                name: 'listas_itens',
                pageBuilder: (context, state) => const NoTransitionPage(child: ItensTablePage()),
                routes: [
                  GoRoute(
                    path: ':id',
                    name: 'listas_itens_edit',
                    pageBuilder: (context, state) {
                      final raw = state.pathParameters['id'];
                      final id = int.tryParse(raw ?? '');
                      if (id == null) {
                        return const NoTransitionPage(child: PlaceholderPage(title: 'Item inválido'));
                      }
                      return NoTransitionPage(child: ItemEditPage(itemId: id, initialRow: state.extra as Map<String, dynamic>?));
                    },
                  ),
                ],
              ),
              GoRoute(
                path: 'precificacao-produtos',
                name: 'listas_precificacao_produtos',
                pageBuilder: (context, state) => const NoTransitionPage(child: PrecificacaoProdutosPage()),
                routes: [
                  GoRoute(
                    path: ':id/preco-venda',
                    name: 'listas_precificacao_preco_venda',
                    pageBuilder: (context, state) {
                      final raw = state.pathParameters['id'] ?? '';
                      final id = int.tryParse(raw);
                      final extra = state.extra;
                      if (id == null || extra is! Map) {
                        return const NoTransitionPage(child: PlaceholderPage(title: 'Produto inválido'));
                      }

                      double? readDouble(String key) {
                        final v = extra[key];
                        if (v == null) return null;
                        if (v is num) return v.toDouble();
                        if (v is String) return double.tryParse(v);
                        return null;
                      }

                      return NoTransitionPage(
                        child: PrecoVendaProdutoPage(
                          produtoId: id,
                          nome: (extra['nome'] ?? '').toString(),
                          percentualLucro: readDouble('percentualLucro') ?? 0.0,
                          custoProdUn: readDouble('custoProdUn') ?? 0.0,
                          despesaFixaUn: readDouble('despesaFixaUn') ?? 0.0,
                          despesaVarUn: readDouble('despesaVarUn') ?? 0.0,
                          valorVendaInicial: readDouble('valorVendaInicial'),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

/// Route path constants
/// Use these instead of hard-coding route strings
class AppRoutes {
  static const String home = '/';
  static const String login = '/login';
  static const String forcePasswordChange = '/force-password-change';

  static const String cadastros = '/cadastros';
  static const String cadastrosOperacional = '/cadastros-operacional';
  static const String compras = '/compras';
  static const String estoqueProducao = '/estoque-producao';
  static const String estoqueProdutos = '/estoque-produtos';
  static const String pedidos = '/pedidos';
  static const String pcp = '/pcp';
  static const String vendas = '/vendas';
  static const String relatorios = '/relatorios';
  static const String listas = '/listas';
  static const String listasItens = '/listas/itens';
  static const String listasPrecificacaoProdutos = '/listas/precificacao-produtos';
  static String listasItemEdit(int itemId) => '/listas/itens/$itemId';

  // Kept for backwards-compatibility with existing (currently unused) pages.
  static const String recipeDetail = '/recipes/:id';
  static String recipeDetails(int id) => '/recipes/$id';
}
