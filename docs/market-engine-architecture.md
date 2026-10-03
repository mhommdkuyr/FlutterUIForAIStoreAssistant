# Yemeni Market Engine

## Product surfaces

Customer:
- search product/store
- use current GPS or the Ibb default/manual location
- nearby offers sorted by distance then price
- OSM interactive map
- store phone/WhatsApp
- external directions
- no account required for discovery

Merchant:
- existing inventory/sales/analytics features remain available
- capture branch coordinates
- future cloud sync through the market backend
- claim and maintain a public store profile

## Data model

A canonical product is separate from a store offer.

store -> offer -> canonical product

This avoids treating the same SKU in multiple shops as separate products.

## Location model

The app gets a device position from GPS only after user permission.
Store coordinates are stored once and reused for proximity queries.
The backend performs geospatial filtering with PostGIS; the client does not
need a paid map request to calculate straight-line distance.

## Maps

Interactive tiles use OpenStreetMap with attribution. No tile scraping,
prefetching, or bulk tile downloads are part of the application.

Directions open an external maps application/URL, so the core proximity
feature does not require a routing API on every tap.

## Source policy

- OSM: durable seed data with its license/attribution.
- Merchant-entered data: authoritative for price/availability after consent.
- Google Places: official API only; do not copy restricted Google fields into
  the canonical database unless a permitted use/license/merchant-provided
  source supports it.
- Open Food Facts: barcode enrichment with source and image-license tracking.

## Coverage QA

Coverage is measured using 250 m QA cells. Empty cells become work items for
OSM review, field collection, or merchant outreach. A coverage percentage is
a quality indicator, not proof of complete real-world discovery.
