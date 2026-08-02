import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/products_table.dart';

part 'products_dao.g.dart';

/// Data Access Object for [Products] table operations.
///
/// Provides standard CRUD plus inventory-specific queries such as
/// low-stock watching and name/barcode search.
@DriftAccessor(tables: [Products])
class ProductsDao extends DatabaseAccessor<AppDatabase>
    with _$ProductsDaoMixin {
  ProductsDao(super.db);

  // ── Queries ───────────────────────────────────────────────────────────────

  /// Watches all products as a reactive stream.
  Stream<List<Product>> watchAll() =>
      (select(products)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  /// Returns all products as a one-time snapshot.
  Future<List<Product>> getAll() =>
      (select(products)..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  /// Returns a single product by its primary key, or `null` if not found.
  Future<Product?> getById(int id) =>
      (select(products)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Returns a product whose [barcode] matches exactly, or `null`.
  Future<Product?> getByBarcode(String barcode) =>
      (select(products)..where((t) => t.barcode.equals(barcode)))
          .getSingleOrNull();

  /// Watches products whose current [quantity] is below [minimumStock].
  Stream<List<Product>> watchLowStock() =>
      (select(products)..where((t) => t.quantity.isSmallerThan(t.minimumStock)))
          .watch();

  /// Watches products whose [quantity] is zero.
  Stream<List<Product>> watchOutOfStock() =>
      (select(products)..where((t) => t.quantity.equals(0))).watch();

  /// Watches all products belonging to [category].
  Stream<List<Product>> watchByCategory(String category) =>
      (select(products)..where((t) => t.category.equals(category))).watch();

  /// Returns products whose name contains [query] (case-insensitive).
  Future<List<Product>> searchByName(String query) =>
      (select(products)..where((t) => t.name.like('%$query%'))).get();

  // ── Mutations ─────────────────────────────────────────────────────────────

  /// Inserts a new product and returns the generated row id.
  Future<int> insertOne(ProductsCompanion companion) =>
      into(products).insert(companion);

  /// Replaces an existing product row entirely.
  Future<bool> updateOne(Product entity) => update(products).replace(entity);

  /// Partially updates a product identified by [id].
  Future<int> updateById(int id, ProductsCompanion companion) =>
      (update(products)..where((t) => t.id.equals(id))).write(companion);

  /// Adjusts [quantity] for [productId] by [delta] (can be negative).
  Future<void> adjustStock(int productId, int delta) async {
    final product = await getById(productId);
    if (product == null) return;
    await updateById(
      productId,
      ProductsCompanion(
        quantity: Value(product.quantity + delta),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Deletes the product with the given [id]. Returns number of rows deleted.
  Future<int> deleteById(int id) =>
      (delete(products)..where((t) => t.id.equals(id))).go();
}
