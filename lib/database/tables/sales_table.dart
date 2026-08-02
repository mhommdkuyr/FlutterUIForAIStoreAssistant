import 'package:drift/drift.dart';

import 'employees_table.dart';
import 'products_table.dart';

/// Drift table definition for sales transactions.
///
/// Each [Sale] row records the sale of a single [Product] line item.
/// Multiple rows with the same transaction context represent a cart.
class Sales extends Table {
  /// Auto-incremented primary key.
  IntColumn get id => integer().autoIncrement()();

  /// Foreign key referencing the sold [Products.id].
  IntColumn get productId => integer().references(Products, #id)();

  /// Number of units sold in this line item.
  IntColumn get quantity => integer()();

  /// Price per unit at time of sale (snapshot, not a live FK).
  RealColumn get unitPrice => real()();

  /// Pre-computed total: [quantity] × [unitPrice].
  RealColumn get totalPrice => real()();

  /// Optional FK to the [Employees.id] who processed the sale.
  IntColumn get employeeId => integer().nullable().references(Employees, #id)();

  /// Timestamp when the sale was recorded.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
