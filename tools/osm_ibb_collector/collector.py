#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import time
from pathlib import Path
from typing import Any, Iterator

import pandas as pd
import requests

DEFAULT_BBOX = (13.93, 44.13, 14.03, 44.22)
ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]
USER_AGENT = os.getenv(
    "MARKET_ENGINE_USER_AGENT",
    "YemeniMarketEngine/0.1 (OSM collection; replace-with-contact)",
)
QUERY_TEMPLATE = """
[out:json][timeout:180];
(
  nwr["shop"]({bbox});
  nwr["amenity"~"marketplace|restaurant|cafe|fast_food|pharmacy|fuel"]({bbox});
  nwr["craft"]({bbox});
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

def tile_boxes(bbox: tuple[float, float, float, float], tile_km: float) -> Iterator[tuple[float, float, float, float]]:
    south, west, north, east = bbox
    lat_step = tile_km / 111.32
    lat = south
    while lat < north:
        next_lat = min(north, lat + lat_step)
        mid_lat = (lat + next_lat) / 2
        lon_step = tile_km / (111.32 * max(math.cos(math.radians(mid_lat)), 0.1))
        lon = west
        while lon < east:
            next_lon = min(east, lon + lon_step)
            yield (lat, lon, next_lat, next_lon)
            lon = next_lon
        lat = next_lat

def make_query(bbox: tuple[float, float, float, float]) -> str:
    return QUERY_TEMPLATE.format(bbox=",".join(str(x) for x in bbox))

def request(session: requests.Session, endpoint: str, query: str) -> dict[str, Any]:
    response = session.post(
        endpoint,
        data=query.encode("utf-8"),
        headers={
            "User-Agent": USER_AGENT,
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        },
        timeout=240,
    )
    response.raise_for_status()
    return response.json()

def collect_tile(session: requests.Session, query: str) -> tuple[dict[str, Any], str]:
    failures: list[str] = []
    for endpoint in ENDPOINTS:
        delay = 2.0
        for attempt in range(4):
            try:
                return request(session, endpoint, query), endpoint
            except (requests.RequestException, ValueError) as exc:
                failures.append(f"{endpoint}: {exc}")
                if attempt < 3:
                    time.sleep(delay)
                    delay = min(delay * 2, 30)
        time.sleep(2)
    raise RuntimeError("All Overpass endpoints failed: " + " | ".join(failures))

def location(element: dict[str, Any]) -> tuple[float | None, float | None]:
    if element.get("type") == "node":
        return element.get("lat"), element.get("lon")
    center = element.get("center") or {}
    return center.get("lat"), center.get("lon")

def normalize(element: dict[str, Any], collected_at: str) -> dict[str, Any]:
    tags = element.get("tags") or {}
    lat, lon = location(element)
    ref = f"osm:{element.get('type')}:{element.get('id')}"
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
        "source_ref": ref,
        "source_license": "ODbL 1.0",
        "collected_at": collected_at,
    }


def coverage_cells(rows: list[dict[str, Any]], bbox: tuple[float, float, float, float], step_m: int = 300) -> tuple[int, int, list[dict[str, int]]]:
    south, west, north, east = bbox
    lat_step = step_m / 111_320
    cells: set[tuple[int, int]] = set()
    occupied: set[tuple[int, int]] = set()
    lat = south
    while lat <= north:
        lon_step = step_m / (111_320 * max(math.cos(math.radians(lat)), 0.1))
        lon = west
        row_index = math.floor((lat - south) / lat_step)
        while lon <= east:
            col_index = math.floor((lon - west) / lon_step)
            cells.add((row_index, col_index))
            lon += lon_step
        lat += lat_step
    for row in rows:
        if row.get("latitude") is None or row.get("longitude") is None:
            continue
        rlat = float(row["latitude"])
        rlon = float(row["longitude"])
        lon_step = step_m / (111_320 * max(math.cos(math.radians(rlat)), 0.1))
        occupied.add((
            math.floor((rlat - south) / lat_step),
            math.floor((rlon - west) / lon_step),
        ))
    empty = [
        {"cell_row": r, "cell_col": c}
        for r, c in sorted(cells - occupied)
    ]
    return len(occupied), len(cells), empty

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bbox-json", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("output"))
    parser.add_argument("--tile-km", type=float, default=0.3)
    parser.add_argument("--pause-seconds", type=float, default=0.8)
    parser.add_argument("--grid-step-m", type=int, default=300)\n    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    bbox = bbox_from_file(args.bbox_json)
    tiles = list(tile_boxes(bbox, max(0.5, args.tile_km)))
    if args.dry_run:
        print(json.dumps({
            "bbox": bbox,
            "tile_count": len(tiles),
            "tile_km": args.tile_km,
            "endpoints": ENDPOINTS,
        }, indent=2))
        return 0

    session = requests.Session()
    collected_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    unique: dict[tuple[str, int], dict[str, Any]] = {}
    endpoint_counts: dict[str, int] = {}

    for index, tile in enumerate(tiles, start=1):
        print(
            f"[tile {index}/{len(tiles)}] "
            f"bbox={','.join(f'{value:.6f}' for value in tile)}",
            flush=True,
        )
        data, endpoint = collect_tile(session, make_query(tile))
        endpoint_counts[endpoint] = endpoint_counts.get(endpoint, 0) + 1
        for element in data.get("elements") or []:
            key = (str(element.get("type")), int(element.get("id")))
            unique.setdefault(key, normalize(element, collected_at))
        if index < len(tiles):
            time.sleep(max(0.0, args.pause_seconds))

    rows = list(unique.values())
    out = args.output_dir
    out.mkdir(parents=True, exist_ok=True)
    frame = pd.DataFrame(rows)
    if not frame.empty:
        frame = frame.sort_values(
            ["shop", "amenity", "craft", "name"],
            na_position="last",
        )
    frame.to_csv(out / "ibb_osm_stores.csv", index=False, encoding="utf-8-sig")
    frame.to_excel(out / "ibb_osm_stores.xlsx", index=False)
    occupied_cells, total_cells, empty_cells = coverage_cells(rows, bbox, step_m=args.grid_step_m)
    with (out / "ibb_empty_coverage_cells.csv").open(
        "w",
        encoding="utf-8-sig",
        newline="",
    ) as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["cell_row", "cell_col"],
        )
        writer.writeheader()
        writer.writerows(empty_cells)

    (out / "ibb_osm_stores.json").write_text(
        json.dumps(rows, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    audit = {
        "source": "OpenStreetMap via Overpass",
        "bbox": dict(
            south=bbox[0],
            west=bbox[1],
            north=bbox[2],
            east=bbox[3],
        ),
        "tile_km": args.tile_km,
        "tile_count": len(tiles),
        "endpoint_counts": endpoint_counts,
        "feature_count": len(rows),
        "coverage_cells_300m": occupied_cells,
        "total_cells_300m": total_cells,
        "empty_cells_300m": len(empty_cells),
        "coverage_percent": round((occupied_cells / total_cells) * 100, 2) if total_cells else 0,
        "license": "ODbL 1.0",
        "tiles_downloaded": False,
        "collected_at": collected_at,
        "note": "This is a mapped-feature coverage indicator, not proof of complete real-world discovery.",
    }
    (out / "run_audit.json").write_text(
        json.dumps(audit, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(json.dumps(audit, ensure_ascii=False, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
