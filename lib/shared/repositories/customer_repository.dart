import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../shared/models/user_model.dart';
import 'repository_exceptions.dart';

class CustomerRepository {
  final AppDatabase _db = AppDatabase.instance;

  Future<List<UserModel>> getCustomers() async {
    try {
      final rows = await (_db.select(_db.customers)
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();
      return rows.map((row) => UserModel(
            id: row.id,
            fullName: row.fullName,
            email: row.email ?? '',
            phone: row.phone ?? '',
            role: 'customer',
            createdAt: row.createdAt,
            isActive: row.isActive,
          )).toList();
    } catch (e) {
      throw DatabaseException('Unable to load customers: $e');
    }
  }

  Future<UserModel> createCustomer({required String fullName, String? phone, String? email, String? address, String? note}) async {
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
}
