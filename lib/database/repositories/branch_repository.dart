import '../daos/branches_dao.dart';
import '../app_database.dart';

/// Repository for [Branche] entities (Drift-generated row type for [Branches]).
///
/// Features should depend on this repository rather than accessing
/// [BranchesDao] directly.
class BranchRepository {
  final BranchesDao _dao;

  const BranchRepository(this._dao);

  // ── Read ──────────────────────────────────────────────────────────────────

  /// Watches all branches as a reactive stream.
  Stream<List<Branche>> watchAll() => _dao.watchAll();

  /// Returns all branches as a one-time snapshot.
  Future<List<Branche>> getAll() => _dao.getAll();

  /// Returns the branch with [id], or `null` if it does not exist.
  Future<Branche?> getById(int id) => _dao.getById(id);

  /// Watches all branches belonging to [storeId].
  Stream<List<Branche>> watchByStore(int storeId) => _dao.watchByStore(storeId);

  /// Returns all branches belonging to [storeId].
  Future<List<Branche>> getByStore(int storeId) => _dao.getByStore(storeId);

  // ── Write ─────────────────────────────────────────────────────────────────

  /// Creates a new branch from the provided companion and returns its id.
  Future<int> create(BranchesCompanion companion) => _dao.insertOne(companion);

  /// Fully replaces the branch row for [entity].
  Future<bool> save(Branche entity) => _dao.updateOne(entity);

  /// Partially updates the branch identified by [id].
  Future<int> patch(int id, BranchesCompanion companion) =>
      _dao.updateById(id, companion);

  /// Removes the branch with [id] from the database.
  Future<int> delete(int id) => _dao.deleteById(id);
}
