#!/usr/bin/env python3
"""Build and enroll a resumable SKU batch with MobileCLIP2-S0."""
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
UA='AIStoreAssistant-YemenCatalog-Batch/3.0'; IMG='https://images.openfoodfacts.org/images/products'

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
    if line.strip():
     try:yield from flatten_records(json.loads(line))
     except Exception:continue
  return
 if suffix=='.gz' and path.name.endswith('.jsonl.gz'):
  with gzip.open(path,'rt',encoding='utf-8',errors='ignore') as fh:
   for line in fh:
    if line.strip():
     try:yield from flatten_records(json.loads(line))
     except Exception:continue
  return
 if suffix in ('.json',''):
  try:
   text=path.read_text(encoding='utf-8',errors='ignore');stripped=text.lstrip()
   if stripped.startswith('{') or stripped.startswith('['):yield from flatten_records(json.loads(text));return
  except Exception:pass
 if suffix=='.csv':
  with path.open('r',encoding='utf-8',errors='ignore',newline='') as fh:
   yield from csv.DictReader(fh)

def iter_off_records(sample_root):
 root=Path(sample_root);jsonls=list(root.rglob('*.jsonl'))
 if jsonls:
  for f in jsonls:yield from parse_file(f)
  return
 for f in root.rglob('*.json'):
  if f.name in ('changes.json','scans.json'):continue
  yield from parse_file(f)

def off_products(target):
 found=[];seen=set()
 for p in iter_off_records(os.environ.get('OFF_SAMPLE_ROOT','')):
  if not isinstance(p,dict):continue
  code=str(p.get('code') or p.get('_id') or '').strip();digits=re.sub(r'\D','',code)
  if not digits or digits in seen:continue
  name=first_value(p.get('product_name')) or first_value(p.get('generic_name'))
  image=(p.get('image_front_url') or p.get('image_front_small_url') or p.get('image_front_thumb_url') or '').strip()
  if not image:image=barcode_image_url(digits,extract_image_id(p.get('images')) or '1')
  if not name or not image.startswith('http'):continue
  cats=p.get('categories_tags') or [];cat=first_value(cats[0] if cats else '') or 'مواد غذائية'
  found.append({'id':'off-'+digits,'nameAr':name,'brand':first_value(p.get('brands')),'category':cat.replace('en:','').replace('-',' '),'packSize':first_value(p.get('quantity')),'source':'Open Food Facts full JSONL stream','sourceUrl':f'https://world.openfoodfacts.org/product/{digits}','sourceType':'open_food_facts_jsonl','imageUrls':[image],'barcode':digits,'priceYER':None,'openingQuantity':None})
  seen.add(digits)
  if len(found)>=target:return found
 return found

def choose_batch(target,start_index,include_seed):
 pool=off_products(start_index+target+2000)
 seed=json.loads(SEED.read_text(encoding='utf-8')).get('products',[]) if include_seed else []
 catalog=[dict(x) for x in seed];ids={x['id'] for x in catalog}
 for p in pool[start_index:]:
  if p['id'] in ids:continue
  catalog.append(p);ids.add(p['id'])
  if len(catalog)>=target:break
 return catalog[:target]

def download_one(job):
 idx,url,path=job
 try:
  r=requests.get(url,headers={'User-Agent':UA},timeout=30);r.raise_for_status();im=Image.open(io.BytesIO(r.content)).convert('RGB')
  if min(im.size)<96:return idx,None
  im.thumbnail((960,960),Image.Resampling.LANCZOS);path.parent.mkdir(parents=True,exist_ok=True);im.save(path,'JPEG',quality=90);return idx,path
 except Exception:return idx,None

def augment(im,n,rng):
 base=ImageOps.contain(im,(320,320),Image.Resampling.LANCZOS);out=[]
 for _ in range(n):
  x=base.rotate(rng.uniform(-15,15),resample=Image.Resampling.BICUBIC,expand=False,fillcolor=tuple(rng.randint(175,255) for _ in range(3)))
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
 ap=argparse.ArgumentParser();ap.add_argument('--target-products',type=int,required=True);ap.add_argument('--start-index',type=int,default=0);ap.add_argument('--include-seed',action='store_true');ap.add_argument('--augments',type=int,default=8);ap.add_argument('--download-workers',type=int,default=24);a=ap.parse_args()
 if not MODEL.exists() or not MODEL_DATA.exists():raise SystemExit('MobileCLIP2 model files are missing')
 OUT.mkdir(parents=True,exist_ok=True);catalog=choose_batch(a.target_products,a.start_index,a.include_seed)
 if len(catalog)!=a.target_products:raise SystemExit(f'catalog discovery returned {len(catalog)}; wanted {a.target_products}')
 (OUT/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False),encoding='utf-8');jobs=[];path_map={}
 for i,p in enumerate(catalog):
  urls=p.get('imageUrls',[]);dest=OUT/'images'/p['id']/'front.jpg';
  if urls:jobs.append((i,urls[0],dest));path_map[p['id']]=dest
 hydrated=0
 with ThreadPoolExecutor(max_workers=a.download_workers) as ex:
  for f in as_completed([ex.submit(download_one,j) for j in jobs]):_,path=f.result();hydrated+=path is not None
 if hydrated<a.target_products:raise SystemExit(f'Only {hydrated}/{a.target_products} images hydrated')
 session=ort.InferenceSession(str(MODEL),providers=['CPUExecutionProvider']);rng=random.Random(20260821+a.start_index);centroids=[];trained=[];t0=time.perf_counter()
 for p in catalog:
  path=path_map[p['id']];im=Image.open(path).convert('RGB');emb=infer(session,[im]+augment(im,a.augments,rng));centroids.append(l2(emb.mean(0,keepdims=True))[0].astype(np.float32));trained.append(p['id']);p['recognitionReady']=True;p['referenceVariants']=a.augments+1
 matrix=np.stack(centroids);matrix.astype(np.float16).tofile(OUT/'catalog_centroids.f16');(OUT/'catalog_labels.json').write_text(json.dumps(trained,ensure_ascii=False),encoding='utf-8');(OUT/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False),encoding='utf-8')
 stats={'batchStart':a.start_index,'batchProducts':a.target_products,'trainedProducts':len(trained),'embeddingDimension':512,'storedVectors':int(matrix.shape[0]),'referenceVariantsPerTrainedProduct':a.augments+1,'hydratedImages':hydrated,'encoder':'MobileCLIP2-S0 Vision ONNX','embeddingSeconds':round(time.perf_counter()-t0,2)}
 (OUT/'build_stats.json').write_text(json.dumps(stats,indent=2),encoding='utf-8');print(json.dumps(stats,indent=2))
if __name__=='__main__':main()
