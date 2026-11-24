import 'package:bakepro/models/item.dart';

class Ingrediente {
  const Ingrediente({
    required this.ingredienteId,
    required this.receitaId,
    required this.itemId,
    required this.quantidadeGrama,
    this.custoIngrediente,
    this.item,
  });

  final int ingredienteId;
  final int receitaId;
  final int itemId;
  final num quantidadeGrama;

  /// Optional cost override stored in ingrediente.custoingrediente.
  ///
  /// This is separate from item.custounitario, and can be used when the same
  /// item has different costs depending on the recipe/usage context.
  final num? custoIngrediente;

  /// Optional embedded item when using PostgREST joins.
  final Item? item;

  factory Ingrediente.fromJson(Map<String, dynamic> json) => Ingrediente(
    ingredienteId: (json['ingredienteid'] as num).toInt(),
    receitaId: (json['receitaid'] as num?)?.toInt() ?? 0,
    itemId: (json['itemid'] as num?)?.toInt() ?? 0,
    quantidadeGrama: (json['quantidadegrama'] as num?) ?? 0,
    custoIngrediente: json['custoingrediente'] as num?,
    item: json['item'] is Map<String, dynamic> ? Item.fromJson(json['item'] as Map<String, dynamic>) : null,
  );

  Map<String, dynamic> toJson() => {
    'ingredienteid': ingredienteId,
    'receitaid': receitaId,
    'itemid': itemId,
    'quantidadegrama': quantidadeGrama,
    'custoingrediente': custoIngrediente,
  };

  Ingrediente copyWith({
    int? ingredienteId,
    int? receitaId,
    int? itemId,
    num? quantidadeGrama,
    num? custoIngrediente,
    Item? item,
  }) => Ingrediente(
    ingredienteId: ingredienteId ?? this.ingredienteId,
    receitaId: receitaId ?? this.receitaId,
    itemId: itemId ?? this.itemId,
    quantidadeGrama: quantidadeGrama ?? this.quantidadeGrama,
    custoIngrediente: custoIngrediente ?? this.custoIngrediente,
    item: item ?? this.item,
  );
}
