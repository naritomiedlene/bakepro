class Item {
  const Item({
    required this.itemId,
    required this.empresaId,
    required this.nome,
    this.custoUnitario,
    this.custoUnitarioInicial,
  });

  final int itemId;
  final int empresaId;
  final String nome;
  final num? custoUnitario;
  final num? custoUnitarioInicial;

  factory Item.fromJson(Map<String, dynamic> json) => Item(
    itemId: (json['itemid'] as num).toInt(),
    empresaId: (json['empresaid'] as num?)?.toInt() ?? 0,
    nome: (json['nome'] as String?) ?? '',
    // New column name: `custounitario`.
    // Backward compatibility: accept legacy `custounitariounidade` if still present in older payloads.
    custoUnitario: (json['custounitario'] as num?) ?? (json['custounitariounidade'] as num?),
    custoUnitarioInicial: (json['custounitarioinicial'] as num?),
  );

  Map<String, dynamic> toJson() => {
    'itemid': itemId,
    'empresaid': empresaId,
    'nome': nome,
    'custounitario': custoUnitario,
    'custounitarioinicial': custoUnitarioInicial,
  };

  Item copyWith({
    int? itemId,
    int? empresaId,
    String? nome,
    num? custoUnitario,
    num? custoUnitarioInicial,
  }) => Item(
    itemId: itemId ?? this.itemId,
    empresaId: empresaId ?? this.empresaId,
    nome: nome ?? this.nome,
    custoUnitario: custoUnitario ?? this.custoUnitario,
    custoUnitarioInicial: custoUnitarioInicial ?? this.custoUnitarioInicial,
  );
}
