import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';
import '../models/product_variant_model.dart';

class ProductVariantRepository {
  final AppDatabase _db = AppDatabase.instance;

  Future<List<ProductVariantModel>> getAllByProductId(String productId) async {
    final rows = await (_db.select(
      _db.productVariants,
    )..where((table) => table.productId.equals(productId))).get();
    return rows.map(_mapRow).toList();
  }

  Future<ProductVariantModel?> getById(String id) async {
    final row = await (_db.select(
      _db.productVariants,
    )..where((table) => table.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

  Future<ProductVariantModel?> getByBarcode(String barcode) async {
    final row = await (_db.select(
      _db.productVariants,
    )..where((table) => table.barcode.equals(barcode))).getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

  Future<ProductVariantModel> insert(ProductVariantModel variant) async {
    await _db.into(_db.productVariants).insert(_toCompanion(variant));
    return variant;
  }

  Future<ProductVariantModel> update(ProductVariantModel variant) async {
    await (_db.update(_db.productVariants)
          ..where((table) => table.id.equals(variant.id)))
        .write(_toCompanion(variant));
    return variant;
  }

  Future<void> delete(String id) async {
    await (_db.delete(
      _db.productVariants,
    )..where((table) => table.id.equals(id))).go();
  }

  ProductVariantModel _mapRow(ProductVariant row) {
    return ProductVariantModel(
      id: row.id,
      productId: row.productId,
      name: row.name,
      sizeValue: row.sizeValue,
      sizeUnit: row.sizeUnit,
      purchasePrice: row.purchasePrice,
      sellingPrice: row.sellingPrice,
      sku: row.sku,
      barcode: row.barcode,
      isActive: row.isActive,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  ProductVariantsCompanion _toCompanion(ProductVariantModel variant) {
    return ProductVariantsCompanion(
      id: Value(variant.id),
      productId: Value(variant.productId),
      name: Value(variant.name),
      sizeValue: Value(variant.sizeValue),
      sizeUnit: Value(variant.sizeUnit),
      purchasePrice: Value(variant.purchasePrice),
      sellingPrice: Value(variant.sellingPrice),
      sku: Value(variant.sku),
      barcode: Value(variant.barcode),
      isActive: Value(variant.isActive),
      createdAt: Value(variant.createdAt),
      updatedAt: Value(variant.updatedAt),
    );
  }
}
