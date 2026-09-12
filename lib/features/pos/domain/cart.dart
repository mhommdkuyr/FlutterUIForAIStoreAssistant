enum CartMutationSource { visual, barcode, manual, ai }

enum CartItemKind { product }

class CartItem {
  const CartItem({
    required this.productId,
    required this.name,
    required this.unitPrice,
    required this.quantity,
    this.barcode,
    this.source = CartMutationSource.manual,
    this.discount = 0,
    this.kind = CartItemKind.product,
  });

  final String productId;
  final String name;
  final double unitPrice;
  final int quantity;
  final String? barcode;
  final CartMutationSource source;
  final double discount;
  final CartItemKind kind;

  double get gross => unitPrice * quantity;
  double get total => gross - discount;

  CartItem copyWith({
    String? name,
    double? unitPrice,
    int? quantity,
    String? barcode,
    CartMutationSource? source,
    double? discount,
    CartItemKind? kind,
  }) {
    return CartItem(
      productId: productId,
      name: name ?? this.name,
      unitPrice: unitPrice ?? this.unitPrice,
      quantity: quantity ?? this.quantity,
      barcode: barcode ?? this.barcode,
      source: source ?? this.source,
      discount: discount ?? this.discount,
      kind: kind ?? this.kind,
    );
  }
}

class CartState {
  const CartState._({
    required this.id,
    required this.items,
    required this.currencyCode,
    required this.exchangeRate,
  });

  factory CartState.empty({
    String id = 'active',
    String currencyCode = 'USD',
    double exchangeRate = 520,
  }) {
    if (exchangeRate <= 0) {
      throw ArgumentError.value(exchangeRate, 'exchangeRate');
    }
    return CartState._(
      id: id,
      items: const <CartItem>[],
      currencyCode: currencyCode,
      exchangeRate: exchangeRate,
    );
  }

  final String id;
  final List<CartItem> items;
  final String currencyCode;
  final double exchangeRate;

  int get itemCount => items.fold(0, (sum, item) => sum + item.quantity);
  double get subtotal => items.fold(0, (sum, item) => sum + item.gross);
  double get discountTotal => items.fold(0, (sum, item) => sum + item.discount);
  double get total => subtotal - discountTotal;
  double get totalInYER => total * exchangeRate;

  CartState addItem({
    required String productId,
    required String name,
    required double unitPrice,
    int quantity = 1,
    String? barcode,
    CartMutationSource source = CartMutationSource.manual,
  }) {
    _validateQuantity(quantity);
    if (productId.trim().isEmpty) {
      throw ArgumentError.value(productId, 'productId');
    }
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name');
    }
    if (unitPrice < 0) {
      throw ArgumentError.value(unitPrice, 'unitPrice');
    }

    final index = items.indexWhere((item) => item.productId == productId);
    final next = List<CartItem>.from(items);
    if (index == -1) {
      next.add(CartItem(
        productId: productId,
        name: name.trim(),
        unitPrice: unitPrice,
        quantity: quantity,
        barcode: barcode,
        source: source,
      ));
    } else {
      final current = next[index];
      next[index] = current.copyWith(
        name: name.trim(),
        unitPrice: unitPrice,
        quantity: current.quantity + quantity,
        barcode: barcode,
        source: source,
      );
    }
    return _copy(items: next);
  }

  CartState setQuantity(String productId, int quantity) {
    _validateQuantity(quantity);
    final index = items.indexWhere((item) => item.productId == productId);
    if (index == -1) return this;
    final next = List<CartItem>.from(items);
    if (quantity == 0) {
      next.removeAt(index);
    } else {
      next[index] = next[index].copyWith(quantity: quantity);
    }
    return _copy(items: next);
  }

  CartState removeItem(String productId) {
    final next = items.where((item) => item.productId != productId).toList();
    return _copy(items: next);
  }

  CartState applyItemDiscount(String productId, double discount) {
    if (discount < 0) throw ArgumentError.value(discount, 'discount');
    final index = items.indexWhere((item) => item.productId == productId);
    if (index == -1) return this;
    final next = List<CartItem>.from(items);
    final current = next[index];
    if (discount > current.gross) {
      throw ArgumentError('Discount cannot exceed item gross value.');
    }
    next[index] = current.copyWith(discount: discount);
    return _copy(items: next);
  }

  CartState _copy({List<CartItem>? items}) {
    return CartState._(
      id: id,
      items: List<CartItem>.unmodifiable(items ?? this.items),
      currencyCode: currencyCode,
      exchangeRate: exchangeRate,
    );
  }

  static void _validateQuantity(int quantity) {
    if (quantity < 0) throw ArgumentError.value(quantity, 'quantity');
  }
}
