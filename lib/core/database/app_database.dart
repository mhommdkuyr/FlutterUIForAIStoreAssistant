import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

// ── Phase 2 tables ────────────────────────────────────────────────────────────

/// Stores additional reference images for a product (Phase 2 multi-image).
class ProductImages extends Table {
  TextColumn get id => text()();
  TextColumn get productId => text()();
  TextColumn get localPath => text()();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Caches precomputed visual embeddings for product images (Phase 2).
///
/// Keyed on (productId + imagePath + modelVersion) so embeddings are
/// automatically invalidated when the ML model is upgraded.
class ProductEmbeddings extends Table {
  TextColumn get id => text()();
  TextColumn get productId => text()();
  TextColumn get imagePath => text().nullable()();
  BlobColumn get hashBytes => blob()();

  /// Identifier of the model/algorithm that produced [hashBytes].
  /// e.g. "mv3_small_224_float32_v1" or "ahash_16x16".
  TextColumn get modelVersion =>
      text().withDefault(const Constant(''))();

  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Holds partially-completed product entries awaiting review (Phase 2 drafts).
class ProductDrafts extends Table {
  TextColumn get id => text()();
  TextColumn get source => text()(); // barcode / image / invoice / manual
  TextColumn get rawData => text()(); // JSON snapshot of form state
  TextColumn get status =>
      text().withDefault(const Constant('pending'))(); // pending/reviewed/saved/rejected
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// ─────────────────────────────────────────────────────────────────────────────

class Products extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get category => text()();
  RealColumn get purchasePrice => real()();
  RealColumn get sellingPrice => real()();
  IntColumn get quantity => integer()();
  TextColumn get barcode => text().nullable()();
  TextColumn get imageUrl => text().nullable()();
  TextColumn get description => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get branchId => text().nullable()();
}

class ProductVariants extends Table {
  TextColumn get id => text()();
  TextColumn get productId => text()();
  TextColumn get name => text()();
  RealColumn get sizeValue => real().nullable()();
  TextColumn get sizeUnit => text().nullable()();
  RealColumn get purchasePrice => real()();
  RealColumn get sellingPrice => real()();
  TextColumn get sku => text().nullable()();
  TextColumn get barcode => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Index> get indexes => [
        Index('product_variants_product_id', [productId]),
        Index('product_variants_barcode', [barcode]),
      ];
}

class Sales extends Table {
  TextColumn get id => text()();
  RealColumn get subtotal => real()();
  RealColumn get discount => real().withDefault(const Constant(0))();
  RealColumn get total => real()();
  TextColumn get customerId => text().nullable()();
  TextColumn get customerName => text().nullable()();
  TextColumn get workerId => text()();
  TextColumn get branchId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get paymentMethod => text().withDefault(const Constant('cash'))();
}

class SaleItems extends Table {
  TextColumn get id => text()();
  TextColumn get saleId => text()();
  TextColumn get productId => text()();
  TextColumn get productName => text()();
  IntColumn get quantity => integer()();
  RealColumn get unitPrice => real()();
  RealColumn get totalPrice => real()();
}

class Debts extends Table {
  TextColumn get id => text()();
  TextColumn get customerId => text().nullable()();
  TextColumn get customerName => text()();
  TextColumn get customerPhone => text().nullable()();
  RealColumn get originalAmount => real()();
  RealColumn get paidAmount => real().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get dueDate => dateTime().nullable()();
  TextColumn get note => text().nullable()();
  TextColumn get branchId => text().nullable()();
}

class Branches extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get address => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  RealColumn get dailySales => real().withDefault(const Constant(0))();
  IntColumn get workerCount => integer().withDefault(const Constant(0))();
}

class Customers extends Table {
  TextColumn get id => text()();
  TextColumn get fullName => text()();
  TextColumn get email => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

class Promotions extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get discount => text()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get expiresAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
}

@DriftDatabase(tables: [
  Products,
  Sales,
  SaleItems,
  Debts,
  Branches,
  Customers,
  Promotions,
  ProductImages,
  ProductEmbeddings,
  ProductDrafts,
  ProductVariants,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  static AppDatabase? _instance;
  static AppDatabase get instance => _instance ??= AppDatabase();

  // ── Test helpers ─────────────────────────────────────────────────────────

  /// Replaces the singleton with a custom executor (e.g. in-memory for tests).
  ///
  /// Call before creating any repository instance in a test's [setUp].
  // ignore: invalid_use_of_visible_for_testing_member
  static void overrideForTest(QueryExecutor executor) {
    _instance = AppDatabase(executor);
  }

  /// Clears the singleton so [instance] creates a fresh connection next time.
  ///
  /// Call in a test's [tearDown] after [AppDatabase.instance.close()].
  // ignore: invalid_use_of_visible_for_testing_member
  static void resetForTest() {
    _instance = null;
  }

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(promotions);
          }
          if (from < 3) {
            // Phase 2: multi-image support, embeddings cache, draft queue.
            await m.createTable(productImages);
            await m.createTable(productEmbeddings);
            await m.createTable(productDrafts);
          }
          if (from < 4) {
            // Phase 2 revision: add modelVersion to embeddings cache table.
            // Drop-and-recreate is safe since this is a pure cache.
            await m.drop(productEmbeddings);
            await m.createTable(productEmbeddings);
          }
          if (from < 5) {
            await m.createTable(productVariants);
          }
        },
      );

  Future<void> ensureSeeded() async {
    final productCount = await select(products).get();
    if (productCount.isNotEmpty) return;

    await into(products).insert(ProductsCompanion(
      id: const Value('seed-product-1'),
      name: const Value('Rice (5kg)'),
      category: const Value('Grains'),
      purchasePrice: const Value(2100),
      sellingPrice: const Value(2500),
      quantity: const Value(20),
      barcode: const Value('6281234567890'),
      createdAt: Value(DateTime.now()),
      updatedAt: Value(DateTime.now()),
    ));

    await into(products).insert(ProductsCompanion(
      id: const Value('seed-product-2'),
      name: const Value('Cooking Oil (1L)'),
      category: const Value('Oils'),
      purchasePrice: const Value(1000),
      sellingPrice: const Value(1200),
      quantity: const Value(8),
      barcode: const Value('6281234567891'),
      createdAt: Value(DateTime.now()),
      updatedAt: Value(DateTime.now()),
    ));

    await into(productVariants).insert(ProductVariantsCompanion(
      id: const Value('seed-product-1-variant'),
      productId: const Value('seed-product-1'),
      name: const Value('5kg'),
      sizeValue: const Value(5),
      sizeUnit: const Value('kg'),
      purchasePrice: const Value(2100),
      sellingPrice: const Value(2500),
      createdAt: Value(DateTime.now()),
      updatedAt: Value(DateTime.now()),
    ));

    await into(productVariants).insert(ProductVariantsCompanion(
      id: const Value('seed-product-2-variant'),
      productId: const Value('seed-product-2'),
      name: const Value('1L'),
      sizeValue: const Value(1),
      sizeUnit: const Value('L'),
      purchasePrice: const Value(1000),
      sellingPrice: const Value(1200),
      createdAt: Value(DateTime.now()),
      updatedAt: Value(DateTime.now()),
    ));

    await into(branches).insert(BranchesCompanion(
      id: const Value('seed-branch-1'),
      name: const Value('Main Branch'),
      address: const Value('Tahrir Square, Sana\'a'),
      dailySales: const Value(0),
      workerCount: const Value(4),
    ));
  }

  Future<void> reset() async {
    await close();
    final dbFile = await _databaseFile();
    if (await dbFile.exists()) {
      await dbFile.delete();
    }
    _instance = null;
  }

  static QueryExecutor _openConnection() {
    return LazyDatabase(() async {
      final dbFolder = await _dbDirectory();
      final file = File(p.join(dbFolder.path, 'ai_store_assistant.db'));
      return NativeDatabase.createInBackground(file);
    });
  }

  static Future<File> _databaseFile() async {
    final dbFolder = await _dbDirectory();
    return File(p.join(dbFolder.path, 'ai_store_assistant.db'));
  }

  static Future<Directory> _dbDirectory() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return dir;
    } on MissingPluginException {
      final fallback = Directory.current;
      if (!fallback.existsSync()) {
        fallback.createSync(recursive: true);
      }
      return fallback;
    } on PlatformException {
      final fallback = Directory.current;
      if (!fallback.existsSync()) {
        fallback.createSync(recursive: true);
      }
      return fallback;
    }
  }
}

// The generated file will expose the `Product`, `Sale`, ... row classes.
