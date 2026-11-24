class Receita {
  const Receita({
    required this.receitaId,
    required this.empresaId,
    required this.nome,
    this.descricao,
    required this.unidadeId,
    this.unidadeLabel,
    required this.qtdReceita,
    this.custoReceita,
    this.custoTotalIngredientes,
    this.custoTotalMateriais,
    required this.status,
  });

  final int receitaId;
  final int empresaId;
  final String nome;
  final String? descricao;
  final int qtdReceita;
  final int unidadeId;

  /// Human-friendly label (from join with table `unidade`).
  /// Not persisted back to the DB.
  final String? unidadeLabel;

  final num? custoReceita;

  /// Transient (computed client-side) totals for list UI.
  /// Not persisted directly from this model.
  final num? custoTotalIngredientes;
  final num? custoTotalMateriais;
  final String status;

  factory Receita.fromJson(Map<String, dynamic> json) => Receita(
    receitaId: (json['receitaid'] as num).toInt(),
    empresaId: (json['empresaid'] as num).toInt(),
    nome: (json['nome'] as String?) ?? '',
    descricao: json['descricao'] as String?,
    qtdReceita: (json['qtdreceita'] as num?)?.toInt() ?? 0,
    custoReceita: json['custoreceita'] as num?,
    custoTotalIngredientes: json['custototalingrediente'] as num?,
    custoTotalMateriais: json['custototalmaterial'] as num?,
    status: (json['status'] as String?) ?? 'A',
    unidadeId: (json['unidadeid'] as num?)?.toInt() ?? 0,
    unidadeLabel: _parseUnidadeLabel(json),
  );

  static String? _parseUnidadeLabel(Map<String, dynamic> json) {
    // New schema: unidadeid is a FK. When joined, it comes as `unidade:unidadeid(unidade)`.
    final u = json['unidade'];
    if (u is Map) {
      final label = u['unidade']?.toString().trim();
      if (label != null && label.isNotEmpty) return label;
    }
    // Backward compatibility (older schema used a plain `unidade` text column).
    final legacy = json['unidade']?.toString().trim();
    if (legacy != null && legacy.isNotEmpty) return legacy;
    return null;
  }

  Map<String, dynamic> toJson() => {
    'receitaid': receitaId,
    'empresaid': empresaId,
    'nome': nome,
    'descricao': descricao,
    'qtdreceita': qtdReceita,
    'status': status,
    'custoreceita': custoReceita,
    'unidadeid': unidadeId,
  };

  Receita copyWith({
    int? receitaId,
    int? empresaId,
    String? nome,
    String? descricao,
    int? qtdReceita,
    int? unidadeId,
    String? unidadeLabel,
    num? custoReceita,
    num? custoTotalIngredientes,
    num? custoTotalMateriais,
    String? status,
  }) => Receita(
    receitaId: receitaId ?? this.receitaId,
    empresaId: empresaId ?? this.empresaId,
    nome: nome ?? this.nome,
    descricao: descricao ?? this.descricao,
    qtdReceita: qtdReceita ?? this.qtdReceita,
    custoReceita: custoReceita ?? this.custoReceita,
    status: status ?? this.status,
    unidadeId: unidadeId ?? this.unidadeId,
    unidadeLabel: unidadeLabel ?? this.unidadeLabel,
    custoTotalIngredientes: custoTotalIngredientes ?? this.custoTotalIngredientes,
    custoTotalMateriais: custoTotalMateriais ?? this.custoTotalMateriais,
  );
}
