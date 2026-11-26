# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Visão geral

BakePro é um app Flutter (gerado originalmente no **Dreamflow**) de gestão para confeitarias/padarias: cadastros, receitas, custos, precificação, kits e compras. Backend é **Supabase** (Postgres via PostgREST). UI e domínio são em português (pt-BR) — nomes de tabelas, colunas, telas e comentários seguem esse padrão; mantenha-o.

O usuário conversa em português.

## Ambiente e comandos

- Flutter SDK em `C:\src\flutter` (stable, no PATH do usuário). Git em `C:\Program Files\Git\cmd`. Em shells abertos antes da instalação, prefixe o PATH: `$env:Path = "C:\src\flutter\bin;C:\Program Files\Git\cmd;" + $env:Path`.
- Plataforma de desenvolvimento: **web (Chrome)**. Não há Android SDK nem Visual Studio instalados.

```powershell
flutter pub get
flutter analyze                 # lint (flutter_lints); use para validar mudanças
flutter run -d chrome           # rodar o app (longo; execute em background)
flutter run -d chrome --dart-define=OPENAI_PROXY_API_KEY=... --dart-define=OPENAI_PROXY_ENDPOINT=...
```

Não existe pasta `test/` — não há testes automatizados. Valide com `flutter analyze` e rodando o app.

## Arquitetura

**Inicialização** — `main.dart` inicializa o Supabase (`lib/supabase/supabase_config.dart`, URL e anon key fixos no código) e fornece um único `AppSessionController` (Provider/ChangeNotifier) para o app inteiro.

**Sessão / autenticação** — `lib/services/state/app_session_controller.dart`. O login **não usa Supabase Auth**: consulta a tabela `usuario` por email e compara a coluna `senha` no cliente; o email fica em `shared_preferences`. `usuario.dataprimeiroacesso == null` força troca de senha. Perfis por `tipousuario`: `A` = administrador geral (`isSuperAdmin`, vê todas as empresas), `E` = admin da empresa (`isAdminEmpresa` cobre A e E).

**Multiempresa** — quase toda tabela tem `empresaid`. O filtro por empresa é aplicado **no cliente** (lista genérica e lookups de FK), exceto para super admin. Ao criar consultas novas, filtre por `session.empresaId` explicitamente.

**Navegação** — `lib/nav.dart` (go_router). `redirect` depende do estado da sessão (`refreshListenable: session`). Todas as telas autenticadas ficam sob um `ShellRoute` com `AppShell` (menu lateral em `lib/pages/shell/app_shell.dart`). Use as constantes de `AppRoutes`. Seções ainda não implementadas (Estoque, Pedidos, PCP, Vendas, Relatórios) apontam para `PlaceholderPage`.

**Cadastros genéricos (núcleo do app)** — `lib/pages/cadastros/cadastro_definitions.dart` declara cada entidade como `CadastroDefinition` (tabela, coluna id, colunas exibidas, campos, FKs, `scopedByEmpresa`, `visibleInMenu`). A partir disso:
- `GenericCadastroListPage` e `GenericCadastroFormSheet` montam lista e formulário de qualquer entidade. Esses arquivos são grandes e contêm muitas regras específicas por entidade (`if keyName == ...`) — procure lá antes de criar tela nova.
- `CadastroRouterPage` resolve `/cadastros/:entity` e aplica permissões por perfil; `CadastroOperacionalIndexPage` separa o menu "básico" do "operacional" por listas de `keyName`.
- `FkDeleteGuard` (`lib/services/fk_delete_guard.dart`) usa os metadados de FK das definições para bloquear exclusões referenciadas; filhos excluídos em cascata são listados em `_cascadeChildrenByKeyName`.
- `Cadastros.all` é um **getter** (não `const`/`static final`) de propósito, para o hot reload refletir mudanças de schema.

Para adicionar um cadastro simples: crie a `CadastroDefinition`, inclua o `keyName` no menu adequado e, se tiver FKs/filhos, revise `FkDeleteGuard`.

**Telas "cascade"** — entidades mestre‑detalhe têm páginas próprias: `produto` (+ `produtoreceita`, `ingrediente`, `material`), `kit` (+ `kitproduto`, `kitembalagem`), `compra` (+ `compraitem`, com importação de itens). Receitas reutilizam a lista genérica filtrada por `receitaid`.

**Acesso a dados** — `SupabaseService` (em `supabase_config.dart`) oferece `select/selectSingle/insert/update/delete` com filtros por igualdade; para joins/consultas complexas o código usa `SupabaseConfig.client.from(...)` diretamente. Services em `lib/services/` concentram cálculos (custos de receita, totais de kit, despesas). Precificação (`lib/pages/listas/precificacao/`) combina custo de produção, `despesafixa`, `despesavariavel` e `empresasetup` (imposto).

**Números** — valores podem vir como texto em formato pt-BR; use `parsePtBrNumber` de `lib/utils/number_parsing.dart` em vez de `double.parse`.

**Tema** — `lib/theme.dart` (Material 3, claro/escuro, `AppSpacing`, `AppRadius`, Google Fonts). Use esses tokens em vez de valores soltos.

**OpenAI** — `lib/openai/openai_config.dart` chama um proxy configurado via `--dart-define`; sem esses valores o restante do app funciona normalmente.

## Observações

- O schema do banco não está versionado no repositório. Ao precisar de tabela/coluna nova, escreva o SQL para o usuário executar no painel do Supabase; não presuma colunas que não aparecem no código.
- Se o projeto também for editado no Dreamflow, sincronize via git (commit/push) antes de trocar de ferramenta para evitar conflitos.
