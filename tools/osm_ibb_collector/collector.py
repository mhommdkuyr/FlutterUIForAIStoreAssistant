#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import os
import time
from pathlib import Path
from typing import Any

import pandas as pd
import requests

DEFAULT_BBOX = (13.92, 44.12, 14.03, 44.25)
ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]
USER_AGENT = os.getenv(
    "MARKET_ENGINE_USER_AGENT",
    "YemeniMarketEngine/0.1 (OSM collection; replace-with-contact)",
)

QUERY = """
[out:json][timeout:120];
(
  nwr["shop"](BBOX);
  nwr["amenity"~"marketplace|restaurant|cafe|fast_food|pharmacy|fuel"](BBOX);
  nwr["craft"](BBOX);
);
out center tags;
"""


def bbox_from_file(path: Path | None) -> tuple[float, float, float, float]:
    if path is None:
        return DEFAULT_BBOX
    data = json.loads(path.read_text(encoding="utf-8"))
    return (
        float(data["south"]),
        float(data["west"]),
        float(data["north"]),
        float(data["east"]),
    )


def make_query(bbox: tuple[float, float, float, float]) -> str:
    return QUERY.replace("BBOX", ",".join(str(v) for v in bbox))


def request(endpoint: str, query: str) -> dict[str, Any]:
    response = requests.post(
        endpoint,
        data=query.encode("utf-8"),
        headers={
            "User-Agent": USER_AGENT,
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        },
        timeout=180,
    )
    response.raise_for_status()
    return response.json()


def collect(query: str) -> tuple[dict[str, Any], str]:
    failures = []
    for endpoint in ENDPOINTS:
        delay = 2.0
        for attempt in range(3):
            try:
                return request(endpoint, query), endpoint
            except (requests.RequestException, ValueError) as exc:
                failures.append(f"{endpoint}: {exc}")
                if attempt < 2:
                    time.sleep(delay)
                    delay = min(delay * 2, 20)
        time.sleep(2)
    raise RuntimeError("All Overpass endpoints failed: " + " | ".join(failures))


def location(element: dict[str, Any]) -> tuple[float | None, float | None]:
    if element.get("type") == "node":
        return element.get("lat"), element.get("lon")
    center = element.get("center") or {}
    return center.get("lat"), center.get("lon")


def normalize(element: dict[str, Any]) -> dict[str, Any]:
    tags = element.get("tags") or {}
    lat, lon = location(element)
    return {
        "osm_type": element.get("type"),
        "osm_id": element.get("id"),
        "name": tags.get("name"),
        "name_ar": tags.get("name:ar"),
        "shop": tags.get("shop"),
        "amenity": tags.get("amenity"),
        "craft": tags.get("craft"),
        "brand": tags.get("brand"),
        "phone": tags.get("phone") or tags.get("contact:phone"),
        "website": tags.get("website") or tags.get("contact:website"),
        "opening_hours": tags.get("opening_hours"),
        "address": tags.get("addr:full")
        or " ".join(
            part
            for part in (
                tags.get("addr:street"),
                tags.get("addr:housenumber"),
                tags.get("addr:place"),
            )
            if part
        ),
        "latitude": lat,
        "longitude": lon,
        "source": "openstreetmap",
        "source_license": "ODbL 1.0",
    }


def coverage_cells(rows: list[dict[str, Any]], step_m: int = 250) -> int:
    cells = set()
    for row in rows:
        lat = row.get("latitude")
        lon = row.get("longitude")
        if lat is None or lon is None:
            continue
        lat_step = step_m / 111_320
        lon_step = step_m / (111_320 * max(math.cos(math.radians(lat)), 0.1))
        cells.add((math.floor(lat / lat_step), math.floor(lon / lon_step)))
    return len(cells)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bbox-json", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("output"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    bbox = bbox_from_file(args.bbox_json)
    query = make_query(bbox)

    if args.dry_run:
        print(json.dumps(
            {"bbox": bbox, "endpoints": ENDPOINTS, "query_bytes": len(query.encode())},
            indent=2,
        ))
        return 0

    data, endpoint = collect(query)
    rows = []
    seen = set()
    for element in data.get("elements") or []:
        key = (element.get("type"), element.get("id"))
        if key in seen:
            continue
        seen.add(key)
        rows.append(normalize(element))

    args.output_dir.mkdir(parents=True, exist_ok=True)
    df = pd.DataFrame(rows)
    if not df.empty:
        df = df.sort_values(["shop", "amenity", "name"], na_position="last")
    df.to_csv(args.output_dir / "ibb_osm_stores.csv", index=False, encoding="utf-8-sig")
    df.to_excel(args.output_dir / "ibb_osm_stores.xlsx", index=False)
    (args.output_dir / "ibb_osm_stores.json").write_text(
        json.dumps(rows, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    audit = {
        "source": "OpenStreetMap via Overpass",
        "endpoint": endpoint,
        "bbox": bbox,
        "feature_count": len(rows),
        "coverage_cells_250m": coverage_cells(rows),
        "license": "ODbL 1.0",
        "tiles_downloaded": False,
    }
    (args.output_dir / "run_audit.json").write_text(
        json.dumps(audit, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(json.dumps(audit, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
