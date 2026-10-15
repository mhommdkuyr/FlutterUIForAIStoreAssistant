#!/usr/bin/env python3
"""Collect traceable Ibb POIs from OpenStreetMap/Overpass.
No Google Maps scraping. Source data is ODbL 1.0; attribute OpenStreetMap contributors.
"""
import argparse, csv, json, math, re, time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
import requests

DEFAULT_BBOX = (13.935, 44.135, 14.005, 44.195)  # south, west, north, east; approximate only
TAGS = ("shop", "amenity", "office", "craft", "tourism", "healthcare", "leisure")
ENDPOINT = "https://overpass-api.de/api/interpreter"

def query(bbox):
    s, w, n, e = bbox
    selectors = "".join('nwr["%s"](%s,%s,%s,%s);' % (k, s, w, n, e) for k in TAGS)
    return "[out:json][timeout:90];(" + selectors + ");out center tags;"

def fetch(bbox, depth=0, session=None):
    session = session or requests.Session()
    try:
        response = session.post(ENDPOINT, data={"data": query(bbox)},
            headers={"User-Agent": "IbbOpenDataCollector/1.0 (OpenStreetMap ODbL snapshot)"},
            timeout=120)
        response.raise_for_status()
        return response.json()
    except Exception:
        if depth >= 3:
            raise
        s, w, n, e = bbox
        ml, mw = (s+n)/2, (w+e)/2
        chunks = [(s,w,ml,mw),(s,mw,ml,e),(ml,w,n,mw),(ml,mw,n,e)]
        combined = {"elements": [], "osm3s": {}, "version": 0.6}
        for part in chunks:
            time.sleep(1.2)
            result = fetch(part, depth+1, session)
            combined["elements"].extend(result.get("elements", []))
            if result.get("osm3s"):
                combined["osm3s"] = result["osm3s"]
        return combined

def unpack(el):
    tags = el.get("tags", {})
    center = el.get("center", {})
    lat, lon = el.get("lat", center.get("lat")), el.get("lon", center.get("lon"))
    if lat is None or lon is None:
        return None
    name = tags.get("name:ar") or tags.get("name") or tags.get("name:en") or ""
    address_parts = [tags.get("addr:housenumber"), tags.get("addr:street"),
        tags.get("addr:suburb") or tags.get("addr:district"), tags.get("addr:city")]
    cats = [k for k in TAGS if tags.get(k)]
    return {
        "osm_type": el["type"], "osm_id": el["id"], "name": name,
        "name_ar": tags.get("name:ar", ""), "name_en": tags.get("name:en", ""),
        "primary_category": cats[0] if cats else "",
        "category_tags": ";".join(k+"="+tags[k] for k in cats),
        "latitude": lat, "longitude": lon,
        "coordinate_method": "OSM node coordinate" if el["type"]=="node" else "Overpass center for way/relation",
        "house_number": tags.get("addr:housenumber", ""), "street": tags.get("addr:street", ""),
        "district": tags.get("addr:suburb") or tags.get("addr:district", ""),
        "city": tags.get("addr:city", ""), "address": ", ".join(x for x in address_parts if x),
        "phone": tags.get("phone") or tags.get("contact:phone") or tags.get("mobile") or "",
        "website": tags.get("website") or tags.get("contact:website") or tags.get("url") or "",
        "opening_hours": tags.get("opening_hours", ""),
        "source_url": "https://www.openstreetmap.org/%s/%s" % (el["type"], el["id"]),
        "osm_tags": tags,
    }

def norm(value):
    value = (value or "").lower()
    value = re.sub(r"[\u064b-\u065f\u0670]", "", value)
    value = value.translate(str.maketrans({"أ":"ا","إ":"ا","آ":"ا","ى":"ي","ة":"ه","ـ":""}))
    return re.sub(r"[^\w]", "", value, flags=re.UNICODE)

def distance_m(a, b):
    rad = lambda x: math.radians(x)
    p1, p2 = rad(a["latitude"]), rad(b["latitude"])
    dp, dl = rad(b["latitude"]-a["latitude"]), rad(b["longitude"]-a["longitude"])
    h = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return 6371000 * 2 * math.asin(min(1, math.sqrt(h)))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bbox", nargs=4, type=float, default=DEFAULT_BBOX,
                    metavar=("SOUTH","WEST","NORTH","EAST"))
    ap.add_argument("--out", default="ibb_osm_output")
    ap.add_argument("--cell-size", type=float, default=0.01)
    args = ap.parse_args()
    s, w, n, e = args.bbox
    if not (s < n and w < e and args.cell_size > 0):
        ap.error("invalid bbox or cell size")
    payload = fetch(tuple(args.bbox))
    unique = {}
    for el in payload.get("elements", []):
        row = unpack(el)
        if row:
            unique[(row["osm_type"], row["osm_id"])] = row
    rows = sorted(unique.values(), key=lambda x:(x["primary_category"], x["name"], x["osm_type"], x["osm_id"]))
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    fields = ["osm_type","osm_id","name","name_ar","name_en","primary_category","category_tags",
      "latitude","longitude","coordinate_method","house_number","street","district","city","address",
      "phone","website","opening_hours","source_url","osm_tags_json"]
    with (out/"places.csv").open("w", encoding="utf-8-sig", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            item = dict(row)
            item["osm_tags_json"] = json.dumps(item.pop("osm_tags"), ensure_ascii=False)
            writer.writerow(item)
    features = []
    for row in rows:
        props = {k:v for k,v in row.items() if k not in ("latitude","longitude","osm_tags")}
        props["osm_tags"] = row["osm_tags"]
        features.append({"type":"Feature","id":"%s/%s"%(row["osm_type"],row["osm_id"]),
          "properties":props,"geometry":{"type":"Point","coordinates":[row["longitude"],row["latitude"]]}})
    (out/"places.geojson").write_text(json.dumps({"type":"FeatureCollection","name":"ibb_osm_live_snapshot",
        "license":"ODbL-1.0","source":"OpenStreetMap contributors via Overpass API",
        "osm_base_timestamp":payload.get("osm3s",{}).get("timestamp_osm_base"),
        "bbox":[w,s,e,n],"features":features}, ensure_ascii=False, indent=2), encoding="utf-8")
    grid, lat = [], s
    while lat < n - 1e-9:
        lon = w
        while lon < e - 1e-9:
            cs, cw = round(lat,6), round(lon,6)
            cn, ce = round(min(lat+args.cell_size,n),6), round(min(lon+args.cell_size,e),6)
            hits = [x for x in rows if cs <= x["latitude"] < cn+1e-9 and cw <= x["longitude"] < ce+1e-9]
            grid.append({"south":cs,"west":cw,"north":cn,"east":ce,"count":len(hits),
                         "named":sum(bool(x["name"]) for x in hits)})
            lon += args.cell_size
        lat += args.cell_size
    grid_geo = {"type":"FeatureCollection","name":"ibb_study_envelope_grid",
      "notes":"Rectangle only, not municipal boundary. Empty cells do not prove absence of businesses.",
      "features":[{"type":"Feature","properties":{"count":c["count"],"named":c["named"],
        "status":"HAS_MATCHING_OSM_OBJECTS" if c["count"] else "NO_MATCHING_OSM_OBJECTS"},
        "geometry":{"type":"Polygon","coordinates":[[[c["west"],c["south"]],[c["east"],c["south"]],
        [c["east"],c["north"]],[c["west"],c["north"]],[c["west"],c["south"]]]]}} for c in grid]}
    (out/"coverage_grid.geojson").write_text(json.dumps(grid_geo,ensure_ascii=False,indent=2),encoding="utf-8")
    by_name = defaultdict(list)
    for row in rows:
        key = norm(row["name"])
        if len(key) >= 3:
            by_name[key].append(row)
    dup_fields = ["name","osm_a","osm_b","distance_m","url_a","url_b","decision"]
    with (out/"possible_duplicates.csv").open("w",encoding="utf-8-sig",newline="") as file:
        writer=csv.DictWriter(file,fieldnames=dup_fields); writer.writeheader()
        for group in by_name.values():
            for i in range(len(group)):
                for j in range(i+1,len(group)):
                    dist=distance_m(group[i],group[j])
                    if dist <= 250:
                        writer.writerow({"name":group[i]["name"],
                          "osm_a":"%s/%s"%(group[i]["osm_type"],group[i]["osm_id"]),
                          "osm_b":"%s/%s"%(group[j]["osm_type"],group[j]["osm_id"]),
                          "distance_m":round(dist),"url_a":group[i]["source_url"],"url_b":group[j]["source_url"],
                          "decision":"Review only; never auto-merge"})
    stats={"generated_at":datetime.now(timezone.utc).isoformat(),"source":"OpenStreetMap contributors via Overpass API",
      "osm_base_timestamp":payload.get("osm3s",{}).get("timestamp_osm_base"),"bbox_south_west_north_east":args.bbox,
      "objects":len(rows),"named":sum(bool(x["name"]) for x in rows),
      "phone":sum(bool(x["phone"]) for x in rows),"website":sum(bool(x["website"]) for x in rows),
      "address":sum(bool(x["address"]) for x in rows),"opening_hours":sum(bool(x["opening_hours"]) for x in rows),
      "empty_grid_cells":sum(c["count"]==0 for c in grid),"grid_cells":len(grid),
      "note":"OSM snapshot, not a complete census. Rectangle is not a verified city boundary. Missing values must remain missing.",
      "license":"ODbL-1.0","attribution":"© OpenStreetMap contributors"}
    (out/"audit.json").write_text(json.dumps(stats,ensure_ascii=False,indent=2),encoding="utf-8")
    print(json.dumps(stats,ensure_ascii=False,indent=2))

if __name__ == "__main__":
    main()
