#!/usr/bin/env python3
"""Build and enroll an exact 3000-SKU grocery visual catalog."""
# CI retrigger: execute the finalized JSONL/Open Food Facts training path.
from __future__ import annotations
import argparse, csv, gzip, io, json, os, random, re, time, unicodedata
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import numpy as np
import onnxruntime as ort
import requests
from PIL import Image, ImageEnhance, ImageFilter, ImageOps
ROOT=Path(__file__).resolve().parents[1]
MODEL=ROOT/'assets/models/mobileclip2/mobileclip2_s0_vision.onnx'; MODEL_DATA=ROOT/'assets/models/mobileclip2/mobileclip2_s0_vision.onnx.data'; SEED=ROOT/'data/yemen_food_catalog_seed.json'; OUT=ROOT/'build/yemen_food_catalog'
UA='AIStoreAssistant-YemenCatalog/2.9'; IMG='https://images.openfoodfacts.org/images/products'

def norm(s):
 s=unicodedata.normalize('NFKD',str(s or ''));s=''.join(c for c in s if not unicodedata.combining(c));s=re.sub(r'[\u064B-\u065F\u0670]','',s).lower();return re.sub(r'[^\w\u0600-\u06ff]+',' ',s).strip()

def first_value(v):
 if isinstance(v,str):return v.strip()
 if isinstance(v,(int,float)):return str(v)
 if isinstance(v,list):
  for x in v:
   y=first_value(x)
   if y:return y
 if isinstance(v,dict):
  for k in ('text','value','name','en','ar'):
   if k in v:
    y=first_value(v[k])
    if y:return y
 return ''

def barcode_from_path(path):
 nums=[x for x in Path(path).parts if x.isdigit()]
 return ''.join(nums[-4:]) if len(nums)>=4 else ''

def barcode_image_url(code,imgid='1'):
 code=re.sub(r'\D','',str(code or ''))
 if len(code)<7:return ''
 groups=[];i=0
 while i+3<len(code):groups.append(code[i:i+3]);i+=3
 groups.append(code[i:]);return f"{IMG}/{'/'.join(groups)}/{imgid}.400.jpg"

def extract_image_id(images):
 if isinstance(images,dict):
  for k in ('front','front_en','front_ar'):
   x=images.get(k)
   if isinstance(x,dict):
    for kk in ('imgid','imageid','id'):
     if x.get(kk):return str(x[kk])
  for k,v in images.items():
   if str(k).isdigit():return str(k)
   x=extract_image_id(v)
   if x:return x
 if isinstance(images,list):
  for x in images:
   y=extract_image_id(x)
   if y:return y
 return ''

def merge_value(existing,new):
 if not existing:return new
 if isinstance(existing,dict) and isinstance(new,dict):
  merged=dict(existing)
  for k,v in new.items():merged[k]=merge_value(merged.get(k),v)
  return merged
 if isinstance(existing,list) and isinstance(new,list):return existing+[x for x in new if x not in existing]
 return existing

def flatten_records(obj):
 if isinstance(obj,dict):
  for key in ('products','docs','items','results','data'):
   value=obj.get(key)
   if isinstance(value,list):
    for row in value:
     if isinstance(row,dict):yield row
    return
  yield obj
 elif isinstance(obj,list):
  for row in obj:
   if isinstance(row,dict):yield row

def parse_file(path):
 suffix=path.suffix.lower()
 if suffix=='.jsonl' or suffix=='.ndjson':
  with path.open('r',encoding='utf-8',errors='ignore') as fh:
   for line in fh:
    if not line.strip():continue
    try:obj=json.loads(line)
    except Exception:continue
    yield from flatten_records(obj)
  return
 if suffix=='.gz' and path.name.endswith('.jsonl.gz'):
  with gzip.open(path,'rt',encoding='utf-8',errors='ignore') as fh:
   for line in fh:
    if not line.strip():continue
    try:obj=json.loads(line)
    except Exception:continue
    yield from flatten_records(obj)
  return
 if suffix in ('.json',''):
  try:
   text=path.read_text(encoding='utf-8',errors='ignore');stripped=text.lstrip()
   if stripped.startswith('{') or stripped.startswith('['):yield from flatten_records(json.loads(text));return
  except Exception:pass
 if suffix=='.csv':
  with path.open('r',encoding='utf-8',errors='ignore',newline='') as fh:
   for row in csv.DictReader(fh):yield dict(row)

def iter_off_records(sample_root):
 root=Path(sample_root)
 jsonl=list(root.rglob('*.jsonl'))
 if jsonl:
  for f in jsonl:yield from parse_file(f)
  return
 for f in root.rglob('*.json'):
  if f.name in ('changes.json','scans.json'):continue
  for row in parse_file(f):yield row

def off_products(target):
 grouped={}
 for p in iter_off_records(os.environ.get('OFF_SAMPLE_ROOT','')):
  if not isinstance(p,dict):continue
  code=str(p.get('code') or p.get('_id') or '').strip();
  if not code:continue
  code_digits=re.sub(r'\D','',code);rec=grouped.setdefault(code_digits,{})
  for k,v in p.items():rec[k]=merge_value(rec.get(k),v)
 out=[]
 for code,p in grouped.items():
  name=first_value(p.get('product_name')) or first_value(p.get('generic_name'))
  if not code or not name:continue
  image=(p.get('image_front_url') or p.get('image_front_small_url') or p.get('image_front_thumb_url') or '').strip()
  if not image:image=barcode_image_url(code,extract_image_id(p.get('images')) or '1')
  if not image or not image.startswith('http'):continue
  cats=p.get('categories_tags') or [];cat=first_value(cats[0] if cats else '') or 'مواد غذائية'
  out.append({'id':'off-'+re.sub(r'[^0-9A-Za-z_-]','',code),'nameAr':name,'brand':first_value(p.get('brands')),'category':cat.replace('en:','').replace('-',' '),'packSize':first_value(p.get('quantity')),'source':'Open Food Facts full JSONL stream','sourceUrl':f'https://world.openfoodfacts.org/product/{code}','sourceType':'open_food_facts_jsonl','imageUrls':[image],'barcode':code,'priceYER':None,'openingQuantity':None})
  if len(out)>=target:return out
 return out

def fallback_products(target):
 found=off_products(target)
 if len(found)<target:raise RuntimeError(f'Full Open Food Facts stream yielded only {len(found)} image-backed products in the streamed window; expected {target}')
 return found

def choose_catalog(target):
 seed=json.loads(SEED.read_text(encoding='utf-8')).get('products',[]);catalog=[dict(x) for x in seed];ids={x['id'] for x in catalog};need=target-len(catalog)
 for p in fallback_products(need+700):
  if p['id'] in ids:continue
  catalog.append(p);ids.add(p['id'])
  if len(catalog)>=target:break
 return catalog[:target]

def download_one(job):
 idx,url,path=job
 try:
  r=requests.get(url,headers={'User-Agent':UA,'Accept':'image/avif,image/webp,image/jpeg,image/png,*/*'},timeout=30);r.raise_for_status();im=Image.open(io.BytesIO(r.content)).convert('RGB')
  if min(im.size)<96:return idx,None
  im.thumbnail((960,960),Image.Resampling.LANCZOS);path.parent.mkdir(parents=True,exist_ok=True);im.save(path,'JPEG',quality=90);return idx,path
 except Exception:return idx,None

def augment(im,n,rng):
 base=ImageOps.contain(im,(320,320),Image.Resampling.LANCZOS);out=[]
 for _ in range(n):
  x=base.copy();x=x.rotate(rng.uniform(-15,15),resample=Image.Resampling.BICUBIC,expand=False,fillcolor=tuple(rng.randint(175,255) for _ in range(3)))
  if rng.random()<.75:
   scale=rng.uniform(.78,1);nw,nh=max(1,int(x.width*scale)),max(1,int(x.height*scale));x=x.resize((nw,nh),Image.Resampling.LANCZOS);bg=Image.new('RGB',(320,320),tuple(rng.randint(0,255) for _ in range(3)));bg.paste(x,(rng.randint(0,320-nw),rng.randint(0,320-nh)));x=bg
  else:x=ImageOps.fit(x,(320,320),Image.Resampling.LANCZOS)
  if rng.random()<.6:x=ImageEnhance.Brightness(x).enhance(rng.uniform(.65,1.35))
  if rng.random()<.5:x=ImageEnhance.Contrast(x).enhance(rng.uniform(.7,1.35))
  if rng.random()<.35:x=x.filter(ImageFilter.GaussianBlur(rng.uniform(.2,1.4)))
  out.append(x)
 return out

def preprocess(im):
 mean=np.array([.48145466,.4578275,.40821073],np.float32);std=np.array([.26862954,.26130258,.27577711],np.float32);a=np.asarray(ImageOps.fit(im.convert('RGB'),(224,224),Image.Resampling.BICUBIC),np.float32)/255.;a=(a-mean)/std;return np.transpose(a,(2,0,1))[None,...]

def l2(v):return v/np.clip(np.linalg.norm(v,axis=1,keepdims=True),1e-12,None)

def infer(session,images):
 inp=session.get_inputs()[0].name;rows=[]
 for im in images:
  raw=session.run(None,{inp:preprocess(im)})[0].astype(np.float32)
  if raw.shape!=(1,512):raise RuntimeError(str(raw.shape))
  rows.append(raw[0])
 return l2(np.stack(rows))

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--target-products',type=int,default=3000);ap.add_argument('--augments',type=int,default=8);ap.add_argument('--download-workers',type=int,default=24);a=ap.parse_args()
 if not MODEL.exists() or not MODEL_DATA.exists():raise SystemExit('MobileCLIP2 model files are missing')
 OUT.mkdir(parents=True,exist_ok=True);catalog=choose_catalog(a.target_products)
 if len(catalog)!=a.target_products:raise SystemExit(f'catalog discovery returned {len(catalog)}')
 (OUT/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2),encoding='utf-8')
 jobs=[];path_map={}
 for i,p in enumerate(catalog):
  urls=[u for u in p.get('imageUrls',[]) if isinstance(u,str)]
  if urls:dest=OUT/'images'/p['id']/'front.jpg';jobs.append((i,urls[0],dest));path_map[p['id']]=dest
 hydrated=0
 with ThreadPoolExecutor(max_workers=a.download_workers) as ex:
  for f in as_completed([ex.submit(download_one,j) for j in jobs]):_,path=f.result();hydrated+=path is not None
 session=ort.InferenceSession(str(MODEL),providers=['CPUExecutionProvider']);rng=random.Random(20260821);centroids=[];trained=[];t0=time.perf_counter()
 for idx,p in enumerate(catalog,1):
  path=path_map.get(p['id'])
  if path is None or not path.exists():p['recognitionReady']=False;continue
  try:
   im=Image.open(path).convert('RGB');emb=infer(session,[im]+augment(im,a.augments,rng));centroids.append(l2(emb.mean(0,keepdims=True))[0].astype(np.float32));trained.append(p['id']);p['recognitionReady']=True;p['referenceVariants']=a.augments+1
  except Exception:p['recognitionReady']=False
  if idx%100==0:print(f'embedded {idx}/{len(catalog)}',flush=True)
 if len(trained)<a.target_products:raise SystemExit(f'Only {len(trained)} products have usable images; refusing to publish <{a.target_products}')
 matrix=np.stack(centroids);matrix.astype(np.float16).tofile(OUT/'catalog_centroids.f16');(OUT/'catalog_labels.json').write_text(json.dumps(trained,ensure_ascii=False),encoding='utf-8');(OUT/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2),encoding='utf-8')
 stats={'targetProducts':a.target_products,'catalogProducts':len(catalog),'trainedProducts':len(trained),'embeddingDimension':512,'storedVectors':int(matrix.shape[0]),'referenceVariantsPerTrainedProduct':a.augments+1,'hydratedImages':hydrated,'encoder':'MobileCLIP2-S0 Vision ONNX','catalogImageSources':['Yemen seed catalog','Open Food Facts full JSONL stream'],'rights':'Open Food Facts data is ODbL and product images CC-BY-SA; preserve attribution and comply with licenses before commercial redistribution.','embeddingSeconds':round(time.perf_counter()-t0,2),'builtAt':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
 (OUT/'build_stats.json').write_text(json.dumps(stats,ensure_ascii=False,indent=2),encoding='utf-8');(OUT/'source_licenses.md').write_text('# Provenance and licenses\n\nFallback products are from the Open Food Facts full JSONL stream. Data is ODbL and product images CC-BY-SA; preserve attribution and comply with applicable licenses before commercial redistribution.\n',encoding='utf-8');print(json.dumps(stats,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
