# Yemen Food Catalog Seed

## What this adds

This seed introduces a merchant-ready Yemen food catalog without changing the camera, ONNX runtime, recognition pipeline, database schema, or APK build workflow.

The important architectural point is that the current scanner does **not** fine-tune MobileCLIP2 from a product list. It enrolls each product by converting one or more local product images into a 512-dimensional MobileCLIP2 embedding and then searches those embeddings in memory during live scanning. The current `LocalProductIndexService` already precomputes and caches these embeddings, so the catalog step should prepare product identities and image references first, then hydrate permitted images and generate embeddings.

## Files

### `data/yemen_food_catalog_seed.json`

Contains:

- observed Yemen grocery SKUs from Bazzarry, with Arabic product names, brand, category and pack size;
- official Yemen brand families from HSA Yemen, Alfogehi and MAFCO;
- product families from Dadiah General Trading;
- merchant fields `priceYER` and `openingQuantity`, intentionally `null` until the merchant chooses a catalog item;
- image URL slots that remain empty until a permitted image source is acquired;
- explicit recognition state so a catalog item is not treated as scan-ready before local image hydration and embedding generation;
- source attribution and usage notes.

### `data/yemen_food_taxonomy.json`

Contains a broad Yemen food taxonomy for category/discovery coverage, including staple grains, legumes, vegetables, fruits, dairy, meats, seafood, sweets, snacks, instant foods, milk/drinks and traditional foods.

## Intended merchant flow

1. Merchant opens **Add Product**.
2. Merchant searches the cloud seed catalog by Arabic name, brand or category.
3. Merchant selects a catalog template.
4. The app opens a product setup page with the catalog identity already filled in.
5. `priceYER` and `openingQuantity` remain blank until the merchant enters their own values.
6. A permitted catalog image is hydrated into the app's local product-image storage.
7. The existing MobileCLIP2 service generates the product embedding from that local image.
8. The existing local product index caches the embedding using the current model version.
9. The product becomes eligible for rapid camera recognition.

This means the merchant does **not** need to photograph the product during initial setup when a permitted catalog image exists. It also avoids changing the existing recognition engine just to populate the catalog.

## Why the dataset is split from model training

MobileCLIP2 in this repository is a fixed ONNX vision encoder. The current implementation validates the expected 224x224 input, CLIP normalization, 512-dimensional output, L2 normalization and ONNX opset, then computes embeddings for local product images. The product identity layer is therefore a vector-index enrollment problem rather than a fine-tuning job.

Trying to fine-tune the model inside this phase would add a new training pipeline, new model artifacts, longer APK/CI work and a much larger failure surface. The safer route is:

**catalog identity -> permitted image -> local image -> MobileCLIP2 embedding -> local index -> fast scan**

## Image rights and data quality

The seed stores product metadata and source references rather than copying third-party images into the repository. The image acquisition step must only use images that the project is authorized to redistribute or cache.

For recognition quality, a final image pack should prefer:

- front-of-pack images with the full label visible;
- 2-5 permitted views for visually similar packages;
- multiple pack sizes as separate catalog SKUs;
- multiple flavor/color variants when the packaging differs;
- clean background plus a smaller set of real-store/background examples as hard negatives.

Do not mark a catalog item as `recognitionReady` until at least one local reference image has been embedded and validated against the current model version.

## Coverage strategy

The catalog is intentionally layered:

- **Exact observed SKUs:** products explicitly listed by a Yemen grocery source.
- **Official brand families:** Yemen manufacturers/distributors that provide additional product breadth even when every SKU is not exposed in a single public listing.
- **Food taxonomy:** broad food categories used to drive future catalog expansion and search.
- **Price reference:** World Bank Yemen food-price data can be used later for market-prior suggestions, but merchant-specific price stays blank in the seed.

This is a starting catalog, not a claim that every Yemen grocery SKU has already been collected or that all source images are reusable.

## Next data-hydration phase

The next safe implementation should be a data importer, not a camera rewrite. It should:

1. read this seed;
2. resolve an authorized image for each eligible SKU;
3. download it to the app/cloud image store;
4. create the local `ProductModel` image path;
5. run the existing MobileCLIP2 embedding service;
6. persist the embedding with `modelVersion`;
7. show only hydrated catalog records as instant-scan-ready.

No camera behavior or ONNX contract needs to change for that flow.
