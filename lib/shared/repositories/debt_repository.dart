import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../shared/models/debt_model.dart';
import 'repository_exceptions.dart';

class DebtRepository {
  final AppDatabase _db = AppDatabase.instance;

  Future<List<DebtModel>> getDebts() async {
    try {
      final rows = await (_db.select(_db.debts)
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();
      return rows.map((row) => DebtModel(
            id: row.id,
            customerId: row.customerId ?? '',
            customerName: row.customerName,
            customerPhone: row.customerPhone,
            originalAmount: row.originalAmount,
            payments: const [],
            createdAt: row.createdAt,
            dueDate: row.dueDate,
            note: row.note,
            branchId: row.branchId,
          )).toList();
    } catch (e) {
      throw DatabaseException('Unable to load debts: $e');
    }
  }

  Future<DebtModel> createDebt({required String customerName, required double amount, String? note}) async {
    if (customerName.trim().isEmpty) {
      throw ValidationException('Customer name is required.');
    }
    if (amount <= 0) {
      throw ValidationException('Debt amount must be greater than zero.');
    }

    try {
      final now = DateTime.now();
      final entity = DebtsCompanion(
        id: Value(Uuid().v4()),
        customerName: Value(customerName.trim()),
        originalAmount: Value(amount),
        paidAmount: const Value(0),
        createdAt: Value(now),
        note: Value(note?.trim()),
      );
      await _db.into(_db.debts).insert(entity);
      return DebtModel(
        id: entity.id.value,
        customerId: '',
        customerName: customerName.trim(),
        originalAmount: amount,
        createdAt: now,
        note: note?.trim(),
      );
    } catch (e) {
      if (e is ValidationException) rethrow;
      throw DatabaseException('Unable to save debt: $e');
    }
  }

  Future<DebtModel> recordPayment(String id, double amount) async {
    if (amount <= 0) {
      throw ValidationException('Payment amount must be greater than zero.');
    }
    try {
      final existing = await (_db.select(_db.debts)..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
      if (existing == null) {
        throw ValidationException('Debt not found.');
      }
      final updatedPaid = (existing.paidAmount + amount).clamp(0, existing.originalAmount.toDouble());
      await (_db.update(_db.debts)
            ..where((tbl) => tbl.id.equals(id)))
          .write(DebtsCompanion(paidAmount: Value(updatedPaid)));
      return DebtModel(
        id: existing.id,
        customerId: existing.customerId ?? '',
        customerName: existing.customerName,
        customerPhone: existing.customerPhone,
        originalAmount: existing.originalAmount,
        payments: const [],
        createdAt: existing.createdAt,
        dueDate: existing.dueDate,
        note: existing.note,
        branchId: existing.branchId,
      );
    } catch (e) {
      if (e is ValidationException) rethrow;
      throw DatabaseException('Unable to record payment: $e');
    }
  }
}
