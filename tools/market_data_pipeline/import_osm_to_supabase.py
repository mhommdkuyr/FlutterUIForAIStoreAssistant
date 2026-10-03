#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import uuid
from pathlib import Path
from typing import Any

import requests

BATCH = 100


def load_rows(path: Path) -> list[dict[str, Any]]:
    return json.loads(path.read_text(encoding="utf-8"))


def store_row(row: dict[str, Any]) -> dict[str, Any] | None:
    if not row.get("name") and not row.get("name_ar"):
        return None
    lat = row.get("latitude")
    lon = row.get("longitude")
    if lat is None or lon is None:
        return None
    return {
        "id": str(uuid.uuid5(uuid.NAMESPACE_URL, "osm:" + str(row["osm_type"]) + ":" + str(row["osm_id"]))),
        "name_ar": row.get("name_ar") or row.get("name") or "منشأة بدون اسم",
        "name_en": row.get("name"),
        "phone": row.get("phone"),
        "address": row.get("address"),
        "city": "إب",
        "location": f"SRID=4326;POINT({float(lon)} {float(lat)})",
        "source": "openstreetmap",
        "source_ref": "osm:" + str(row["osm_type"]) + ":" + str(row["osm_id"]),
        "is_verified": False,
        "is_active": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--supabase-url", default=os.getenv("SUPABASE_URL"))
    parser.add_argument("--service-role-key", default=os.getenv("SUPABASE_SERVICE_ROLE_KEY"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    rows = [store_row(row) for row in load_rows(args.input)]
    payload = [row for row in rows if row]
    if args.dry_run:
        print(json.dumps({"input_rows": len(rows), "valid_rows": len(payload)}, indent=2))
        return 0

    if not args.supabase_url or not args.service_role_key:
        raise SystemExit("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required")

    url = args.supabase_url.rstrip("/") + "/rest/v1/market_stores"
    headers = {
        "apikey": args.service_role_key,
        "Authorization": "Bearer " + args.service_role_key,
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates,return=minimal",
    }

    imported = 0
    for start in range(0, len(payload), BATCH):
        response = requests.post(
            url,
            headers=headers,
            json=payload[start : start + BATCH],
            timeout=60,
        )
        response.raise_for_status()
        imported += len(payload[start : start + BATCH])

    print(json.dumps({"imported": imported}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
