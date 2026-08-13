import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../models/inventory_movement_model.dart';

class InventoryMovementRepository {
  final AppDatabase _db = AppDatabase.instance;

  Future<List<InventoryMovementModel>> getByProductId(
    String productId,
  ) async {
    final rows = await (_db.select(_db.inventoryMovements)
          ..where((table) => table.productId.equals(productId))
          ..orderBy([
            (table) => OrderingTerm.desc(table.createdAt),
          ]))
        .get();
    return rows.map(_mapRow).toList();
  }

  Future<List<InventoryMovementModel>> getByVariantId(
    String variantId,
  ) async {
    final rows = await (_db.select(_db.inventoryMovements)
          ..where((table) => table.productVariantId.equals(variantId))
          ..orderBy([
            (table) => OrderingTerm.desc(table.createdAt),
          ]))
        .get();
    return rows.map(_mapRow).toList();
  }

  Future<double> getCurrentStock({
    required String productId,
    String? variantId,
  }) async {
    final query = _db.select(_db.inventoryMovements)
      ..where((table) {
        final productFilter = table.productId.equals(productId);
        if (variantId == null) return productFilter;
        return productFilter & table.productVariantId.equals(variantId);
      });
    final rows = await query.get();

    return rows.fold<double>(
      0,
      (stock, movement) {
        switch (movement.movementType) {
          case 'in':
          case 'return':
          case 'adjustment':
            return stock + movement.quantity;
          case 'out':
          case 'sale':
            return stock - movement.quantity;
          default:
            return stock;
        }
      },
    );
  }

  Future<InventoryMovementModel> recordMovement(
    InventoryMovementModel movement,
  ) async {
    await _db
        .into(_db.inventoryMovements)
        .insert(_toCompanion(movement));
    return movement;
  }

  Future<InventoryMovementModel> recordInbound({
    required String storeId,
    required String productId,
    String? productVariantId,
    required double quantity,
    double? unitPurchasePrice,
    double? unitSellingPrice,
    String? referenceType,
    String? referenceId,
    String? note,
    String? createdBy,
    String? branchId,
    String? id,
    DateTime? createdAt,
  }) {
    return recordMovement(
      InventoryMovementModel(
        id: id ?? Uuid().v4(),
        storeId: storeId,
        productId: productId,
        productVariantId: productVariantId,
        movementType: 'in',
        quantity: quantity,
        unitPurchasePrice: unitPurchasePrice,
        unitSellingPrice: unitSellingPrice,
        referenceType: referenceType,
        referenceId: referenceId,
        note: note,
        createdBy: createdBy,
        branchId: branchId,
        createdAt: createdAt ?? DateTime.now(),
      ),
    );
  }

  Future<InventoryMovementModel> recordOutbound({
    required String storeId,
    required String productId,
    String? productVariantId,
    required double quantity,
    double? unitPurchasePrice,
    double? unitSellingPrice,
    String? referenceType,
    String? referenceId,
    String? note,
    String? createdBy,
    String? branchId,
    String? id,
    DateTime? createdAt,
  }) {
    return recordMovement(
      InventoryMovementModel(
        id: id ?? Uuid().v4(),
        storeId: storeId,
        productId: productId,
        productVariantId: productVariantId,
        movementType: 'out',
        quantity: quantity,
        unitPurchasePrice: unitPurchasePrice,
        unitSellingPrice: unitSellingPrice,
        referenceType: referenceType,
        referenceId: referenceId,
        note: note,
        createdBy: createdBy,
        branchId: branchId,
        createdAt: createdAt ?? DateTime.now(),
      ),
    );
  }

  InventoryMovementModel _mapRow(InventoryMovement row) {
    return InventoryMovementModel(
      id: row.id,
      storeId: row.storeId,
      productId: row.productId,
      productVariantId: row.productVariantId,
      movementType: row.movementType,
      quantity: row.quantity,
      unitPurchasePrice: row.unitPurchasePrice,
      unitSellingPrice: row.unitSellingPrice,
      referenceType: row.referenceType,
      referenceId: row.referenceId,
      note: row.note,
      createdBy: row.createdBy,
      branchId: row.branchId,
      createdAt: row.createdAt,
    );
  }

  InventoryMovementsCompanion _toCompanion(
    InventoryMovementModel movement,
  ) {
    return InventoryMovementsCompanion(
      id: Value(movement.id),
      storeId: Value(movement.storeId),
      productId: Value(movement.productId),
      productVariantId: Value(movement.productVariantId),
      movementType: Value(movement.movementType),
      quantity: Value(movement.quantity),
      unitPurchasePrice: Value(movement.unitPurchasePrice),
      unitSellingPrice: Value(movement.unitSellingPrice),
      referenceType: Value(movement.referenceType),
      referenceId: Value(movement.referenceId),
      note: Value(movement.note),
      createdBy: Value(movement.createdBy),
      branchId: Value(movement.branchId),
      createdAt: Value(movement.createdAt),
    );
  }
}
