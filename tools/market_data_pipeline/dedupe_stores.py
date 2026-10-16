#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import math
import re
from pathlib import Path
from typing import Any

def text(value: Any) -> str:
    return str(value or "").strip()

def normalize_text(value: Any) -> str:
    raw = text(value).lower()
    raw = re.sub(r"[\u064B-\u065F\u0670]", "", raw)
    raw = raw.translate(str.maketrans({"أ":"ا","إ":"ا","آ":"ا","ى":"ي","ة":"ه"}))
    return re.sub(r"[^0-9a-z\u0600-\u06ff]+", "", raw)

def normalize_phone(value: Any) -> str:
    digits = re.sub(r"\D+", "", text(value))
    if digits.startswith("00967"): digits = digits[5:]
    elif digits.startswith("967"): digits = digits[3:]
    return digits[-9:]

def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    radius = 6371008.8
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2) ** 2
    return radius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))

def load_csv(path: Path, source: str) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    for row in rows:
        row["_source"] = source
    return rows

def row_name(row: dict[str, Any]) -> str:
    return text(row.get("name_ar") or row.get("name"))

def same_business(left: dict[str, Any], right: dict[str, Any], max_distance_m: float) -> bool:
    left_phone = normalize_phone(left.get("phone"))
    right_phone = normalize_phone(right.get("phone"))
    if left_phone and right_phone and left_phone == right_phone:
        return True
    left_name = normalize_text(row_name(left))
    right_name = normalize_text(row_name(right))
    if not left_name or not right_name or left_name != right_name:
        return False
    try:
        distance = haversine_m(float(left["latitude"]), float(left["longitude"]), float(right["latitude"]), float(right["longitude"]))
    except (KeyError, TypeError, ValueError):
        return True
    return distance <= max_distance_m

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--osm", type=Path)
    parser.add_argument("--google", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-distance-m", type=float, default=100)
    args = parser.parse_args()

    rows: list[dict[str, Any]] = []
    if args.osm: rows.extend(load_csv(args.osm, "openstreetmap"))
    if args.google: rows.extend(load_csv(args.google, "google_places"))
    if not rows: raise SystemExit("Provide at least one input CSV.")

    merged: list[dict[str, Any]] = []
    for row in rows:
        match = next((existing for existing in merged if same_business(existing, row, max(10, args.max_distance_m))), None)
        if match is None:
            base = dict(row)
            base["sources"] = row.get("_source", "")
            base.pop("_source", None)
            merged.append(base)
            continue
        sources = set(filter(None, text(match.get("sources")).split("|")))
        sources.add(text(row.get("_source")))
        match["sources"] = "|".join(sorted(sources))
        for field in ("name_ar", "name", "phone", "website", "address"):
            if not text(match.get(field)) and text(row.get(field)):
                match[field] = row[field]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    fields = sorted({key for row in merged for key in row if not key.startswith("_")})
    with args.output.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(merged)

    print({"input_rows": len(rows), "deduplicated_rows": len(merged), "duplicates_removed": len(rows)-len(merged)})
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
