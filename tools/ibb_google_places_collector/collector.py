#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, math, os, sys, time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Tuple
import pandas as pd
import requests

SEARCH_URL="https://places.googleapis.com/v1/places:searchText"
DETAILS_URL="https://places.googleapis.com/v1/places"

SEARCH_MASK="places.id,nextPageToken"

def grid_centers(south:float,north:float,west:float,east:float,step_km:float)->Iterable[Tuple[float,float]]:
    lat_step=step_km/111.32
    mid=(south+north)/2
    lon_step=step_km/(111.32*math.cos(math.radians(mid)))
    lat=south
    while lat<=north+1e-9:
        lon=west
        while lon<=east+1e-9:
            yield round(lat,6),round(lon,6)
            lon+=lon_step
        lat+=lat_step

def post_json(session:requests.Session,headers:Dict[str,str],payload:Dict[str,Any],retries:int=5)->Dict[str,Any]:
    delay=1.5
    for attempt in range(retries):
        try:
            r=session.post(SEARCH_URL,headers=headers,json=payload,timeout=45)
            if r.status_code==200:
                return r.json()
            if r.status_code in (429,500,502,503,504) and attempt<retries-1:
                time.sleep(delay); delay=min(delay*2,30); continue
            raise RuntimeError(f"Places API error {r.status_code}: {r.text[:1200]}")
        except requests.RequestException as exc:
            if attempt==retries-1: raise RuntimeError(str(exc)) from exc
            time.sleep(delay); delay=min(delay*2,30)
    raise RuntimeError("request failed")

def flatten(p:Dict[str,Any],q:str,clat:float,clon:float)->Dict[str,Any]:
    d=p.get("displayName") or {}
    loc=p.get("location") or {}
    hours=p.get("regularOpeningHours") or {}
    return {
        "place_id":p.get("id"),
        "name":d.get("text"),
        "address":p.get("formattedAddress"),
        "national_phone":p.get("nationalPhoneNumber"),
        "international_phone":p.get("internationalPhoneNumber"),
        "website":p.get("websiteUri"),
        "latitude":loc.get("latitude"),
        "longitude":loc.get("longitude"),
        "primary_type":p.get("primaryType"),
        "types":"|".join(p.get("types") or []),
        "business_status":p.get("businessStatus"),
        "google_maps_url":p.get("googleMapsUri"),
        "has_photos":bool(p.get("photos")),
        "opening_period_count":len(hours.get("periods") or []),
        "search_query":q,
        "search_cell_lat":clat,
        "search_cell_lon":clon,
    }

def search(session,headers,q,lat,lon,radius,max_pages,lang,region)->List[Dict[str,Any]]:
    out=[]; token=None
    for _ in range(max_pages):
        body={"textQuery":q,"pageSize":20,"languageCode":lang,"regionCode":region,
              "locationBias":{"circle":{"center":{"latitude":lat,"longitude":lon},"radius":radius}}}
        if token: body["pageToken"]=token
        data=post_json(session,headers,body)
        out.extend(data.get("places") or [])
        token=data.get("nextPageToken")
        if not token: break
        time.sleep(2)
    return out

def main()->int:
    ap=argparse.ArgumentParser()
    ap.add_argument("--config",type=Path,default=Path("ibb_city_box.json"))
    ap.add_argument("--output-dir",type=Path,default=Path("output"))
    ap.add_argument("--dry-run",action="store_true")
    args=ap.parse_args()
    cfg=json.loads(args.config.read_text(encoding="utf-8"))
    cells=list(grid_centers(cfg["south"],cfg["north"],cfg["west"],cfg["east"],cfg["grid_step_km"]))
    estimate={"cells":len(cells),"queries":len(cfg["queries"]),"max_text_calls":len(cells)*len(cfg["queries"])*cfg["max_pages"]}
    print(json.dumps(estimate,ensure_ascii=False,indent=2))
    if args.dry_run: return 0
    key=os.getenv("GOOGLE_MAPS_API_KEY")
    if not key: raise SystemExit("GOOGLE_MAPS_API_KEY is required")
    headers={"Content-Type":"application/json","X-Goog-Api-Key":key,"X-Goog-FieldMask":SEARCH_MASK}
    session=requests.Session()
    unique:set[str]=set()
    raw=0
    for ci,(lat,lon) in enumerate(cells,1):
        for qi,q in enumerate(cfg["queries"],1):
            print(f"[{ci}/{len(cells)}|{qi}/{len(cfg['queries'])}] {q}",flush=True)
            for p in search(session,headers,q,lat,lon,cfg["search_radius_m"],cfg["max_pages"],cfg.get("language_code","ar"),cfg.get("region_code","YE")):
                raw+=1
                pid=p.get("id")
                if not pid: continue
                if pid:
                    unique.add(pid)
    out=args.output_dir; out.mkdir(parents=True,exist_ok=True)
    out=args.output_dir; out.mkdir(parents=True,exist_ok=True)
    audit={"raw_discoveries":raw,"place_id_count":len(unique),"cells":len(cells),"queries":len(cfg["queries"]),"max_pages_per_query":cfg["max_pages"],"mode":"audit-only","google_content_export":False}
    (out/"run_audit.json").write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding="utf-8")
    print(json.dumps(audit,ensure_ascii=False,indent=2))
    return 0

if __name__=="__main__":
    raise SystemExit(main())
