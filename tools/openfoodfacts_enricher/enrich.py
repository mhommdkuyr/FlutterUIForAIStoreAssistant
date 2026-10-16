#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import time
from pathlib import Path

import requests

BASE = "https://world.openfoodfacts.org/api/v3/product"
USER_AGENT = "YemeniMarketEngine/0.1 (Open Food Facts; replace-with-contact)"
FIELDS = [
    "product_name",
    "product_name_ar",
    "brands",
    "categories",
    "categories_tags",
    "quantity",
    "image_front_url",
    "image_front_small_url",
]


def fetch(barcode: str) -> dict:
    response = requests.get(
        f"{BASE}/{barcode}.json",
        params={"fields": ",".join(FIELDS)},
        headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
        timeout=30,
    )
    response.raise_for_status()
    return response.json()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--barcode-column", default="barcode")
    parser.add_argument("--delay-seconds", type=float, default=4.2)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    with args.input.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))

    result = []
    for index, row in enumerate(rows):
        barcode = (row.get(args.barcode_column) or "").strip()
        if not barcode:
            continue
        if args.dry_run:
            result.append({"barcode": barcode, "status": "dry-run"})
        else:
            try:
                data = fetch(barcode)
                product = data.get("product") or {}
                result.append({
                    "barcode": barcode,
                    "status": data.get("status"),
                    "product_name": product.get("product_name"),
                    "product_name_ar": product.get("product_name_ar"),
                    "brands": product.get("brands"),
                    "categories": product.get("categories"),
                    "categories_tags": "|".join(product.get("categories_tags") or []),
                    "quantity": product.get("quantity"),
                    "image_front_url": product.get("image_front_url"),
                    "image_front_small_url": product.get("image_front_small_url"),
                })
            except requests.RequestException as exc:
                result.append({"barcode": barcode, "status": "error", "error": str(exc)})

        if index < len(rows) - 1:
            time.sleep(max(0, args.delay_seconds))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="") as handle:
        fieldnames = sorted({key for row in result for key in row})
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
