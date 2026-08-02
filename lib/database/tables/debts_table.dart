import 'package:drift/drift.dart';

import 'customers_table.dart';

/// Drift table definition for customer debts.
///
/// A [Debt] tracks how much a [Customer] owes, how much has been
/// paid, and how much remains outstanding.
class Debts extends Table {
  /// Auto-incremented primary key.
  IntColumn get id => integer().autoIncrement()();

  /// Foreign key referencing the debtor [Customers.id].
  IntColumn get customerId => integer().references(Customers, #id)();

  /// Original debt amount.
  RealColumn get amount => real()();

  /// Amount already paid by the customer.
  RealColumn get paid => real().withDefault(const Constant(0.0))();

  /// Remaining balance: [amount] − [paid].
  ///
  /// Stored as a denormalised column so queries can filter/sort
  /// efficiently without computing it on every read.
  RealColumn get remaining => real()();

  /// Timestamp when the debt was recorded.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
