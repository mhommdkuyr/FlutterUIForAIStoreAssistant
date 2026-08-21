#!/usr/bin/env python3
"""Build and enroll an exact 3000-SKU grocery visual catalog."""
from __future__ import annotations
import argparse, io, json, random, re, time, unicodedata
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import numpy as np
import onnxruntime as ort
import requests
from PIL import Image, ImageEnhance, ImageFilter, ImageOps
ROOT=Path(__file__).resolve().parents[1]
MODEL=ROOT/'assets/models/mobileclip2/mobileclip2_s0_vision.onnx'
MODEL_DATA=ROOT/'assets/models/mobileclip2/mobileclip2_s0_vision.onnx.data'
SEED=ROOT/'data/yemen_food_catalog_seed.json'; OUT=ROOT/'build/yemen_food_catalog'
UA='AIStoreAssistant-YemenCatalog/2.3'
HF='https://datasets-server.huggingface.co/rows'
IMG='https://images.openfoodfacts.org/images/products'

def norm(s):
    s=unicodedata.normalize('NFKD',str(s or '')); s=''.join(c for c in s if not unicodedata.combining(c)); s=re.sub(r'[\u064B-\u065F\u0670]','',s).lower(); return re.sub(r'[^\w\u0600-\u06ff]+',' ',s).strip()

def first_value(v):
    if isinstance(v,str): return v.strip()
    if isinstance(v,list):
        for x in v:
            y=first_value(x)
            if y: return y
    if isinstance(v,dict):
        for k in ('text','value','name','en','ar'):
            if k in v:
                y=first_value(v[k])
                if y:return y
    return ''

def barcode_image_url(code, imgid='1'):
    code=re.sub(r'\D','',str(code or ''))
    if len(code)<7:return ''
    groups=[]; i=0
    while i+3 < len(code): groups.append(code[i:i+3]); i+=3
    groups.append(code[i:])
    return f"{IMG}/{'/'.join(groups)}/{imgid}.400.jpg"

def extract_image_id(images):
    if isinstance(images,dict):
        for k in ('front','front_en','front_ar'):
            if k in images:
                x=images[k]
                if isinstance(x,dict):
                    for kk in ('imgid','imageid','id'):
                        if x.get(kk): return str(x[kk])
        for k,v in images.items():
            if str(k).isdigit(): return str(k)
            x=extract_image_id(v)
            if x:return x
    if isinstance(images,list):
        for x in images:
            y=extract_image_id(x)
            if y:return y
    return ''

def hf_rows(session, offset, length=100):
    params={'dataset':'openfoodfacts/product-database','config':'default','split':'food','offset':offset,'length':length}
    last=None
    for attempt in range(6):
        try:
            r=session.get(HF,params=params,headers={'User-Agent':UA,'Accept':'application/json'},timeout=60)
            if r.status_code in (429,500,502,503,504):
                last=r.status_code; time.sleep(min(2*(attempt+1),12)); continue
            r.raise_for_status(); return r.json().get('rows',[])
        except requests.RequestException as e:
            last=e; time.sleep(min(2*(attempt+1),12))
    raise RuntimeError(f'HF dataset viewer unavailable after retries: {last}')

def fallback_products(target):
    s=requests.Session(); out=[]; seen=set()
    for offset in range(0, min(4600, target*2+1000), 100):
        for rec in hf_rows(s,offset,100):
            p=rec.get('row',{})
            code=str(p.get('code') or '').strip(); name=first_value(p.get('product_name')) or first_value(p.get('generic_name'))
            if not code or code in seen or not name: continue
            imgid=extract_image_id(p.get('images')) or '1'; image=barcode_image_url(code,imgid)
            if not image: continue
            cats=p.get('categories_tags') or []; cat=first_value(cats[0] if cats else '') or 'مواد غذائية'
            out.append({'id':'off-'+re.sub(r'[^0-9A-Za-z_-]','',code),'nameAr':name,'brand':first_value(p.get('brands')),'category':cat.replace('en:','').replace('-',' '),'packSize':first_value(p.get('quantity')),'source':'Open Food Facts / Hugging Face Parquet','sourceUrl':f'https://world.openfoodfacts.org/product/{code}','sourceType':'open_food_facts_parquet','imageUrls':[image],'barcode':code,'priceYER':None,'openingQuantity':None})
            seen.add(code)
            if len(out)>=target:return out
    return out

def choose_catalog(target):
    seed=json.loads(SEED.read_text(encoding='utf-8')).get('products',[]); catalog=[dict(x) for x in seed]; ids={x['id'] for x in catalog}
    need=target-len(catalog)
    for p in fallback_products(max(need+500,need)):
        if p['id'] in ids: continue
        catalog.append(p); ids.add(p['id'])
        if len(catalog)>=target: break
    return catalog[:target]

def download_one(job):
    idx,url,path=job
    try:
        r=requests.get(url,headers={'User-Agent':UA,'Accept':'image/avif,image/webp,image/jpeg,image/png,*/*'},timeout=30); r.raise_for_status(); im=Image.open(io.BytesIO(r.content)).convert('RGB')
        if min(im.size)<96:return idx,None
        im.thumbnail((960,960),Image.Resampling.LANCZOS); path.parent.mkdir(parents=True,exist_ok=True); im.save(path,'JPEG',quality=90); return idx,path
    except Exception:return idx,None

def augment(im,n,rng):
    base=ImageOps.contain(im,(320,320),Image.Resampling.LANCZOS); out=[]
    for _ in range(n):
        x=base.copy(); x=x.rotate(rng.uniform(-15,15),resample=Image.Resampling.BICUBIC,expand=False,fillcolor=tuple(rng.randint(175,255) for _ in range(3)))
        if rng.random()<.75:
            scale=rng.uniform(.78,1); nw,nh=max(1,int(x.width*scale)),max(1,int(x.height*scale)); x=x.resize((nw,nh),Image.Resampling.LANCZOS); bg=Image.new('RGB',(320,320),tuple(rng.randint(0,255) for _ in range(3))); bg.paste(x,(rng.randint(0,320-nw),rng.randint(0,320-nh))); x=bg
        else:x=ImageOps.fit(x,(320,320),Image.Resampling.LANCZOS)
        if rng.random()<.6:x=ImageEnhance.Brightness(x).enhance(rng.uniform(.65,1.35))
        if rng.random()<.5:x=ImageEnhance.Contrast(x).enhance(rng.uniform(.7,1.35))
        if rng.random()<.35:x=x.filter(ImageFilter.GaussianBlur(rng.uniform(.2,1.4)))
        out.append(x)
    return out

def preprocess(im):
    mean=np.array([.48145466,.4578275,.40821073],np.float32); std=np.array([.26862954,.26130258,.27577711],np.float32); a=np.asarray(ImageOps.fit(im.convert('RGB'),(224,224),Image.Resampling.BICUBIC),np.float32)/255.; a=(a-mean)/std; return np.transpose(a,(2,0,1))[None,...]

def l2(v):return v/np.clip(np.linalg.norm(v,axis=1,keepdims=True),1e-12,None)

def infer(session,images):
    inp=session.get_inputs()[0].name; rows=[]
    for im in images:
        raw=session.run(None,{inp:preprocess(im)})[0].astype(np.float32)
        if raw.shape!=(1,512):raise RuntimeError(str(raw.shape))
        rows.append(raw[0])
    return l2(np.stack(rows))

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--target-products',type=int,default=3000); ap.add_argument('--augments',type=int,default=8); ap.add_argument('--download-workers',type=int,default=16); a=ap.parse_args()
    if not MODEL.exists() or not MODEL_DATA.exists():raise SystemExit('MobileCLIP2 model files are missing')
    OUT.mkdir(parents=True,exist_ok=True); catalog=choose_catalog(a.target_products)
    if len(catalog)!=a.target_products:raise SystemExit(f'catalog discovery returned {len(catalog)}')
    (OUT/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2),encoding='utf-8')
    jobs=[]; path_map={}
    for i,p in enumerate(catalog):
        urls=[u for u in p.get('imageUrls',[]) if isinstance(u,str) and u.startswith('http')]
        if urls:
            dest=OUT/'images'/p['id']/'front.jpg'; jobs.append((i,urls[0],dest)); path_map[p['id']]=dest
    hydrated=0
    with ThreadPoolExecutor(max_workers=a.download_workers) as ex:
        for f in as_completed([ex.submit(download_one,j) for j in jobs]):
            _,path=f.result(); hydrated += path is not None
    session=ort.InferenceSession(str(MODEL),providers=['CPUExecutionProvider']); rng=random.Random(20260821); centroids=[]; trained=[]; t0=time.perf_counter()
    for idx,p in enumerate(catalog,1):
        path=path_map.get(p['id'])
        if path is None or not path.exists():p['recognitionReady']=False;continue
        try:
            emb=infer(session,[Image.open(path).convert('RGB')]+augment(Image.open(path).convert('RGB'),a.augments,rng)); centroids.append(l2(emb.mean(0,keepdims=True))[0].astype(np.float32)); trained.append(p['id']); p['recognitionReady']=True; p['referenceVariants']=a.augments+1
        except Exception:p['recognitionReady']=False
        if idx%100==0:print(f'embedded {idx}/{len(catalog)}',flush=True)
    if len(trained)<a.target_products:raise SystemExit(f'Only {len(trained)} products have usable images; refusing to publish <{a.target_products}')
    matrix=np.stack(centroids); matrix.astype(np.float16).tofile(OUT/'catalog_centroids.f16'); (OUT/'catalog_labels.json').write_text(json.dumps(trained,ensure_ascii=False),encoding='utf-8'); (OUT/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2),encoding='utf-8')
    stats={'targetProducts':a.target_products,'catalogProducts':len(catalog),'trainedProducts':len(trained),'embeddingDimension':512,'storedVectors':int(matrix.shape[0]),'referenceVariantsPerTrainedProduct':a.augments+1,'hydratedImages':hydrated,'encoder':'MobileCLIP2-S0 Vision ONNX','catalogImageSources':['Yemen seed catalog','Open Food Facts Parquet dataset'],'rights':'Open Food Facts data is ODbL and images CC-BY-SA; preserve attribution and comply with licenses before commercial redistribution.','embeddingSeconds':round(time.perf_counter()-t0,2),'builtAt':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
    (OUT/'build_stats.json').write_text(json.dumps(stats,ensure_ascii=False,indent=2),encoding='utf-8'); (OUT/'source_licenses.md').write_text('# Provenance and licenses\n\nFallback products are from Open Food Facts Parquet via the Hugging Face dataset viewer. Data is ODbL and product images CC-BY-SA; preserve attribution and comply with applicable licenses before commercial redistribution.\n',encoding='utf-8'); print(json.dumps(stats,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
