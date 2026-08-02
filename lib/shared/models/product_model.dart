class ProductModel {
  final String id;
  final String name;
  final String? nameAr;
  final String category;
  final double purchasePrice;
  final double sellingPrice;
  final int quantity;
  final String? barcode;
  final String? imageUrl;
  final String? description;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isActive;
  final String? branchId;

  const ProductModel({
    required this.id,
    required this.name,
    this.nameAr,
    required this.category,
    required this.purchasePrice,
    required this.sellingPrice,
    required this.quantity,
    this.barcode,
    this.imageUrl,
    this.description,
    required this.createdAt,
    required this.updatedAt,
    this.isActive = true,
    this.branchId,
  });

  double get profit => sellingPrice - purchasePrice;
  double get profitMargin =>
      purchasePrice == 0 ? 0 : (profit / purchasePrice) * 100;
  bool get isLowStock => quantity > 0 && quantity <= 10;
  bool get isOutOfStock => quantity == 0;

  String get stockStatus {
    if (isOutOfStock) return 'Out of Stock';
    if (isLowStock) return 'Low Stock';
    return 'In Stock';
  }

  ProductModel copyWith({
    String? id,
    String? name,
    String? nameAr,
    String? category,
    double? purchasePrice,
    double? sellingPrice,
    int? quantity,
    String? barcode,
    String? imageUrl,
    String? description,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isActive,
    String? branchId,
  }) {
    return ProductModel(
      id: id ?? this.id,
      name: name ?? this.name,
      nameAr: nameAr ?? this.nameAr,
      category: category ?? this.category,
      purchasePrice: purchasePrice ?? this.purchasePrice,
      sellingPrice: sellingPrice ?? this.sellingPrice,
      quantity: quantity ?? this.quantity,
      barcode: barcode ?? this.barcode,
      imageUrl: imageUrl ?? this.imageUrl,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isActive: isActive ?? this.isActive,
      branchId: branchId ?? this.branchId,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'nameAr': nameAr,
        'category': category,
        'purchasePrice': purchasePrice,
        'sellingPrice': sellingPrice,
        'quantity': quantity,
        'barcode': barcode,
        'imageUrl': imageUrl,
        'description': description,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'isActive': isActive,
        'branchId': branchId,
      };

  factory ProductModel.fromJson(Map<String, dynamic> json) => ProductModel(
        id: json['id'] as String,
        name: json['name'] as String,
        nameAr: json['nameAr'] as String?,
        category: json['category'] as String,
        purchasePrice: (json['purchasePrice'] as num).toDouble(),
        sellingPrice: (json['sellingPrice'] as num).toDouble(),
        quantity: json['quantity'] as int,
        barcode: json['barcode'] as String?,
        imageUrl: json['imageUrl'] as String?,
        description: json['description'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        isActive: json['isActive'] as bool? ?? true,
        branchId: json['branchId'] as String?,
      );
}
