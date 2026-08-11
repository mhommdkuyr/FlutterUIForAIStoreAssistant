import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_store_assistant/core/database/app_database.dart';
import 'package:ai_store_assistant/shared/models/inventory_movement_model.dart';
import 'package:ai_store_assistant/shared/repositories/inventory_movement_repository.dart';

void main() {
  late AppDatabase database;
  late InventoryMovementRepository repository;

  setUp(() {
    AppDatabase.overrideForTest(NativeDatabase.memory());
    database = AppDatabase.instance;
    repository = InventoryMovementRepository();
  });

  tearDown(() async {
    await database.close();
    AppDatabase.resetForTest();
  });

  test(
    'getByProductId returns movements for the requested product only',
    () async {
      await repository.recordInbound(
        storeId: 'store-1',
        productId: 'product-a',
        quantity: 10,
      );
      await repository.recordInbound(
        storeId: 'store-1',
        productId: 'product-b',
        quantity: 4,
      );

      final movements = await repository.getByProductId('product-a');

      expect(movements, hasLength(1));
      expect(movements.single.productId, 'product-a');
    },
  );

  test(
    'getByVariantId returns movements for the requested variant only',
    () async {
      await repository.recordInbound(
        storeId: 'store-1',
        productId: 'product-a',
        productVariantId: 'variant-a',
        quantity: 10,
      );
      await repository.recordInbound(
        storeId: 'store-1',
        productId: 'product-a',
        productVariantId: 'variant-b',
        quantity: 7,
      );

      final movements = await repository.getByVariantId('variant-a');

      expect(movements, hasLength(1));
      expect(movements.single.productVariantId, 'variant-a');
    },
  );

  test('recordInbound adds quantity to current stock', () async {
    await repository.recordInbound(
      storeId: 'store-1',
      productId: 'product-a',
      quantity: 10,
    );
    await repository.recordInbound(
      storeId: 'store-1',
      productId: 'product-a',
      quantity: 5,
    );

    expect(await repository.getCurrentStock(productId: 'product-a'), 15);
  });

  test('recordOutbound subtracts quantity from current stock', () async {
    await repository.recordInbound(
      storeId: 'store-1',
      productId: 'product-a',
      quantity: 15,
    );
    await repository.recordOutbound(
      storeId: 'store-1',
      productId: 'product-a',
      quantity: 3,
    );

    expect(await repository.getCurrentStock(productId: 'product-a'), 12);
  });

  test(
    'getCurrentStock handles in, out, return, and variant isolation',
    () async {
      await repository.recordInbound(
        storeId: 'store-1',
        productId: 'product-a',
        productVariantId: 'variant-a',
        quantity: 10,
      );
      await repository.recordInbound(
        storeId: 'store-1',
        productId: 'product-a',
        productVariantId: 'variant-a',
        quantity: 5,
      );
      await repository.recordOutbound(
        storeId: 'store-1',
        productId: 'product-a',
        productVariantId: 'variant-a',
        quantity: 3,
      );
      await repository.recordMovement(
        InventoryMovementModel(
          id: 'return-1',
          storeId: 'store-1',
          productId: 'product-a',
          productVariantId: 'variant-a',
          movementType: 'return',
          quantity: 2,
          createdAt: DateTime(2026, 1, 1),
        ),
      );
      await repository.recordInbound(
        storeId: 'store-1',
        productId: 'product-a',
        productVariantId: 'variant-b',
        quantity: 20,
      );

      expect(
        await repository.getCurrentStock(
          productId: 'product-a',
          variantId: 'variant-a',
        ),
        14,
      );
      expect(
        await repository.getCurrentStock(
          productId: 'product-a',
          variantId: 'variant-b',
        ),
        20,
      );
    },
  );
}
