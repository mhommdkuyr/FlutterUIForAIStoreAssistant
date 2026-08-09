class ProductVariantModel {
  final String id;
  final String productId;
  final String name;
  final double? sizeValue;
  final String? sizeUnit;
  final double purchasePrice;
  final double sellingPrice;
  final String? sku;
  final String? barcode;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ProductVariantModel({
    required this.id,
    required this.productId,
    required this.name,
    this.sizeValue,
    this.sizeUnit,
    required this.purchasePrice,
    required this.sellingPrice,
    this.sku,
    this.barcode,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
  });

  ProductVariantModel copyWith({
    String? id,
    String? productId,
    String? name,
    double? sizeValue,
    String? sizeUnit,
    double? purchasePrice,
    double? sellingPrice,
    String? sku,
    String? barcode,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ProductVariantModel(
      id: id ?? this.id,
      productId: productId ?? this.productId,
      name: name ?? this.name,
      sizeValue: sizeValue ?? this.sizeValue,
      sizeUnit: sizeUnit ?? this.sizeUnit,
      purchasePrice: purchasePrice ?? this.purchasePrice,
      sellingPrice: sellingPrice ?? this.sellingPrice,
      sku: sku ?? this.sku,
      barcode: barcode ?? this.barcode,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'productId': productId,
    'name': name,
    'sizeValue': sizeValue,
    'sizeUnit': sizeUnit,
    'purchasePrice': purchasePrice,
    'sellingPrice': sellingPrice,
    'sku': sku,
    'barcode': barcode,
    'isActive': isActive,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ProductVariantModel.fromJson(Map<String, dynamic> json) =>
      ProductVariantModel(
        id: json['id'] as String,
        productId: json['productId'] as String,
        name: json['name'] as String,
        sizeValue: (json['sizeValue'] as num?)?.toDouble(),
        sizeUnit: json['sizeUnit'] as String?,
        purchasePrice: (json['purchasePrice'] as num).toDouble(),
        sellingPrice: (json['sellingPrice'] as num).toDouble(),
        sku: json['sku'] as String?,
        barcode: json['barcode'] as String?,
        isActive: json['isActive'] as bool,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}
