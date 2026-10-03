# Market Engine implementation

## Customer

/market provides OpenStreetMap tiles with attribution, device GPS after permission,
nearby product/price/availability search, store contact actions, and external directions.
PostGIS performs server-side proximity search when Supabase is configured.

## Merchant

/merchant/catalog provides an owned store profile, GPS capture, product/price/availability
publishing, and CSV/JSON bulk import. Ownership is enforced in Postgres.

## Administration

/market/admin provides market counts, seven-day offer freshness, and pending store-claim review.
Administrative authorization comes from auth.jwt()->'app_metadata'->>'role'. The app UI is not
the security boundary.

## Data model

market_products is the canonical product entity.
market_offers is the merchant-specific price and availability record.
market_price_history stores observations.

The merchant upsert function reuses products by barcode or normalized Arabic name before
creating a new canonical product.

## Coverage

The OSM collector tiles the Ibb bounding box and produces CSV/XLSX/JSON, a 250 m QA coverage
audit, and empty-cell output for field follow-up. Cross-source deduplication is available.

Google Places remains API-only. A missing API secret skips the collection job instead of
scraping the public Google Maps website.

## External setup

Cloud features require a Supabase project, the mobile build defines SUPABASE_URL and
SUPABASE_PUBLISHABLE_KEY, and the migration files must be applied.

Google collection requires a repository secret GOOGLE_MAPS_API_KEY with the required Places API
enabled. OSM tiles do not need an app key, but production deployments must obey the OSM tile
usage policy or use an OSM-derived provider.
