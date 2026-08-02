import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../shared/models/user_model.dart';
import 'repository_exceptions.dart';

class CustomerRepository {
  final AppDatabase _db = AppDatabase.instance;

  /// Watches all customers as a reactive stream that emits a new list
  /// whenever the database changes.
  Stream<List<UserModel>> watchCustomers() {
    return (_db.select(_db.customers)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch()
        .map((rows) => rows.map(_mapRow).toList());
  }

  Future<List<UserModel>> getCustomers() async {
    try {
      final rows = await (_db.select(_db.customers)
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();
      return rows.map(_mapRow).toList();
    } catch (e) {
      throw DatabaseException('Unable to load customers: $e');
    }
  }

  Future<UserModel?> getCustomerById(String id) async {
    try {
      final row = await (_db.select(_db.customers)
            ..where((tbl) => tbl.id.equals(id)))
          .getSingleOrNull();
      if (row == null) return null;
      return _mapRow(row);
    } catch (e) {
      throw DatabaseException('Unable to load customer: $e');
    }
  }

  Future<UserModel> createCustomer({
    required String fullName,
    String? phone,
    String? email,
    String? address,
    String? note,
  }) async {
    if (fullName.trim().isEmpty) {
      throw ValidationException('Customer name is required.');
    }
    try {
      final now = DateTime.now();
      final entity = CustomersCompanion(
        id: Value(Uuid().v4()),
        fullName: Value(fullName.trim()),
        email: Value(email?.trim()),
        phone: Value(phone?.trim()),
        address: Value(address?.trim()),
        note: Value(note?.trim()),
        createdAt: Value(now),
      );
      await _db.into(_db.customers).insert(entity);
      return UserModel(
        id: entity.id.value,
        fullName: fullName.trim(),
        email: email?.trim() ?? '',
        phone: phone?.trim() ?? '',
        role: 'customer',
        createdAt: now,
      );
    } catch (e) {
      if (e is ValidationException) rethrow;
      throw DatabaseException('Unable to save customer: $e');
    }
  }

  Future<UserModel> updateCustomer({
    required String id,
    required String fullName,
    String? phone,
    String? email,
    String? address,
    String? note,
  }) async {
    if (fullName.trim().isEmpty) {
      throw ValidationException('Customer name is required.');
    }
    try {
      final existing = await (_db.select(_db.customers)
            ..where((tbl) => tbl.id.equals(id)))
          .getSingleOrNull();
      if (existing == null) {
        throw ValidationException('Customer not found.');
      }

      final companion = CustomersCompanion(
        fullName: Value(fullName.trim()),
        email: Value(email?.trim()),
        phone: Value(phone?.trim()),
        address: Value(address?.trim()),
        note: Value(note?.trim()),
      );

      await (_db.update(_db.customers)..where((tbl) => tbl.id.equals(id)))
          .write(companion);

      final row = await (_db.select(_db.customers)
            ..where((tbl) => tbl.id.equals(id)))
          .getSingle();
      return _mapRow(row);
    } catch (e) {
      if (e is ValidationException || e is DatabaseException) rethrow;
      throw DatabaseException('Unable to update customer: $e');
    }
  }

  Future<void> deleteCustomer(String id) async {
    try {
      final deleted = await (_db.delete(_db.customers)
            ..where((tbl) => tbl.id.equals(id)))
          .go();
      if (deleted == 0) {
        throw ValidationException('Customer not found.');
      }
    } catch (e) {
      if (e is ValidationException || e is DatabaseException) rethrow;
      throw DatabaseException('Unable to delete customer: $e');
    }
  }

  UserModel _mapRow(Customer row) {
    return UserModel(
      id: row.id,
      fullName: row.fullName,
      email: row.email ?? '',
      phone: row.phone ?? '',
      role: 'customer',
      createdAt: row.createdAt,
      isActive: row.isActive,
    );
  }
}
