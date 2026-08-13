import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_store_assistant/core/database/app_database.dart';
import 'package:ai_store_assistant/shared/repositories/inventory_movement_repository.dart';
import 'package:ai_store_assistant/shared/repositories/product_repository.dart';
import 'package:ai_store_assistant/shared/repositories/repository_exceptions.dart';
import 'package:ai_store_assistant/shared/repositories/sale_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late ProductRepository productRepository;
  late SaleRepository saleRepository;
  late InventoryMovementRepository movementRepository;

  setUp(() {
    AppDatabase.overrideForTest(NativeDatabase.memory());
    database = AppDatabase.instance;
    productRepository = ProductRepository();
    saleRepository = SaleRepository();
    movementRepository = InventoryMovementRepository();
  });

  tearDown(() async {
    await database.close();
    AppDatabase.resetForTest();
  });

  test('createSale records a sale inventory movement for each sold item',
      () async {
    final product = await productRepository.createProduct(
      name: 'Rice',
      category: 'Grains',
      purchasePrice: 2000,
      sellingPrice: 2500,
      quantity: 10,
      barcode: 'sale-movement-1',
    );

    final sale = await saleRepository.createSale(
      items: [product.copyWith(quantity: 2)],
      discount: 0,
      workerId: 'worker-1',
      branchId: 'branch-1',
      storeId: 'store-1',
      paymentMethod: 'cash',
    );

    final movements = await movementRepository.getByProductId(product.id);
    final updatedProduct = await productRepository.getProductById(product.id);

    expect(movements, hasLength(1));
    expect(movements.single.movementType, 'sale');
    expect(movements.single.quantity, 2);
    expect(movements.single.unitPurchasePrice, 2000);
    expect(movements.single.unitSellingPrice, 2500);
    expect(movements.single.referenceType, 'sale');
    expect(movements.single.referenceId, sale.id);
    expect(movements.single.createdBy, 'worker-1');
    expect(movements.single.branchId, 'branch-1');
    expect(movements.single.storeId, 'store-1');
    expect(updatedProduct?.quantity, 8);
    expect(
      await movementRepository.getCurrentStock(productId: product.id),
      -2,
    );
  });

  test('createSale does not record movements when stock is insufficient',
      () async {
    final product = await productRepository.createProduct(
      name: 'Oil',
      category: 'Cooking',
      purchasePrice: 1000,
      sellingPrice: 1200,
      quantity: 1,
      barcode: 'sale-movement-2',
    );

    await expectLater(
      () => saleRepository.createSale(
        items: [product.copyWith(quantity: 2)],
        discount: 0,
        workerId: 'worker-1',
        storeId: 'store-1',
      ),
      throwsA(isA<ValidationException>()),
    );

    expect(await movementRepository.getByProductId(product.id), isEmpty);
  });
}
