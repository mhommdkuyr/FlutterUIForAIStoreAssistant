import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../shared/models/product_model.dart';
import '../../shared/models/sale_model.dart';
import 'product_repository.dart';
import 'repository_exceptions.dart';

class SaleRepository {
  final AppDatabase _db = AppDatabase.instance;
  final ProductRepository _products = ProductRepository();

  Future<SaleModel> createSale({
    required List<ProductModel> items,
    required double discount,
    required String workerId,
    String? customerId,
    String? customerName,
    String? branchId,
    String paymentMethod = 'cash',
  }) async {
    if (items.isEmpty) {
      throw ValidationException('Add at least one product to complete the sale.');
    }
    if (discount < 0) {
      throw ValidationException('Discount cannot be negative.');
    }

    try {
      final subtotal = items.fold<double>(0, (sum, item) => sum + (item.sellingPrice * item.quantity));
      final total = (subtotal - discount).clamp(0, double.infinity).toDouble();

      final saleId = Uuid().v4();
      final now = DateTime.now();

      await _db.transaction(() async {
        await _db.into(_db.sales).insert(SalesCompanion(
          id: Value(saleId),
          subtotal: Value(subtotal),
          discount: Value(discount),
          total: Value(total),
          customerId: Value(customerId),
          customerName: Value(customerName),
          workerId: Value(workerId),
          branchId: Value(branchId),
          createdAt: Value(now),
          paymentMethod: Value(paymentMethod),
        ));

        for (final item in items) {
          final quantity = item.quantity;
          if (quantity <= 0) {
            throw ValidationException('Quantity must be greater than zero.');
          }

          await _db.into(_db.saleItems).insert(SaleItemsCompanion(
            id: Value(Uuid().v4()),
            saleId: Value(saleId),
            productId: Value(item.id),
            productName: Value(item.name),
            quantity: Value(quantity),
            unitPrice: Value(item.sellingPrice),
            totalPrice: Value(item.sellingPrice * quantity),
          ));
        }
      });

      return SaleModel(
        id: saleId,
        items: items.map((p) => SaleItemModel(
              productId: p.id,
              productName: p.name,
              quantity: p.quantity,
              unitPrice: p.sellingPrice,
              totalPrice: p.sellingPrice * p.quantity,
            )).toList(),
        subtotal: subtotal,
        discount: discount,
        total: total,
        customerId: customerId,
        customerName: customerName,
        workerId: workerId,
        branchId: branchId,
        createdAt: now,
        paymentMethod: paymentMethod,
      );
    } catch (e) {
      if (e is ValidationException || e is DatabaseException) {
        rethrow;
      }
      throw DatabaseException('Unable to create sale: $e');
    }
  }

  /// Watches the most recent [limit] sales as a reactive stream.
  ///
  /// Emits a new list automatically whenever the sales table changes,
  /// so the UI refreshes without manual reloads.
  Stream<List<SaleModel>> watchRecentSales({int limit = 50}) {
    return (_db.select(_db.sales)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .watch()
        .asyncMap((rows) async {
      final result = <SaleModel>[];
      for (final row in rows) {
        final saleItems = await (_db.select(_db.saleItems)
              ..where((tbl) => tbl.saleId.equals(row.id)))
            .get();
        result.add(SaleModel(
          id: row.id,
          items: saleItems
              .map((item) => SaleItemModel(
                    productId: item.productId,
                    productName: item.productName,
                    quantity: item.quantity,
                    unitPrice: item.unitPrice,
                    totalPrice: item.totalPrice,
                  ))
              .toList(),
          subtotal: row.subtotal,
          discount: row.discount,
          total: row.total,
          customerId: row.customerId,
          customerName: row.customerName,
          workerId: row.workerId,
          branchId: row.branchId,
          createdAt: row.createdAt,
          paymentMethod: row.paymentMethod,
        ));
      }
      return result;
    });
  }

  Future<List<SaleModel>> getRecentSales() async {
    try {
      final rows = await (_db.select(_db.sales)
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
            ..limit(10))
          .get();
      final items = <SaleModel>[];
      for (final row in rows) {
        final saleItems = await (_db.select(_db.saleItems)
              ..where((tbl) => tbl.saleId.equals(row.id)))
            .get();
        items.add(SaleModel(
          id: row.id,
          items: saleItems.map((item) => SaleItemModel(
                productId: item.productId,
                productName: item.productName,
                quantity: item.quantity,
                unitPrice: item.unitPrice,
                totalPrice: item.totalPrice,
              )).toList(),
          subtotal: row.subtotal,
          discount: row.discount,
          total: row.total,
          customerId: row.customerId,
          customerName: row.customerName,
          workerId: row.workerId,
          branchId: row.branchId,
          createdAt: row.createdAt,
          paymentMethod: row.paymentMethod,
        ));
      }
      return items;
    } catch (e) {
      throw DatabaseException('Unable to load sales: $e');
    }
  }

  Future<double> getTodayRevenue() async {
    try {
      final today = DateTime.now();
      final start = DateTime(today.year, today.month, today.day);
      final end = start.add(const Duration(days: 1));
      final rows = await (_db.select(_db.sales)
            ..where((tbl) => tbl.createdAt.isBetweenValues(start, end)))
          .get();
      return rows.fold<double>(0, (sum, row) => sum + row.total);
    } catch (e) {
      throw DatabaseException('Unable to load today revenue: $e');
    }
  }

  Future<double> getTodayProfit() async {
    try {
      final today = DateTime.now();
      final start = DateTime(today.year, today.month, today.day);
      final end = start.add(const Duration(days: 1));
      final rows = await (_db.select(_db.sales)
            ..where((tbl) => tbl.createdAt.isBetweenValues(start, end)))
          .get();
      double profit = 0;
      for (final row in rows) {
        final items = await (_db.select(_db.saleItems)
              ..where((tbl) => tbl.saleId.equals(row.id)))
            .get();
        for (final item in items) {
          final product = await _products.getProductById(item.productId);
          if (product != null) {
            profit += item.totalPrice - (product.purchasePrice * item.quantity);
          }
        }
      }
      return profit;
    } catch (e) {
      throw DatabaseException('Unable to load today profit: $e');
    }
  }
}
