#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from typing import Any


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--bbox-json", type=Path, required=True)
    parser.add_argument("--cell-m", type=int, default=250)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    bbox = json.loads(args.bbox_json.read_text(encoding="utf-8"))
    south = float(bbox["south"])
    west = float(bbox["west"])
    north = float(bbox["north"])
    east = float(bbox["east"])

    rows: list[dict[str, Any]] = []
    with args.input.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))

    lat_step = args.cell_m / 111_320
    coverage: dict[tuple[int, int], int] = {}
    total_cells = 0
    lat = south
    while lat <= north:
        lon_step = args.cell_m / (111_320 * max(math.cos(math.radians(lat)), 0.1))
        lon = west
        while lon <= east:
            total_cells += 1
            coverage[(math.floor(lat / lat_step), math.floor(lon / lon_step))] = 0
            lon += lon_step
        lat += lat_step

    for row in rows:
        try:
            rlat = float(row["latitude"])
            rlon = float(row["longitude"])
        except (KeyError, TypeError, ValueError):
            continue
        if not (south <= rlat <= north and west <= rlon <= east):
            continue
        lon_step = args.cell_m / (111_320 * max(math.cos(math.radians(rlat)), 0.1))
        key = (math.floor(rlat / lat_step), math.floor(rlon / lon_step))
        coverage[key] = coverage.get(key, 0) + 1

    populated = sum(1 for count in coverage.values() if count > 0)
    result = {
        "bbox": bbox,
        "cell_m": args.cell_m,
        "total_cells": total_cells,
        "populated_cells": populated,
        "empty_cells": max(0, total_cells - populated),
        "coverage_percent": round((populated / total_cells) * 100, 2) if total_cells else 0,
        "feature_count": len(rows),
        "note": "A populated cell means the source contains at least one mapped feature; it does not prove every business was discovered.",
    }
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
