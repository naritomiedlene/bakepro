/// Tamanho máximo das colunas `varchar` do banco (Supabase), por tabela.
///
/// Os formulários usam estes valores para limitar a digitação e mostrar o
/// contador (ex.: 7/10), evitando o erro "value too long for type character
/// varying(n)" ao salvar.
///
/// Espelha o schema; ao criar/alterar uma coluna varchar no Supabase,
/// atualize aqui. Consulta para conferir:
///   select table_name, column_name, character_maximum_length
///   from information_schema.columns
///   where table_schema = 'public' and data_type = 'character varying'
///     and character_maximum_length is not null
///   order by table_name, column_name;
const Map<String, Map<String, int>> dbColumnMaxLengths = {
  'adquirente': {'nome': 12},
  'categoria': {'nome': 50},
  'classificacaokit': {'nome': 25},
  'cliente': {
    'cel': 12,
    'cep': 10,
    'cidade': 50,
    'cnpj': 25,
    'cpf': 15,
    'email': 50,
    'logradouro': 50,
    'logradourocomplemento': 20,
    'logradouronumero': 10,
    'nome': 50,
    'nomecontato': 20,
    'sobrenomecontato': 30,
  },
  'compra': {'numeronf': 35},
  'delivery': {'nome': 12},
  'despesafixa': {'nome': 30},
  'empresa': {
    'celular': 20,
    'cidade': 50,
    'cnpj': 25,
    'cpf': 15,
    'email': 50,
    'endereco': 70,
    'nomefantasia': 30,
    'razaosocial': 70,
  },
  'fornecedor': {
    'cnpj': 30,
    'cpf': 15,
    'nomefantasia': 30,
    'razaosocial': 50,
    'urlfornecedor': 100,
  },
  'item': {'nome': 50, 'obs': 500},
  'kit': {'descricao': 500, 'nome': 50},
  'marca': {'nome': 30},
  'movestoqueprod': {'observacao': 100},
  'produto': {'codigo': 10, 'descricao': 500, 'nome': 50},
  'receita': {'descricao': 500, 'nome': 60},
  'tipoitem': {'nome': 30},
  'uf': {'nome': 50},
  'unidade': {'unidade': 10},
  'usuario': {'email': 40, 'nome': 25, 'senha': 20, 'sobrenome': 30},
};

/// Limite da coluna [column] da tabela [table], ou null se não houver.
int? dbColumnMaxLength(String table, String column) => dbColumnMaxLengths[table]?[column.toLowerCase()];
