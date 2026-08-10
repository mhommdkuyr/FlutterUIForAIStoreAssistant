class InventoryMovementModel {
  final String id;
  final String storeId;
  final String productId;
  final String? productVariantId;
  final String movementType;
  final double quantity;
  final double? unitPurchasePrice;
  final double? unitSellingPrice;
  final String? referenceType;
  final String? referenceId;
  final String? note;
  final String? createdBy;
  final String? branchId;
  final DateTime createdAt;

  const InventoryMovementModel({
    required this.id,
    required this.storeId,
    required this.productId,
    this.productVariantId,
    required this.movementType,
    required this.quantity,
    this.unitPurchasePrice,
    this.unitSellingPrice,
    this.referenceType,
    this.referenceId,
    this.note,
    this.createdBy,
    this.branchId,
    required this.createdAt,
  });

  InventoryMovementModel copyWith({
    String? id,
    String? storeId,
    String? productId,
    String? productVariantId,
    String? movementType,
    double? quantity,
    double? unitPurchasePrice,
    double? unitSellingPrice,
    String? referenceType,
    String? referenceId,
    String? note,
    String? createdBy,
    String? branchId,
    DateTime? createdAt,
  }) {
    return InventoryMovementModel(
      id: id ?? this.id,
      storeId: storeId ?? this.storeId,
      productId: productId ?? this.productId,
      productVariantId: productVariantId ?? this.productVariantId,
      movementType: movementType ?? this.movementType,
      quantity: quantity ?? this.quantity,
      unitPurchasePrice: unitPurchasePrice ?? this.unitPurchasePrice,
      unitSellingPrice: unitSellingPrice ?? this.unitSellingPrice,
      referenceType: referenceType ?? this.referenceType,
      referenceId: referenceId ?? this.referenceId,
      note: note ?? this.note,
      createdBy: createdBy ?? this.createdBy,
      branchId: branchId ?? this.branchId,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'storeId': storeId,
    'productId': productId,
    'productVariantId': productVariantId,
    'movementType': movementType,
    'quantity': quantity,
    'unitPurchasePrice': unitPurchasePrice,
    'unitSellingPrice': unitSellingPrice,
    'referenceType': referenceType,
    'referenceId': referenceId,
    'note': note,
    'createdBy': createdBy,
    'branchId': branchId,
    'createdAt': createdAt.toIso8601String(),
  };

  factory InventoryMovementModel.fromJson(Map<String, dynamic> json) =>
      InventoryMovementModel(
        id: json['id'] as String,
        storeId: json['storeId'] as String,
        productId: json['productId'] as String,
        productVariantId: json['productVariantId'] as String?,
        movementType: json['movementType'] as String,
        quantity: (json['quantity'] as num).toDouble(),
        unitPurchasePrice: (json['unitPurchasePrice'] as num?)?.toDouble(),
        unitSellingPrice: (json['unitSellingPrice'] as num?)?.toDouble(),
        referenceType: json['referenceType'] as String?,
        referenceId: json['referenceId'] as String?,
        note: json['note'] as String?,
        createdBy: json['createdBy'] as String?,
        branchId: json['branchId'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}
