import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import 'repository_exceptions.dart';

class BranchRepository {
  final AppDatabase _db = AppDatabase.instance;

  Future<List<BranchRecord>> getBranches() async {
    try {
      final rows = await (_db.select(_db.branches)
            ..orderBy([(t) => OrderingTerm.asc(t.name)]))
          .get();
      return rows.map((row) => BranchRecord(
            id: row.id,
            name: row.name,
            address: row.address ?? '',
            isActive: row.isActive,
            dailySales: row.dailySales,
            workerCount: row.workerCount,
          )).toList();
    } catch (e) {
      throw DatabaseException('Unable to load branches: $e');
    }
  }

  Future<BranchRecord> createBranch({required String name, String? address}) async {
    if (name.trim().isEmpty) {
      throw ValidationException('Branch name is required.');
    }
    try {
      final entity = BranchesCompanion(
        id: Value(Uuid().v4()),
        name: Value(name.trim()),
        address: Value(address?.trim()),
      );
      await _db.into(_db.branches).insert(entity);
      return BranchRecord(id: entity.id.value, name: name.trim(), address: address?.trim() ?? '', isActive: true, dailySales: 0, workerCount: 0);
    } catch (e) {
      if (e is ValidationException) rethrow;
      throw DatabaseException('Unable to create branch: $e');
    }
  }

  Future<void> toggleBranch(String id) async {
    try {
      final row = await (_db.select(_db.branches)..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
      if (row == null) {
        throw ValidationException('Branch not found.');
      }
      await (_db.update(_db.branches)
            ..where((tbl) => tbl.id.equals(id)))
          .write(BranchesCompanion(isActive: Value(!row.isActive)));
    } catch (e) {
      if (e is ValidationException) rethrow;
      throw DatabaseException('Unable to update branch: $e');
    }
  }
}

class BranchRecord {
  final String id;
  final String name;
  final String address;
  final bool isActive;
  final double dailySales;
  final int workerCount;

  const BranchRecord({required this.id, required this.name, required this.address, required this.isActive, required this.dailySales, required this.workerCount});
}
