import '../daos/customers_dao.dart';
import '../app_database.dart';

/// Repository for [Customer] entities.
///
/// Features should depend on this repository rather than accessing
/// [CustomersDao] directly.
class CustomerRepository {
  final CustomersDao _dao;

  const CustomerRepository(this._dao);

  // ── Read ──────────────────────────────────────────────────────────────────

  /// Watches all customers (alphabetically) as a reactive stream.
  Stream<List<Customer>> watchAll() => _dao.watchAll();

  /// Returns all customers as a one-time snapshot.
  Future<List<Customer>> getAll() => _dao.getAll();

  /// Returns the customer with [id], or `null` if they do not exist.
  Future<Customer?> getById(int id) => _dao.getById(id);

  /// Returns customers whose name contains [query] (case-insensitive).
  Future<List<Customer>> search(String query) => _dao.searchByName(query);

  /// Returns the customer with [phone], or `null` if not found.
  Future<Customer?> getByPhone(String phone) => _dao.getByPhone(phone);

  // ── Write ─────────────────────────────────────────────────────────────────

  /// Creates a new customer from the provided companion and returns their id.
  Future<int> create(CustomersCompanion companion) => _dao.insertOne(companion);

  /// Fully replaces the customer row for [entity].
  Future<bool> save(Customer entity) => _dao.updateOne(entity);

  /// Partially updates the customer identified by [id].
  Future<int> patch(int id, CustomersCompanion companion) =>
      _dao.updateById(id, companion);

  /// Removes the customer with [id] from the database.
  Future<int> delete(int id) => _dao.deleteById(id);
}
