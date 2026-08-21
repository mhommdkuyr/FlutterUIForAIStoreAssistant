#!/usr/bin/env python3
"""Validate the Yemen food catalog seed without external dependencies."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "data" / "yemen_food_catalog_seed.json"
TAXONOMY = ROOT / "data" / "yemen_food_taxonomy.json"

REQUIRED_PRODUCT_FIELDS = {
    "id",
    "nameAr",
    "brand",
    "category",
    "source",
    "sourceUrl",
    "sourceType",
    "imageUrls",
    "priceYER",
    "openingQuantity",
    "barcode",
}


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def validate_catalog(data: dict) -> tuple[int, int]:
    products = data.get("products")
    if not isinstance(products, list) or not products:
        raise ValueError("products must be a non-empty list")

    ids: set[str] = set()
    observed = 0
    brand_families = 0

    for index, product in enumerate(products, start=1):
        if not isinstance(product, dict):
            raise ValueError(f"product #{index} is not an object")
        missing = REQUIRED_PRODUCT_FIELDS - set(product)
        if missing:
            raise ValueError(f"product #{index} missing fields: {sorted(missing)}")
        product_id = product["id"]
        if not isinstance(product_id, str) or not product_id:
            raise ValueError(f"product #{index} has invalid id")
        if product_id in ids:
            raise ValueError(f"duplicate product id: {product_id}")
        ids.add(product_id)
        if product["sourceType"] == "observed_listing":
            observed += 1
        elif product.get("productType") == "brand_family" or product.get("productType") == "catalog_family":
            brand_families += 1

        if product["priceYER"] is not None:
            raise ValueError(f"seed price must remain null for {product_id}")
        if product["openingQuantity"] is not None:
            raise ValueError(f"seed quantity must remain null for {product_id}")
        if product["imageUrls"] is not None and not isinstance(product["imageUrls"], list):
            raise ValueError(f"imageUrls must be a list for {product_id}")

    return len(products), observed


def validate_taxonomy(data: dict) -> int:
    foods = data.get("foods")
    if not isinstance(foods, list) or not foods:
        raise ValueError("foods must be a non-empty list")
    for index, food in enumerate(foods, start=1):
        if not isinstance(food, dict) or not food.get("category") or not food.get("nameEn"):
            raise ValueError(f"taxonomy entry #{index} is incomplete")
    return len(foods)


def main() -> None:
    catalog = load_json(CATALOG)
    taxonomy = load_json(TAXONOMY)
    product_count, observed_count = validate_catalog(catalog)
    taxonomy_count = validate_taxonomy(taxonomy)
    print(f"catalog_products={product_count}")
    print(f"observed_listing_products={observed_count}")
    print(f"taxonomy_foods={taxonomy_count}")
    print("validation=PASS")


if __name__ == "__main__":
    main()
