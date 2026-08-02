import '../../database/app_database.dart';
import '../../database/repositories/branch_repository.dart';
import '../../database/repositories/customer_repository.dart';
import '../../database/repositories/debt_repository.dart';
import '../../database/repositories/employee_repository.dart';
import '../../database/repositories/inventory_movement_repository.dart';
import '../../database/repositories/product_repository.dart';
import '../../database/repositories/sale_repository.dart';
import '../../database/repositories/store_repository.dart';
import '../../database/sync/sync_service.dart';

/// Simple service locator (poor-man's DI container).
///
/// Holds a single [AppDatabase] instance and exposes lazily-created
/// repository accessors. Replace with `get_it`, `riverpod`, or
/// `injectable` when the project grows.
///
/// ## Usage
/// ```dart
/// // In main.dart, initialise once:
/// await ServiceLocator.init();
///
/// // Anywhere in the app:
/// final products = await ServiceLocator.products.getAll();
/// ```
///
/// ## Replacing for tests
/// ```dart
/// ServiceLocator.overrideDatabase(AppDatabase(NativeDatabase.memory()));
/// ```
class ServiceLocator {
  ServiceLocator._();

  static AppDatabase? _db;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Initialises the service locator and opens the database connection.
  ///
  /// Must be called once before any other accessor is used, typically
  /// at the top of `main()` before [runApp].
  static Future<void> init() async {
    _db ??= AppDatabase();
  }

  /// Replaces the active database instance (for testing / hot-swap).
  ///
  /// Call [close] first if an existing database is open.
  static void overrideDatabase(AppDatabase db) => _db = db;

  /// Closes the database connection and clears the cached instance.
  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ── Database ──────────────────────────────────────────────────────────────

  /// The shared [AppDatabase] instance. Throws if [init] has not been called.
  static AppDatabase get database {
    assert(_db != null, 'ServiceLocator.init() must be called before use.');
    return _db!;
  }

  // ── Repositories ──────────────────────────────────────────────────────────

  /// Repository for [Store] entities.
  static StoreRepository get stores => StoreRepository(database.storesDao);

  /// Repository for [Branch] entities.
  static BranchRepository get branches =>
      BranchRepository(database.branchesDao);

  /// Repository for [Employee] entities.
  static EmployeeRepository get employees =>
      EmployeeRepository(database.employeesDao);

  /// Repository for [Product] entities.
  static ProductRepository get products =>
      ProductRepository(database.productsDao);

  /// Repository for [Sale] entities.
  static SaleRepository get sales => SaleRepository(database.salesDao);

  /// Repository for [Customer] entities.
  static CustomerRepository get customers =>
      CustomerRepository(database.customersDao);

  /// Repository for [Debt] entities.
  static DebtRepository get debts => DebtRepository(database.debtsDao);

  /// Repository for [InventoryMovement] entities.
  static InventoryMovementRepository get inventoryMovements =>
      InventoryMovementRepository(database.inventoryMovementsDao);

  // ── Services ──────────────────────────────────────────────────────────────

  /// Placeholder sync service.
  ///
  /// TODO(sync): inject real dependencies when cloud sync is implemented.
  static SyncService get sync => SyncService();
}
