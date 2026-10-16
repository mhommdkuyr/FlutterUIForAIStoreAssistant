# Market data pipeline

1. OpenStreetMap/Overpass: seed directory for stores and services.
2. Google Places API: official API only; use results for permitted discovery/outreach and follow Google's storage/display terms.
3. Merchant registration and store claim: authoritative commercial data.
4. Open Food Facts: barcode enrichment for packaged products where licensing and image terms are satisfied.
5. Supabase/PostGIS: canonical market catalog, offers, freshness and distance search.

Tools:
- ../osm_ibb_collector/collector.py
- ../ibb_google_places_collector/collector.py
- ../openfoodfacts_enricher/enrich.py
- coverage_audit.py
- dedupe_stores.py
- import_osm_to_supabase.py

dedupe_stores.py combines OSM and authorized Google Places exports using normalized
phone/name plus a configurable distance threshold. It does not scrape Google Maps
web pages or copy restricted Google-only fields.

A coverage cell is a QA unit, not a promise that every meter or every business is represented.
Dense mapping data plus merchant onboarding and field collection are required for high recall.

Never ship Google API keys or Supabase service-role keys in the mobile application or repository.
