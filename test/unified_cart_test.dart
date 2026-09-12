import 'package:flutter_test/flutter_test.dart';
import 'package:ai_store_assistant/features/pos/domain/cart.dart';

void main() {
  group('CartState', () {
    test('merges the same product from different sale sources', () {
      var cart = CartState.empty();
      cart = cart.addItem(
        productId: 'p1',
        name: 'Rice',
        unitPrice: 2,
        source: CartMutationSource.visual,
      );
      cart = cart.addItem(
        productId: 'p1',
        name: 'Rice',
        unitPrice: 2,
        source: CartMutationSource.barcode,
      );

      expect(cart.items, hasLength(1));
      expect(cart.itemCount, 2);
      expect(cart.subtotal, 4);
      expect(cart.items.single.source, CartMutationSource.barcode);
    });

    test('quantity zero removes the item', () {
      var cart = CartState.empty().addItem(
        productId: 'p1',
        name: 'Rice',
        unitPrice: 2,
        quantity: 2,
      );

      cart = cart.setQuantity('p1', 0);
      expect(cart.items, isEmpty);
      expect(cart.total, 0);
    });

    test('item discount cannot make total negative', () {
      var cart = CartState.empty().addItem(
        productId: 'p1',
        name: 'Rice',
        unitPrice: 10,
        quantity: 2,
      );
      cart = cart.applyItemDiscount('p1', 4);

      expect(cart.subtotal, 20);
      expect(cart.discountTotal, 4);
      expect(cart.total, 16);
      expect(cart.totalInYER, 8320);
    });

    test('configured USD to YER rate is applied without changing base price', () {
      final cart = CartState.empty(exchangeRate: 520).addItem(
        productId: 'p1',
        name: 'Milk',
        unitPrice: 1.5,
        quantity: 2,
      );

      expect(cart.total, 3);
      expect(cart.totalInYER, 1560);
    });
  });
}
