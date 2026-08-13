# Repository State Analysis — Smart Visual Cashier

This document records the current repository state for the requested product direction: a commercial, offline-first mobile POS and inventory system where visual recognition is the primary selling path, barcode is secondary, and cloud services are added behind a synchronization and AI execution layer.

## What already exists

- The repository is primarily a Flutter application (`pubspec.yaml`) with Drift, camera, barcode scanning, image processing, TFLite, local storage, routing, localization, and charting dependencies already declared.
- A leftover React/Vite surface also exists (`src/`, `package.json`, `vite.config.ts`), but it is not the active mobile architecture described by the product requirements.
- The Flutter entry point initializes local storage, authentication, the Drift database, app routing, theming, and Arabic/English localization.
- The app already has screens for onboarding, authentication, merchant and worker dashboards, customer search, inventory, scanner, live scanner, sales, invoice, debts, analytics, branches, marketing, AI assistant, and settings.
- Drift schema support exists for products, product variants, product images, product embeddings, product drafts, inventory movements, sales, sale items, debts, branches, customers, and promotions.
- Repository classes exist for core commercial entities, including products, variants, inventory movements, sales, customers, debts, branches, and promotions.
- A local visual-recognition pipeline exists with frame skipping, local embedding generation, local index search, confidence filtering, temporal confirmation, and scan-lock deduplication.
- AI assistant routing exists, but currently focuses mainly on navigation and provider-based responses rather than permission-checked business tool execution.
- Sync is represented only as a placeholder service and is not yet an offline operation queue or conflict-handling implementation.
- Automated Flutter tests already exist for database/repository behavior, inventory movements, scanner lock behavior, recognition pipeline behavior, and visual recognition integration.

## What can be reused

- The Flutter + Drift foundation can be reused as the mobile/offline base.
- The existing visual-recognition services can be reused as the starting point for local visual product identity and scan-confirmation behavior.
- The current product image, embedding, draft, variant, and inventory movement tables can be reused as early schema pieces for product identity, product variants, and stock ledger design.
- The existing repositories can be reused temporarily, but business-sensitive operations should move behind use cases before further feature growth.
- Existing screens can be reused as UI shells, provided they stop owning business rules directly.
- Existing tests are useful as a regression baseline for the next phase.

## What needs modification

- There are two database definitions under `lib/core/database` and `lib/database`; the project should converge on one canonical Drift database module to avoid architectural drift.
- Sales currently decrement product quantity directly during checkout. The target architecture requires inventory movements to be the source of truth, so sales should record sale items and stock movements in one transaction, then derive stock from the ledger or from a clearly documented cache.
- Product creation and updates currently treat `Products.quantity` as mutable stock. This must be transitioned toward movement-based stock without introducing contradictory truth sources.
- The live scanner screen currently uses barcode detection as the operational path. It should be adapted to use the visual recognition pipeline as primary, with barcode fallback.
- Product search and sales flows need shared live-invoice state instead of per-screen private cart implementations.
- Product images need a complete persistence flow from capture/picker to local durable storage to `ProductImages`, then embedding/index refresh.
- Permissions need to be enforced in business/use-case services, not just hidden in UI.
- AI commands need an execution layer: parse intent, select tool, check permissions, call a use case, and return an auditable result.
- Configuration such as exchange rates and plan limits should move into updateable settings/configuration rather than hard-coded UI/business logic.

## What should be rebuilt or refactored

- Rebuild the business operation layer around explicit use cases before adding more features. Examples: `CreateProductUseCase`, `AddProductImagesUseCase`, `CreateSaleUseCase`, `RecordDebtPaymentUseCase`, and `CheckPermissionUseCase`.
- Refactor checkout and inventory writes so inventory movement records become the accountable source for stock changes.
- Refactor scanner selling so camera-based visual recognition becomes the primary path and barcode is only a fallback.
- Refactor the assistant from chat/navigation into a safe command executor that never reaches the database directly.
- Refactor cart/invoice state into a shared live-invoice module used by manual sales, scanner sales, text assistant, and voice assistant.

## What should be deleted or quarantined

- Do not delete code in the next phase unless the owner approves it.
- The React/Vite files should be quarantined as unrelated legacy/demo surface or removed in a dedicated cleanup phase after confirmation that Flutter is the only supported app target.
- One of the duplicate Drift database trees should be retired only after confirming which generated files, imports, and tests are authoritative.
- Seed/demo data should not be used as production business data; keep it only as development seeding until a proper onboarding/demo-mode decision is made.

## What is missing

- A documented domain/use-case boundary.
- Permission models and permission-checking services in the business layer.
- Offline sync operation queue, sync status tracking, remote IDs, conflict policy, and retry handling.
- Store/user/session separation suitable for multi-store and worker accounts.
- Audit log for sensitive operations.
- Subscription/plan limit enforcement.
- Cloud catalog data model and merchant-product/reference-product separation.
- Full assistant conversation persistence by user and store.
- Invoice document generation for print/share.
- Durable local image capture flow connected to embeddings and recognition refresh.
- Secure secret handling and local data protection plan.

## Smallest recommended next implementation phase

### Phase: inventory-ledger sale transaction hardening

Goal: make checkout create an auditable inventory movement for every sold item, while preserving the existing UI and avoiding broad schema changes.

Allowed files:

- `lib/shared/repositories/sale_repository.dart`
- `lib/shared/repositories/inventory_movement_repository.dart` only if needed
- `test/database_repository_test.dart` or a new focused sale/inventory test
- generated files only if a necessary Drift generation command changes them

Forbidden files:

- Database table definitions and schema version
- Scanner UI
- AI assistant
- Settings/subscriptions
- React/Vite files

Acceptance checks:

- A sale inserts sale rows and sale-item rows as it does now.
- A sale also records an inventory movement with movement type `sale` or an agreed equivalent outbound type.
- Stock validation still prevents overselling.
- Existing tests pass.
- A focused test proves that checkout creates the expected movement records.

Reason this is the smallest safe next phase: it addresses the current contradiction between direct quantity mutation and the required movement-ledger architecture without changing the database schema or starting unrelated feature work.
