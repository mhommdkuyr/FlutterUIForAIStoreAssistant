import 'package:drift/drift.dart';

/// Drift table definition for inventory products.
///
/// A [Product] represents a single SKU that can be stocked, sold,
/// and tracked for expiration.
class Products extends Table {
  /// Auto-incremented primary key.
  IntColumn get id => integer().autoIncrement()();

  /// Optional barcode string (EAN-13, QR, etc.).
  TextColumn get barcode => text().nullable()();

  /// Display name of the product.
  TextColumn get name => text()();

  /// Optional local file path or URL for the product image.
  TextColumn get image => text().nullable()();

  /// Category label (e.g. 'Dairy', 'Bakery').
  TextColumn get category => text()();

  /// Purchase / cost price per unit.
  RealColumn get purchasePrice => real()();

  /// Selling price per unit.
  RealColumn get sellingPrice => real()();

  /// Current on-hand stock count.
  IntColumn get quantity => integer().withDefault(const Constant(0))();

  /// Alert threshold — reorder when [quantity] falls below this.
  IntColumn get minimumStock => integer().withDefault(const Constant(0))();

  /// Optional expiration date for perishable items.
  DateTimeColumn get expirationDate => dateTime().nullable()();

  /// Timestamp when the product record was first created.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Timestamp of the last modification to this record.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}
