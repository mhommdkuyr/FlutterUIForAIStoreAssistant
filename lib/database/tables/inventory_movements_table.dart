import 'package:drift/drift.dart';

import 'products_table.dart';

/// Drift table definition for inventory movements (audit log).
///
/// Every change to a product's stock level — whether a purchase
/// delivery, a sale, or a manual correction — is recorded here.
///
/// The [type] column uses the following string values:
/// - `'in'`         — stock received / purchased
/// - `'out'`        — stock sold or consumed
/// - `'adjustment'` — manual correction
class InventoryMovements extends Table {
  /// Auto-incremented primary key.
  IntColumn get id => integer().autoIncrement()();

  /// Foreign key referencing the affected [Products.id].
  IntColumn get productId => integer().references(Products, #id)();

  /// Movement direction: `'in'`, `'out'`, or `'adjustment'`.
  TextColumn get type => text()();

  /// Number of units affected (always positive; direction is in [type]).
  IntColumn get quantity => integer()();

  /// Timestamp when the movement was recorded.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
