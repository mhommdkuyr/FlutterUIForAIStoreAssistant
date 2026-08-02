import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/stores_table.dart';

part 'stores_dao.g.dart';

/// Data Access Object for [Stores] table operations.
///
/// Provides reactive streams and one-shot futures for all CRUD
/// operations on store records. Features should use [StoreRepository]
/// rather than this DAO directly.
@DriftAccessor(tables: [Stores])
class StoresDao extends DatabaseAccessor<AppDatabase> with _$StoresDaoMixin {
  StoresDao(super.db);

  // ── Queries ───────────────────────────────────────────────────────────────

  /// Watches all stores as a reactive stream.
  Stream<List<Store>> watchAll() => select(stores).watch();

  /// Returns all stores as a one-time snapshot.
  Future<List<Store>> getAll() => select(stores).get();

  /// Returns a single store by its primary key, or `null` if not found.
  Future<Store?> getById(int id) =>
      (select(stores)..where((t) => t.id.equals(id))).getSingleOrNull();

  // ── Mutations ─────────────────────────────────────────────────────────────

  /// Inserts a new store and returns the generated row id.
  Future<int> insertOne(StoresCompanion companion) =>
      into(stores).insert(companion);

  /// Replaces an existing store row entirely.
  Future<bool> updateOne(Store entity) => update(stores).replace(entity);

  /// Partially updates a store identified by [id].
  Future<int> updateById(int id, StoresCompanion companion) =>
      (update(stores)..where((t) => t.id.equals(id))).write(companion);

  /// Deletes the store with the given [id]. Returns number of rows deleted.
  Future<int> deleteById(int id) =>
      (delete(stores)..where((t) => t.id.equals(id))).go();
}
