import 'package:flutter/material.dart';

enum CadastroFieldType { text, number, option }

class CadastroOption {
  const CadastroOption({required this.value, required this.label});
  final String value;
  final String label;
}

class CadastroForeignKey {
  const CadastroForeignKey({
    required this.table,
    required this.idColumn,
    required this.labelColumn,
    this.scopedByEmpresa = true,
  });

  final String table;
  final String idColumn;
  final String labelColumn;
  final bool scopedByEmpresa;
}

class CadastroField {
  const CadastroField({
    required this.column,
    required this.label,
    required this.type,
    this.required = false,
    this.fk,
    this.options,
  });

  final String column;
  final String label;
  final CadastroFieldType type;
  final bool required;
  final CadastroForeignKey? fk;
  final List<CadastroOption>? options;
}

class CadastroDefinition {
  const CadastroDefinition({
    required this.keyName,
    required this.title,
    required this.table,
    required this.idColumn,
    required this.displayColumns,
    required this.fields,
    required this.scopedByEmpresa,
    this.createdAtColumn,
    this.updatedAtColumn,
    this.visibleInMenu = true,
  });

  final String keyName;
  final String title;
  final String table;
  final String idColumn;
  final List<String> displayColumns;
  final List<CadastroField> fields;
  final bool scopedByEmpresa;
  final String? createdAtColumn;
  final String? updatedAtColumn;
  final bool visibleInMenu;
}

class Cadastros {
  // IMPORTANT:
  // Do NOT keep these definitions as a const list.
  // In Flutter, changes inside const graphs may not reflect with hot reload
  // (e.g. switching a field from optional to required), which can cause the
  // running app to keep old validation rules until a hot restart.
  // Using a runtime-initialized list makes hot reload consistently reflect
  // schema/validation tweaks.
  /// IMPORTANT:
  /// Keep this as a getter (not a `static final` field).
  ///
  /// Reason: during hot reload, Dart does NOT re-run static field initializers.
  /// If we keep the definitions in a `static final`, the running app may keep an
  /// old in-memory version of the schema (e.g. a field that was changed from
  /// optional -> required), and validation will be wrong until a hot restart.
  ///
  /// With a getter, the list is rebuilt whenever accessed, so hot reload picks
  /// up schema/validation tweaks immediately.
  static List<CadastroDefinition> get all => [
    CadastroDefinition(
      keyName: 'empresa',
      title: 'Empresa',
      table: 'empresa',
      idColumn: 'empresaid',
      // Empresa é a entidade raiz; não deve ser automaticamente filtrada por empresa.
      // O filtro (quando necessário) é aplicado na lista conforme o perfil do usuário.
      scopedByEmpresa: false,
      displayColumns: ['nomefantasia', 'razaosocial', 'cnpj', 'cpf', 'status'],
      fields: [
        CadastroField(
          column: 'tipodocumento',
          label: 'Tipo de Pessoa',
          type: CadastroFieldType.option,
          required: true,
          options: [
            CadastroOption(value: 'J', label: 'Jurídica'),
            CadastroOption(value: 'F', label: 'Física'),
          ],
        ),
        CadastroField(column: 'nomefantasia', label: 'Nome fantasia', type: CadastroFieldType.text, required: true),
        // Razão social pode ser nula no BD.
        CadastroField(column: 'razaosocial', label: 'Razão social', type: CadastroFieldType.text, required: false),
        // Obrigatoriedade de CNPJ/CPF é condicional (controlada no formulário):
        // - tipodocumento = 'J' => CNPJ obrigatório
        // - tipodocumento = 'F' => CPF obrigatório
        CadastroField(column: 'cnpj', label: 'CNPJ', type: CadastroFieldType.text),
        CadastroField(column: 'cpf', label: 'CPF', type: CadastroFieldType.text),
        // NOT NULL no BD
        CadastroField(column: 'endereco', label: 'Endereço', type: CadastroFieldType.text, required: true),
        // NOT NULL no BD
        CadastroField(column: 'cidade', label: 'Cidade', type: CadastroFieldType.text, required: true),
        CadastroField(
          column: 'ufid',
          label: 'UF',
          type: CadastroFieldType.number,
          // NOT NULL no BD
          required: true,
          fk: CadastroForeignKey(table: 'uf', idColumn: 'ufid', labelColumn: 'sigla', scopedByEmpresa: false),
        ),
        CadastroField(column: 'email', label: 'Email', type: CadastroFieldType.text),
        // Postgres folds unquoted identifiers to lowercase; the column in Supabase is `dddcelular`.
        CadastroField(column: 'dddcelular', label: 'DDD', type: CadastroFieldType.text),
        CadastroField(column: 'celular', label: 'Número', type: CadastroFieldType.text),
        CadastroField(column: 'status', label: 'Status (A/I)', type: CadastroFieldType.text, required: true),
      ],
    ),

    // Compras
    CadastroDefinition(
      keyName: 'fornecedor',
      title: 'Fornecedor',
      table: 'fornecedor',
      idColumn: 'fornecedorid',
      scopedByEmpresa: true,
      // Este cadastro aparece no menu de Compras (não no menu de Cadastros).
      visibleInMenu: false,
      displayColumns: ['nomefantasia', 'razaosocial', 'cnpj', 'cpf', 'status'],
      fields: [
        CadastroField(
          column: 'tipodocumento',
          label: 'Tipo de pessoa',
          type: CadastroFieldType.option,
          required: true,
          options: [
            CadastroOption(value: 'J', label: 'Jurídica'),
            CadastroOption(value: 'F', label: 'Física'),
          ],
        ),
        CadastroField(column: 'nomefantasia', label: 'Nome fantasia', type: CadastroFieldType.text, required: true),
        // Razão social pode ser nula no BD.
        CadastroField(column: 'razaosocial', label: 'Razão social', type: CadastroFieldType.text, required: false),
        // Obrigatoriedade de CNPJ/CPF é condicional (controlada no formulário):
        // - tipodocumento = 'J' => CNPJ obrigatório
        // - tipodocumento = 'F' => CPF obrigatório
        CadastroField(column: 'cnpj', label: 'CNPJ', type: CadastroFieldType.text),
        CadastroField(column: 'cpf', label: 'CPF', type: CadastroFieldType.text),
        CadastroField(column: 'site', label: 'Site', type: CadastroFieldType.text),
        // Na criação o status é forçado para 'A' e oculto; na edição é exibido.
        CadastroField(column: 'status', label: 'Status (A/I)', type: CadastroFieldType.text, required: true),
      ],
    ),

    CadastroDefinition(
      keyName: 'compra',
      title: 'Compra',
      table: 'compra',
      idColumn: 'compraid',
      scopedByEmpresa: true,
      // Este cadastro aparece no menu de Compras (não no menu de Cadastros).
      visibleInMenu: false,
      displayColumns: ['datacompra', 'fornecedorid', 'valorcompra'],
      fields: [
        CadastroField(
          column: 'fornecedorid',
          label: 'Fornecedor',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'fornecedor', idColumn: 'fornecedorid', labelColumn: 'nomefantasia', scopedByEmpresa: true),
        ),
        CadastroField(column: 'numeronf', label: 'Nota Fiscal', type: CadastroFieldType.text, required: true),
        // UI usa máscara dd/MM/aaaa; o formulário converte para ISO (yyyy-MM-dd) ao salvar.
        CadastroField(column: 'datacompra', label: 'Data da compra', type: CadastroFieldType.text, required: true),
        // UI usa máscara 99.999,99 (pt-BR)
        CadastroField(column: 'valorcompra', label: 'Valor da compra', type: CadastroFieldType.number, required: true),
      ],
    ),

    CadastroDefinition(
      keyName: 'compraitem',
      title: 'Item da Compra',
      table: 'compraitem',
      idColumn: 'compraitemid',
      scopedByEmpresa: true,
      visibleInMenu: false,
      displayColumns: ['itemid', 'quantidade', 'valorunitario', 'datavalidade'],
      fields: [
        CadastroField(
          column: 'compraid',
          label: 'Compra',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'compra', idColumn: 'compraid', labelColumn: 'compraid', scopedByEmpresa: true),
        ),
        CadastroField(
          column: 'itemid',
          label: 'Item',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'item', idColumn: 'itemid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(column: 'quantidade', label: 'Quantidade', type: CadastroFieldType.number, required: true),
        CadastroField(column: 'valorunitario', label: 'Valor unitário', type: CadastroFieldType.number, required: true),
        // UI usa máscara dd/MM/aaaa; o formulário converte para ISO (yyyy-MM-dd) ao salvar.
        CadastroField(column: 'datavalidade', label: 'Data de validade', type: CadastroFieldType.text),
      ],
    ),
    CadastroDefinition(
      keyName: 'usuario',
      title: 'Usuário',
      table: 'usuario',
      idColumn: 'usuarioid',
      scopedByEmpresa: true,
      displayColumns: ['nome', 'sobrenome', 'email', 'status'],
      fields: [
        CadastroField(
          column: 'empresaid',
          label: 'Empresa',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'empresa', idColumn: 'empresaid', labelColumn: 'nomefantasia', scopedByEmpresa: false),
        ),
        CadastroField(column: 'nome', label: 'Nome', type: CadastroFieldType.text, required: true),
        CadastroField(column: 'sobrenome', label: 'Sobrenome', type: CadastroFieldType.text, required: true),
        CadastroField(column: 'email', label: 'Email', type: CadastroFieldType.text, required: true),
        // NOT NULL no BD. Na edição, o campo fica opcional (preencher = alterar a senha).
        CadastroField(column: 'senha', label: 'Senha', type: CadastroFieldType.text, required: true),
        CadastroField(column: 'tipousuario', label: 'Tipo de usuário', type: CadastroFieldType.text, required: true),
        CadastroField(column: 'status', label: 'Status (A/I)', type: CadastroFieldType.text, required: true),
      ],
    ),
    CadastroDefinition(
      keyName: 'marca',
      title: 'Marca',
      table: 'marca',
      idColumn: 'marcaid',
      scopedByEmpresa: true,
      displayColumns: ['nome'],
      fields: [
        CadastroField(column: 'nome', label: 'Nome', type: CadastroFieldType.text, required: true),
      ],
    ),
    CadastroDefinition(
      keyName: 'tipoitem',
      title: 'Tipo de Item',
      table: 'tipoitem',
      idColumn: 'tipoitemid',
      // Tabela interna (sem filtro por empresa).
      scopedByEmpresa: false,
      visibleInMenu: false,
      displayColumns: ['nome'],
      fields: [
        CadastroField(column: 'nome', label: 'Nome', type: CadastroFieldType.text, required: true),
      ],
    ),
    CadastroDefinition(
      keyName: 'unidade',
      title: 'Unidade',
      table: 'unidade',
      idColumn: 'unidadeid',
      // Tabela interna (sem filtro por empresa).
      scopedByEmpresa: false,
      // Exposto no menu de Cadastros para permitir manutenção das unidades.
      visibleInMenu: true,
      displayColumns: ['unidade'],
      fields: [
        CadastroField(column: 'unidade', label: 'Unidade', type: CadastroFieldType.text, required: true),
      ],
    ),
    CadastroDefinition(
      keyName: 'uf',
      title: 'UF',
      table: 'uf',
      idColumn: 'ufid',
      scopedByEmpresa: false,
      visibleInMenu: false,
      displayColumns: ['sigla'],
      fields: [
        CadastroField(column: 'sigla', label: 'Sigla', type: CadastroFieldType.text, required: true),
        // NOT NULL no BD
        CadastroField(column: 'nome', label: 'Nome', type: CadastroFieldType.text, required: true),
      ],
    ),

    CadastroDefinition(
      keyName: 'delivery',
      title: 'Delivery',
      table: 'delivery',
      idColumn: 'deliveryid',
      scopedByEmpresa: false,
      visibleInMenu: true,
      displayColumns: ['nome', 'status'],
      fields: [
        CadastroField(column: 'nome', label: 'Nome', type: CadastroFieldType.text, required: true),
        CadastroField(
          column: 'status',
          label: 'Status',
          type: CadastroFieldType.option,
          required: true,
          options: [
            CadastroOption(value: 'A', label: 'Ativo'),
            CadastroOption(value: 'I', label: 'Inativo'),
          ],
        ),
      ],
    ),

    // Vincula qual serviço de delivery uma empresa utiliza.
    // OBS: o acesso a este cadastro é restrito no router/menu (somente tipo 'A').
    CadastroDefinition(
      keyName: 'empresadelivery',
      title: 'Delivery da Empresa',
      table: 'empresadelivery',
      idColumn: 'empresadeliveryid',
      // Este cadastro deve permitir ver/configurar associações de múltiplas empresas.
      // Então não aplicamos filtro automático por empresa.
      scopedByEmpresa: false,
      visibleInMenu: true,
      displayColumns: ['empresaid', 'deliveryid', 'taxadelivery', 'status'],
      fields: [
        CadastroField(
          column: 'empresaid',
          label: 'Empresa',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'empresa', idColumn: 'empresaid', labelColumn: 'nomefantasia', scopedByEmpresa: false),
        ),
        CadastroField(
          column: 'deliveryid',
          label: 'Delivery',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'delivery', idColumn: 'deliveryid', labelColumn: 'nome', scopedByEmpresa: false),
        ),
        CadastroField(
          column: 'taxadelivery',
          label: 'Taxa delivery (%)',
          type: CadastroFieldType.number,
          required: true,
        ),
        CadastroField(
          column: 'status',
          label: 'Status',
          type: CadastroFieldType.option,
          required: true,
          options: [
            CadastroOption(value: 'A', label: 'Ativo'),
            CadastroOption(value: 'I', label: 'Inativo'),
          ],
        ),
      ],
    ),
    // Imposto e taxas por empresa (tabela `empresasetup`, um registro por empresa).
    // OBS: acesso no router/menu para tipos A e E; tipo E só vê/edita a própria empresa.
    CadastroDefinition(
      keyName: 'empresataxas',
      title: 'Imposto e taxas da empresa',
      table: 'empresasetup',
      idColumn: 'empresasetupid',
      // Admin geral (A) gerencia várias empresas; o filtro por empresa para tipo E é aplicado na lista.
      scopedByEmpresa: false,
      visibleInMenu: true,
      displayColumns: ['empresaid', 'imposto', 'taxaadm', 'taxamotoboy'],
      fields: [
        CadastroField(
          column: 'empresaid',
          label: 'Empresa',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'empresa', idColumn: 'empresaid', labelColumn: 'nomefantasia', scopedByEmpresa: false),
        ),
        CadastroField(column: 'imposto', label: 'Imposto de renda (%)', type: CadastroFieldType.number, required: true),
        CadastroField(column: 'taxaadm', label: 'Taxa administrativa (%)', type: CadastroFieldType.number, required: true),
        CadastroField(column: 'taxamotoboy', label: 'Taxa motoboy', type: CadastroFieldType.number),
      ],
    ),
    CadastroDefinition(
      keyName: 'item',
      title: 'Item',
      table: 'item',
      idColumn: 'itemid',
      scopedByEmpresa: true,
      updatedAtColumn: 'dataatualizacao',
      displayColumns: ['nome', 'tipoitemid', 'marcaid', 'unidadeid'],
      fields: [
        CadastroField(column: 'nome', label: 'Nome', type: CadastroFieldType.text, required: true),
        CadastroField(
          column: 'tipoitemid',
          label: 'Tipo de Item',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'tipoitem', idColumn: 'tipoitemid', labelColumn: 'nome', scopedByEmpresa: false),
        ),
        CadastroField(
          column: 'marcaid',
          label: 'Marca',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'marca', idColumn: 'marcaid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(
          column: 'unidadeid',
          label: 'Unidade',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'unidade', idColumn: 'unidadeid', labelColumn: 'unidade', scopedByEmpresa: false),
        ),
        // Schema update (Supabase): added `custounitarioinicial`
        // NOT NULL no BD (default 0)
        CadastroField(column: 'custounitarioinicial', label: 'Custo unitário inicial', type: CadastroFieldType.number, required: true),

        // Column used in multiple screens (lists/imports). Keep it editable so
        // changes persist to the database.
        CadastroField(column: 'custounitario', label: 'Custo unitário', type: CadastroFieldType.number, required: false),
      ],
    ),
    CadastroDefinition(
      keyName: 'rateiodespesa',
      title: 'Despesas Fixas',
      // IMPORTANT: A despesa fixa é registrada na tabela `despesafixa`.
      // A tabela legada `rateiodespesa` foi removida do Supabase.
      table: 'despesafixa',
      idColumn: 'despesafixaid',
      scopedByEmpresa: true,
      updatedAtColumn: 'dataatualizacao',
      displayColumns: ['nome'],
      fields: [
        CadastroField(column: 'nome', label: 'Nome', type: CadastroFieldType.text, required: true),
        CadastroField(column: 'valormensal', label: 'Valor mensal (R\$)', type: CadastroFieldType.number, required: true),
        CadastroField(column: 'dataatualizacao', label: 'Data de atualização', type: CadastroFieldType.text, required: false),
        // Somente despesas ativas entram no total de despesas fixas.
        CadastroField(
          column: 'status',
          label: 'Status',
          type: CadastroFieldType.option,
          required: true,
          options: [
            CadastroOption(value: 'A', label: 'Ativo'),
            CadastroOption(value: 'I', label: 'Inativo'),
          ],
        ),
      ],
    ),

    CadastroDefinition(
      keyName: 'despesavariavel',
      title: 'Despesas Variáveis',
      table: 'despesavariavel',
      idColumn: 'despesavariavelid',
      scopedByEmpresa: true,
      updatedAtColumn: 'dataatualizacao',
      // A tabela `despesavariavel` não tem coluna `nome`.
      // O título da lista é derivado do join com `item`.
      displayColumns: ['status'],
      fields: [
        // UI: o nome passa a ser derivado do Item selecionado.
        CadastroField(
          column: 'itemid',
          label: 'Item',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'item', idColumn: 'itemid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(column: 'consumomensal', label: 'Consumo mensal', type: CadastroFieldType.number, required: true),
        // Campo calculado no app: Consumo mensal * custo unitário do Item.
        // Coluna no BD: `valormensal`.
        CadastroField(column: 'valormensal', label: 'Valor mensal (R\$)', type: CadastroFieldType.number, required: true),
        CadastroField(column: 'dataatualizacao', label: 'Data de atualização', type: CadastroFieldType.text, required: false),
        CadastroField(
          column: 'status',
          label: 'Status',
          type: CadastroFieldType.option,
          required: true,
          options: [
            CadastroOption(value: 'A', label: 'Ativo'),
            CadastroOption(value: 'I', label: 'Inativo'),
          ],
        ),
      ],
    ),

    // Registro único (por empresa) com parâmetros globais do sistema.
    CadastroDefinition(
      keyName: 'setup',
      title: 'Setup',
      table: 'empresasetup',
      // Observação: o fluxo de UI não usa lista nem exclusão; a tela de Setup
      // faz upsert/atualização usando as chaves disponíveis.
      idColumn: 'empresasetupid',
      scopedByEmpresa: true,
      visibleInMenu: true,
      displayColumns: ['taxaadm', 'imposto'],
      fields: [
        CadastroField(column: 'taxaadm', label: 'Taxa administrativo (%)', type: CadastroFieldType.number, required: true),
        CadastroField(column: 'imposto', label: 'Imposto de renda (%)', type: CadastroFieldType.number, required: true),
      ],
    ),

    CadastroDefinition(
      keyName: 'categoria',
      title: 'Categoria de Produto',
      table: 'categoria',
      idColumn: 'categoriaid',
      // Categorias são específicas por empresa: ao salvar, o app injeta o
      // `empresaid` automaticamente a partir do usuário logado.
      scopedByEmpresa: true,
      displayColumns: ['nome', 'quantidadeproducaomes', 'percentualrateiodespesa', 'percentuallucro'],
      fields: [
        CadastroField(column: 'nome', label: 'Nome', type: CadastroFieldType.text, required: true),
        CadastroField(column: 'quantidadeproducaomes', label: 'Quantidade produção / mês', type: CadastroFieldType.number, required: true),
        CadastroField(column: 'percentualrateiodespesa', label: 'Rateio despesa (%)', type: CadastroFieldType.number, required: true),
        CadastroField(column: 'percentuallucro', label: 'Lucro (%)', type: CadastroFieldType.number, required: true),
      ],
    ),
    CadastroDefinition(
      keyName: 'produto',
      title: 'Produto',
      table: 'produto',
      idColumn: 'produtoid',
      scopedByEmpresa: true,
      displayColumns: ['codigo', 'nome', 'status'],
      fields: [
        CadastroField(column: 'codigo', label: 'Código', type: CadastroFieldType.text, required: true),
        CadastroField(column: 'nome', label: 'Nome', type: CadastroFieldType.text, required: true),
        CadastroField(
          column: 'categoriaid',
          label: 'Categoria de Produto',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'categoria', idColumn: 'categoriaid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(column: 'descricao', label: 'Descrição', type: CadastroFieldType.text),
        // Schema update (Supabase):
        // - qteproduzida -> qtdestoque
        // - estoqueminimodelivery -> estoqueminimo
        // - removed: diaproducao, deliveryflag, rateiodespesaid, valordespesarateada
        // Schema update (Supabase): added `qtdestoqueinicial`
        // NOT NULL no BD (default 0)
        CadastroField(column: 'qtdestoqueinicial', label: 'Qtde de estoque inicial', type: CadastroFieldType.number, required: true),
        // Quantidade produzida usada no rateio/cálculos de receita.
        // NOT NULL no BD (default 0)
        CadastroField(column: 'qtdproduzida', label: 'Qtde produzida na receita', type: CadastroFieldType.number, required: true),
        // NOT NULL no BD
        CadastroField(column: 'estoqueminimo', label: 'Estoque mínimo', type: CadastroFieldType.number, required: true),
        CadastroField(column: 'valorvenda', label: 'Valor venda', type: CadastroFieldType.number),
        CadastroField(column: 'status', label: 'Status (A/I)', type: CadastroFieldType.text, required: true),
      ],
    ),

    CadastroDefinition(
      keyName: 'kit',
      title: 'Kit',
      table: 'kit',
      idColumn: 'kitid',
      scopedByEmpresa: true,
      displayColumns: ['nome', 'status'],
      fields: [
        CadastroField(column: 'nome', label: 'Nome', type: CadastroFieldType.text, required: true),
        CadastroField(column: 'descricao', label: 'Descrição', type: CadastroFieldType.text, required: true),
        // Opcional: kits antigos não têm classificação.
        CadastroField(
          column: 'classificacaokitid',
          label: 'Classificação',
          type: CadastroFieldType.number,
          fk: CadastroForeignKey(table: 'classificacaokit', idColumn: 'classificacaokitid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(column: 'status', label: 'Status (A/I)', type: CadastroFieldType.text, required: true),
      ],
    ),

    // Classificações de kit (várias por empresa, sempre da empresa logada).
    CadastroDefinition(
      keyName: 'classificacaokit',
      title: 'Classificação de Kit',
      table: 'classificacaokit',
      idColumn: 'classificacaokitid',
      scopedByEmpresa: true,
      displayColumns: ['nome', 'status'],
      fields: [
        CadastroField(column: 'nome', label: 'Nome', type: CadastroFieldType.text, required: true),
        CadastroField(
          column: 'status',
          label: 'Status',
          type: CadastroFieldType.option,
          required: true,
          options: [
            CadastroOption(value: 'A', label: 'Ativo'),
            CadastroOption(value: 'I', label: 'Inativo'),
          ],
        ),
      ],
    ),

    CadastroDefinition(
      keyName: 'kitproduto',
      title: 'Kit Produto',
      table: 'kitproduto',
      idColumn: 'kitprodutoid',
      scopedByEmpresa: false,
      visibleInMenu: false,
      displayColumns: ['kitid', 'produtoid', 'quantidade'],
      fields: [
        CadastroField(column: 'kitid', label: 'Kit', type: CadastroFieldType.number, required: true),
        CadastroField(
          column: 'produtoid',
          label: 'Produto',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'produto', idColumn: 'produtoid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(column: 'quantidade', label: 'Quantidade', type: CadastroFieldType.number, required: true),
      ],
    ),

    CadastroDefinition(
      keyName: 'kitembalagem',
      title: 'Kit Embalagem',
      table: 'kitembalagem',
      idColumn: 'kitembalagemid',
      scopedByEmpresa: false,
      visibleInMenu: false,
      displayColumns: ['kitid', 'itemid', 'quantidade'],
      fields: [
        CadastroField(column: 'kitid', label: 'Kit', type: CadastroFieldType.number, required: true),
        CadastroField(
          column: 'itemid',
          label: 'Embalagem',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'item', idColumn: 'itemid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(column: 'quantidade', label: 'Quantidade', type: CadastroFieldType.number, required: true),
      ],
    ),
    CadastroDefinition(
      keyName: 'produtoreceita',
      title: 'Produto Receita',
      table: 'produtoreceita',
      idColumn: 'produtoreceitaid',
      scopedByEmpresa: false,
      visibleInMenu: false,
      displayColumns: ['produtoid', 'receitaid', 'quantidadereceita'],
      fields: [
        CadastroField(
          column: 'produtoid',
          label: 'Produto',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'produto', idColumn: 'produtoid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(
          column: 'receitaid',
          label: 'Receita',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'receita', idColumn: 'receitaid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(column: 'quantidadereceita', label: 'Quantidade da receita utilizada no produto', type: CadastroFieldType.number, required: true),
      ],
    ),
    CadastroDefinition(
      keyName: 'receita',
      title: 'Receita',
      table: 'receita',
      idColumn: 'receitaid',
      scopedByEmpresa: true,
      displayColumns: ['nome', 'unidadeid', 'status'],
      fields: [
        CadastroField(column: 'nome', label: 'Nome', type: CadastroFieldType.text, required: true),
        CadastroField(column: 'descricao', label: 'Descrição', type: CadastroFieldType.text),
        CadastroField(
          column: 'unidadeid',
          label: 'Unidade',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'unidade', idColumn: 'unidadeid', labelColumn: 'unidade', scopedByEmpresa: false),
        ),
        // NOT NULL no BD
        CadastroField(column: 'qtdreceita', label: 'Qtd receita', type: CadastroFieldType.number, required: true),
        CadastroField(column: 'status', label: 'Status (A/I)', type: CadastroFieldType.text, required: true),
      ],
    ),
    CadastroDefinition(
      keyName: 'material',
      title: 'Material de preparo',
      table: 'material',
      idColumn: 'materialid',
      scopedByEmpresa: false,
      visibleInMenu: false,
      displayColumns: ['quantidade'],
      fields: [
        CadastroField(
          column: 'receitaid',
          label: 'Receita',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'receita', idColumn: 'receitaid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(
          column: 'itemid',
          label: 'Item',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'item', idColumn: 'itemid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(column: 'quantidade', label: 'Quantidade em unidade', type: CadastroFieldType.number, required: true),
      ],
    ),
    CadastroDefinition(
      keyName: 'ingrediente',
      title: 'Ingredientes',
      table: 'ingrediente',
      idColumn: 'ingredienteid',
      // IMPORTANT: ingrediente does NOT have `empresaid` column.
      // It is scoped indirectly through `receitaid` (and its receita.empresaid).
      scopedByEmpresa: false,
      visibleInMenu: false,
      displayColumns: ['quantidadegrama'],
      fields: [
        CadastroField(
          column: 'receitaid',
          label: 'Receita',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'receita', idColumn: 'receitaid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(
          column: 'itemid',
          label: 'Item',
          type: CadastroFieldType.number,
          required: true,
          fk: CadastroForeignKey(table: 'item', idColumn: 'itemid', labelColumn: 'nome', scopedByEmpresa: true),
        ),
        CadastroField(column: 'quantidadegrama', label: 'Quantidade em gramas', type: CadastroFieldType.number, required: true),
      ],
    ),
  ];

  static const Map<String, IconData> icons = {
    'empresa': Icons.apartment_rounded,
    'usuario': Icons.people_alt_rounded,
    'marca': Icons.sell_rounded,
    'tipoitem': Icons.category_rounded,
    'unidade': Icons.straighten_rounded,
    'uf': Icons.map_rounded,
    'item': Icons.inventory_2_rounded,
    'rateiodespesa': Icons.account_balance_wallet_rounded,
    'despesavariavel': Icons.payments_rounded,
    'setup': Icons.settings_rounded,
    'categoria': Icons.category_outlined,
    'produto': Icons.local_offer_rounded,
    'kit': Icons.card_giftcard_rounded,
    'classificacaokit': Icons.label_rounded,
    'produtoreceita': Icons.link_rounded,
    'receita': Icons.receipt_long_rounded,
    'material': Icons.all_inbox_rounded,
    'ingrediente': Icons.science_rounded,
    'fornecedor': Icons.local_shipping_rounded,
    'delivery': Icons.delivery_dining_rounded,
    'empresadelivery': Icons.handshake_rounded,
    'empresataxas': Icons.request_quote_rounded,
  };

  static CadastroDefinition? byKey(String key) {
    for (final c in all) {
      if (c.keyName == key) return c;
    }
    return null;
  }

  static CadastroDefinition? byTable(String table) {
    for (final c in all) {
      if (c.table == table) return c;
    }
    return null;
  }
}
