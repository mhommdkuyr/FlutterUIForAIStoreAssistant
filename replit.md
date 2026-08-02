# AI Store Assistant — Flutter Mobile App

An AI-powered retail management platform for grocery stores and small businesses in Yemen and beyond.

## Stack

- **Framework**: Flutter 3.32.0 (Dart 3.5)
- **Database**: Drift (SQLite, offline-first) — `lib/core/database/app_database.dart`
- **Routing**: GoRouter — `lib/core/routing/app_router.dart`
- **Architecture**: Clean Architecture · Repository pattern · Offline-first
- **State**: Local state + Drift reactive streams (no separate state manager)
- **Localization**: English + Arabic (RTL) via `lib/core/i18n/app_translations.dart`

## Running the app

The app targets **Android and iOS**. It cannot run in a browser preview — use a connected device or emulator.

```bash
# Install dependencies
flutter pub get

# Analyze (exits 0 for info-only issues)
flutter analyze --no-fatal-warnings

# Run tests (widget tests + DB repository tests with SQLite graceful skip)
flutter test

# Build debug APK
flutter build apk --debug
```

## Key directory layout

```
lib/
├── core/
│   ├── database/app_database.dart     ← primary Drift DB (used by all screens)
│   ├── di/service_locator.dart        ← future DI; not yet wired to screens
│   ├── i18n/app_translations.dart     ← translations (en/ar)
│   ├── routing/app_router.dart        ← GoRouter configuration
│   └── theme/                         ← light + dark Material3 themes
├── database/                          ← second Drift layer (DAOs + repositories)
│   ├── app_database.dart              ← 8-table schema + DAOs
│   └── repositories/                  ← repository implementations (Step 2 target)
├── features/                          ← one directory per app feature
│   ├── merchant/                      ← merchant dashboard
│   ├── inventory/                     ← product inventory CRUD
│   ├── sales/                         ← fast sales + history
│   ├── debts/                         ← customer debt management
│   ├── analytics/                     ← revenue/profit charts (fl_chart)
│   ├── branches/                      ← branch management
│   ├── customer/                      ← customer search + CRUD
│   ├── ai_assistant/                  ← AI chat (rule-based; Gemini/llama.cpp in Step 2)
│   └── ...
└── shared/
    ├── models/                        ← ProductModel, SaleModel, DebtModel, ...
    ├── repositories/                  ← active repositories used by screens
    └── services/                      ← auth, storage, api stubs
```

## Architecture notes

- **Two Drift database files** coexist intentionally:
  - `lib/core/database/app_database.dart` — the **active** DB, used by all screens via `AppDatabase.instance`
  - `lib/database/app_database.dart` — a richer 8-table schema registered with `ServiceLocator`, targeted for Step 2 migration
- `ServiceLocator` in `lib/core/di/service_locator.dart` is wired to the second DB but not yet used by any screen
- `lib/shared/repositories/` contains the **active** repository layer; `lib/database/repositories/` is the Step 2 target

## CI / GitHub Actions

- `.github/workflows/ci.yml` — Format · Analyze · Test on every push/PR
- `.github/workflows/build.yml` — Release APK build on push to `main`

The build workflow requires three GitHub secrets for signing:
`KEYSTORE_BASE64`, `KEY_STORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`

## Step 2 roadmap (not yet started)

- Connect the Gemini API / llama.cpp AI assistant
- Migrate screens from `lib/shared/repositories/` to the richer `lib/database/repositories/`
- Add offline barcode scanning via `mobile_scanner`
- Enable ONNX vision provider (`lib/features/ai_assistant/services/onnx_vision_provider.dart` — currently a stub)
- Add push notifications (FCM)

## User preferences

- Preserve Clean Architecture and offline-first approach
- Do not increase minimum Dart/Flutter SDK requirements without necessity
- Keep Arabic (RTL) support working
