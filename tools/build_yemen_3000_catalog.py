#!/usr/bin/env python3
"""Build a 3000-SKU grocery visual catalog with fixed MobileCLIP2 embeddings."""
from __future__ import annotations
import argparse, io, json, random, re, time, unicodedata
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import numpy as np
import onnxruntime as ort
import requests
from PIL import Image, ImageEnhance, ImageFilter, ImageOps
ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / 'assets/models/mobileclip2/mobileclip2_s0_vision.onnx'
MODEL_DATA = ROOT / 'assets/models/mobileclip2/mobileclip2_s0_vision.onnx.data'
SEED = ROOT / 'data/yemen_food_catalog_seed.json'
OUT = ROOT / 'build/yemen_food_catalog'
UA = 'AIStoreAssistant-YemenCatalog/2.2 (contact: github.com/mhommdkuyr/FlutterUIForAIStoreAssistant)'
OFF_HOSTS = [
    'https://world.openfoodfacts.org/api/v2/search',
    'https://us.openfoodfacts.org/api/v2/search',
    'https://fr.openfoodfacts.org/api/v2/search',
]

def norm(s: str) -> str:
    s = unicodedata.normalize('NFKD', s or '')
    s = ''.join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r'[\u064B-\u065F\u0670]', '', s).lower()
    return re.sub(r'[^\w\u0600-\u06ff]+', ' ', s).strip()

def off_json(session: requests.Session, params: dict) -> dict:
    last = None
    for attempt in range(6):
        for host in OFF_HOSTS:
            try:
                r = session.get(host, params=params, headers={'User-Agent': UA, 'Accept': 'application/json'}, timeout=45)
                if r.status_code in (429, 500, 502, 503, 504):
                    last = RuntimeError(f'Open Food Facts temporary HTTP {r.status_code}')
                    continue
                r.raise_for_status()
                return r.json()
            except requests.RequestException as exc:
                last = exc
        time.sleep(min(3.0 * (attempt + 1), 15.0))
    raise RuntimeError(f'Open Food Facts unavailable after retries: {last}')

def off_products(target: int) -> list[dict]:
    s = requests.Session(); fields = 'code,product_name,product_name_ar,brands,categories_tags_en,image_front_url,image_url,quantity,countries_tags_en'
    out, seen = [], set()
    for page in range(1, 61):
        if len(out) >= target: break
        data = off_json(s, {'page': page, 'page_size': 100, 'sort_by': 'popularity_key', 'fields': fields})
        for p in data.get('products', []):
            code = str(p.get('code') or '').strip(); name = (p.get('product_name_ar') or p.get('product_name') or '').strip(); image = (p.get('image_front_url') or p.get('image_url') or '').strip()
            if not code or code in seen or not name or not image or not image.startswith('http'): continue
            cats = p.get('categories_tags_en') or []; seen.add(code)
            out.append({'id':'off-'+re.sub(r'[^0-9A-Za-z_-]','',code),'nameAr':name,'brand':(p.get('brands') or '').split(',')[0].strip(),'category':(cats[0].replace('-',' ') if cats else 'مواد غذائية'),'packSize':str(p.get('quantity') or '').strip(),'source':'Open Food Facts','sourceUrl':f'https://world.openfoodfacts.org/product/{code}','sourceType':'open_food_facts_fallback','imageUrls':[image],'barcode':code,'priceYER':None,'openingQuantity':None,'countries':p.get('countries_tags_en') or []})
            if len(out) >= target: break
    return out

def choose_catalog(target: int) -> list[dict]:
    seed = json.loads(SEED.read_text(encoding='utf-8')).get('products', []); catalog=[]; ids=set()
    for p in seed:
        q=dict(p); q.setdefault('sourceType','yemen_seed'); q.setdefault('priceYER',None); q.setdefault('openingQuantity',None); q.setdefault('imageUrls',[]); catalog.append(q); ids.add(q['id'])
    for p in off_products(max(0,target-len(catalog))+500):
        if p['id'] in ids: continue
        catalog.append(p); ids.add(p['id'])
        if len(catalog)>=target: break
    return catalog[:target]

def download_one(item):
    idx,url,path=item
    try:
        r=requests.get(url,headers={'User-Agent':UA,'Accept':'image/avif,image/webp,image/jpeg,image/png,*/*'},timeout=25); r.raise_for_status(); im=Image.open(io.BytesIO(r.content)).convert('RGB')
        if min(im.size)<96: return idx,None
        im.thumbnail((960,960),Image.Resampling.LANCZOS); path.parent.mkdir(parents=True,exist_ok=True); im.save(path,'JPEG',quality=90); return idx,path
    except Exception: return idx,None

def augment(im: Image.Image, n: int, rng: random.Random):
    base=ImageOps.contain(im,(320,320),Image.Resampling.LANCZOS); out=[]
    for _ in range(n):
        x=base.copy(); x=x.rotate(rng.uniform(-15,15),resample=Image.Resampling.BICUBIC,expand=False,fillcolor=tuple(rng.randint(175,255) for _ in range(3)))
        if rng.random()<0.75:
            scale=rng.uniform(0.78,1.0); nw,nh=max(1,int(x.width*scale)),max(1,int(x.height*scale)); x=x.resize((nw,nh),Image.Resampling.LANCZOS); bg=Image.new('RGB',(320,320),tuple(rng.randint(0,255) for _ in range(3))); bg.paste(x,(rng.randint(0,320-nw),rng.randint(0,320-nh))); x=bg
        else: x=ImageOps.fit(x,(320,320),Image.Resampling.LANCZOS)
        if rng.random()<0.6: x=ImageEnhance.Brightness(x).enhance(rng.uniform(0.65,1.35))
        if rng.random()<0.5: x=ImageEnhance.Contrast(x).enhance(rng.uniform(0.7,1.35))
        if rng.random()<0.35: x=x.filter(ImageFilter.GaussianBlur(rng.uniform(0.2,1.4)))
        out.append(x)
    return out

def preprocess(im: Image.Image) -> np.ndarray:
    mean=np.array([0.48145466,0.4578275,0.40821073],dtype=np.float32); std=np.array([0.26862954,0.26130258,0.27577711],dtype=np.float32); x=ImageOps.fit(im.convert('RGB'),(224,224),Image.Resampling.BICUBIC); a=np.asarray(x,dtype=np.float32)/255.0; a=(a-mean)/std; return np.transpose(a,(2,0,1))[None,...]

def l2(v: np.ndarray)->np.ndarray: return v/np.clip(np.linalg.norm(v,axis=1,keepdims=True),1e-12,None)

def infer(session,images):
    inp=session.get_inputs()[0].name; rows=[]
    for im in images:
        raw=session.run(None,{inp:preprocess(im)})[0].astype(np.float32)
        if raw.shape!=(1,512): raise RuntimeError(f'Unexpected MobileCLIP2 output shape {raw.shape}')
        rows.append(raw[0])
    return l2(np.stack(rows,axis=0))

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--target-products',type=int,default=3000); ap.add_argument('--augments',type=int,default=8); ap.add_argument('--download-workers',type=int,default=12); args=ap.parse_args()
    if not MODEL.exists() or not MODEL_DATA.exists(): raise SystemExit('MobileCLIP2 model files are missing')
    OUT.mkdir(parents=True,exist_ok=True); catalog=choose_catalog(args.target_products)
    if len(catalog)!=args.target_products: raise SystemExit(f'Catalog discovery returned {len(catalog)}, expected {args.target_products}')
    (OUT/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2),encoding='utf-8')
    jobs=[]; path_map={}
    for i,p in enumerate(catalog):
        urls=[u for u in p.get('imageUrls',[]) if isinstance(u,str) and u.startswith('http')]
        if urls: dest=OUT/'images'/p['id']/'front.jpg'; jobs.append((i,urls[0],dest)); path_map[p['id']]=dest
    hydrated=0
    with ThreadPoolExecutor(max_workers=args.download_workers) as ex:
        for f in as_completed([ex.submit(download_one,j) for j in jobs]):
            _,path=f.result(); hydrated+=path is not None
    session=ort.InferenceSession(str(MODEL),providers=['CPUExecutionProvider']); rng=random.Random(20260821); centroids=[]; trained=[]; t0=time.perf_counter()
    for idx,p in enumerate(catalog,1):
        path=path_map.get(p['id'])
        if path is None or not path.exists(): p['recognitionReady']=False; continue
        try:
            im=Image.open(path).convert('RGB'); variants=[im]+augment(im,args.augments,rng); emb=infer(session,variants); centroids.append(l2(emb.mean(axis=0,keepdims=True))[0].astype(np.float32)); trained.append(p['id']); p['recognitionReady']=True; p['referenceVariants']=len(variants)
        except Exception: p['recognitionReady']=False
        if idx%100==0: print(f'embedded {idx}/{len(catalog)}')
    if len(trained)<args.target_products: raise SystemExit(f'Only {len(trained)} products have usable images; refusing to publish a <{args.target_products} catalog.')
    matrix=np.stack(centroids,axis=0); matrix.astype(np.float16).tofile(OUT/'catalog_centroids.f16'); (OUT/'catalog_labels.json').write_text(json.dumps(trained,ensure_ascii=False),encoding='utf-8'); (OUT/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2),encoding='utf-8')
    stats={'targetProducts':args.target_products,'catalogProducts':len(catalog),'trainedProducts':len(trained),'embeddingDimension':512,'storedVectors':int(matrix.shape[0]),'referenceVariantsPerTrainedProduct':args.augments+1,'hydratedImages':hydrated,'encoder':'MobileCLIP2-S0 Vision ONNX','catalogImageSources':['Yemen seed catalog','Open Food Facts'],'rights':'Open Food Facts data/images carry source-specific licenses; provenance is retained and commercial redistribution must comply with the applicable license/attribution terms.','embeddingSeconds':round(time.perf_counter()-t0,2),'builtAt':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
    (OUT/'build_stats.json').write_text(json.dumps(stats,ensure_ascii=False,indent=2),encoding='utf-8'); (OUT/'source_licenses.md').write_text('# Catalog provenance and licenses\n\nYemen seed records source URLs. Fallback products are from Open Food Facts. Retain attribution and comply with applicable database/image licenses before commercial redistribution.\n',encoding='utf-8'); print(json.dumps(stats,ensure_ascii=False,indent=2))

if __name__=='__main__': main()
