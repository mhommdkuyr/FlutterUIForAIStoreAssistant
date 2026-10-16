# Supabase backend for Yemeni Market Engine

Public catalog and geospatial search live here.

Flutter build configuration:
- SUPABASE_URL
- SUPABASE_PUBLISHABLE_KEY

Only a publishable client key belongs in the mobile app. Never ship a service-role key.

Tables:
market_stores, market_products, market_offers, market_price_history,
merchant_store_claims, market_favorites.

The migration enables RLS and explicit Data API grants for public reads and
the search RPC. Apply it only after connecting a real Supabase project.
