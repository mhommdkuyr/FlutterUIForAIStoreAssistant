import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/branches_table.dart';

part 'branches_dao.g.dart';

/// Data Access Object for [Branches] table operations.
///
/// Note: Drift generates the row data class as [Branche] (singular of
/// Branches) — this is Drift's automatic singularisation behaviour.
@DriftAccessor(tables: [Branches])
class BranchesDao extends DatabaseAccessor<AppDatabase>
    with _$BranchesDaoMixin {
  BranchesDao(super.db);

  // ── Queries ───────────────────────────────────────────────────────────────

  /// Watches all branches as a reactive stream.
  Stream<List<Branche>> watchAll() => select(branches).watch();

  /// Returns all branches as a one-time snapshot.
  Future<List<Branche>> getAll() => select(branches).get();

  /// Returns a single branch by its primary key, or `null` if not found.
  Future<Branche?> getById(int id) =>
      (select(branches)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Watches all branches that belong to the given [storeId].
  Stream<List<Branche>> watchByStore(int storeId) =>
      (select(branches)..where((t) => t.storeId.equals(storeId))).watch();

  /// Returns all branches for the given [storeId].
  Future<List<Branche>> getByStore(int storeId) =>
      (select(branches)..where((t) => t.storeId.equals(storeId))).get();

  // ── Mutations ─────────────────────────────────────────────────────────────

  /// Inserts a new branch and returns the generated row id.
  Future<int> insertOne(BranchesCompanion companion) =>
      into(branches).insert(companion);

  /// Replaces an existing branch row entirely.
  Future<bool> updateOne(Branche entity) => update(branches).replace(entity);

  /// Partially updates a branch identified by [id].
  Future<int> updateById(int id, BranchesCompanion companion) =>
      (update(branches)..where((t) => t.id.equals(id))).write(companion);

  /// Deletes the branch with the given [id]. Returns number of rows deleted.
  Future<int> deleteById(int id) =>
      (delete(branches)..where((t) => t.id.equals(id))).go();
}
