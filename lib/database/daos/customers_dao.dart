import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/customers_table.dart';

part 'customers_dao.g.dart';

/// Data Access Object for [Customers] table operations.
@DriftAccessor(tables: [Customers])
class CustomersDao extends DatabaseAccessor<AppDatabase>
    with _$CustomersDaoMixin {
  CustomersDao(super.db);

  // ── Queries ───────────────────────────────────────────────────────────────

  /// Watches all customers alphabetically as a reactive stream.
  Stream<List<Customer>> watchAll() =>
      (select(customers)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  /// Returns all customers alphabetically as a one-time snapshot.
  Future<List<Customer>> getAll() =>
      (select(customers)..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  /// Returns a single customer by their primary key, or `null` if not found.
  Future<Customer?> getById(int id) =>
      (select(customers)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Returns customers whose name contains [query] (case-insensitive).
  Future<List<Customer>> searchByName(String query) =>
      (select(customers)..where((t) => t.name.like('%$query%'))).get();

  /// Returns the customer with [phone], or `null` if not found.
  Future<Customer?> getByPhone(String phone) =>
      (select(customers)..where((t) => t.phone.equals(phone)))
          .getSingleOrNull();

  // ── Mutations ─────────────────────────────────────────────────────────────

  /// Inserts a new customer and returns the generated row id.
  Future<int> insertOne(CustomersCompanion companion) =>
      into(customers).insert(companion);

  /// Replaces an existing customer row entirely.
  Future<bool> updateOne(Customer entity) => update(customers).replace(entity);

  /// Partially updates a customer identified by [id].
  Future<int> updateById(int id, CustomersCompanion companion) =>
      (update(customers)..where((t) => t.id.equals(id))).write(companion);

  /// Deletes the customer with the given [id]. Returns number of rows deleted.
  Future<int> deleteById(int id) =>
      (delete(customers)..where((t) => t.id.equals(id))).go();
}
