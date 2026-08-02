import '../daos/employees_dao.dart';
import '../app_database.dart';

/// Repository for [Employee] entities.
///
/// Features should depend on this repository rather than accessing
/// [EmployeesDao] directly.
class EmployeeRepository {
  final EmployeesDao _dao;

  const EmployeeRepository(this._dao);

  // ── Read ──────────────────────────────────────────────────────────────────

  /// Watches all employees as a reactive stream.
  Stream<List<Employee>> watchAll() => _dao.watchAll();

  /// Returns all employees as a one-time snapshot.
  Future<List<Employee>> getAll() => _dao.getAll();

  /// Returns the employee with [id], or `null` if they do not exist.
  Future<Employee?> getById(int id) => _dao.getById(id);

  /// Watches all employees assigned to [branchId].
  Stream<List<Employee>> watchByBranch(int branchId) =>
      _dao.watchByBranch(branchId);

  /// Returns all employees assigned to [branchId].
  Future<List<Employee>> getByBranch(int branchId) =>
      _dao.getByBranch(branchId);

  /// Returns all employees with [role].
  Future<List<Employee>> getByRole(String role) => _dao.getByRole(role);

  // ── Write ─────────────────────────────────────────────────────────────────

  /// Creates a new employee from the provided companion and returns their id.
  Future<int> create(EmployeesCompanion companion) => _dao.insertOne(companion);

  /// Fully replaces the employee row for [entity].
  Future<bool> save(Employee entity) => _dao.updateOne(entity);

  /// Partially updates the employee identified by [id].
  Future<int> patch(int id, EmployeesCompanion companion) =>
      _dao.updateById(id, companion);

  /// Removes the employee with [id] from the database.
  Future<int> delete(int id) => _dao.deleteById(id);
}
