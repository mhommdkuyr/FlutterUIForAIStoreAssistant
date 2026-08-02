import 'package:drift/drift.dart';

/// Drift table definition for top-level store entities.
///
/// A [Store] represents one merchant's business. Branches and employees
/// belong to a store.
class Stores extends Table {
  /// Auto-incremented primary key.
  IntColumn get id => integer().autoIncrement()();

  /// Display name of the store.
  TextColumn get name => text()();

  /// Full name of the store owner.
  TextColumn get ownerName => text()();

  /// Contact phone number for the store.
  TextColumn get phone => text()();

  /// Physical address of the main store.
  TextColumn get address => text()();

  /// Timestamp when the store was created.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
