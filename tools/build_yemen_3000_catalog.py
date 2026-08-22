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
UA='AIStoreAssistant-YemenCatalog-Batch/3.1'; IMG='https://images.openfoodfacts.org/images/products'

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

def extract_urls(v, out=None):
 out=[] if out is None else out
 if len(out)>=8:return out
 if isinstance(v,str):
  s=v.strip()
  if s.startswith('http') and ('.jpg' in s or '.jpeg' in s or '.png' in s or 'images/' in s):
   if s not in out: out.append(s)
 elif isinstance(v,dict):
  for k in ('aws','off','url','image_front_url','image_front_small_url','image_front_thumb_url'):
   if k in v: extract_urls(v[k],out)
  for k in ('front','front_en','front_ar'):
   if k in v: extract_urls(v[k],out)
  for x in v.values(): extract_urls(x,out)
 elif isinstance(v,list):
  for x in v: extract_urls(x,out)
 return out

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
  urls=extract_urls(p.get('image_front_url'))
  for candidate_key in ('images','image_front_small_url','image_front_thumb_url'):
   for u in extract_urls(p.get(candidate_key)):
    if u not in urls:urls.append(u)
  if not urls:
   for iid in ('1','2','3'):
    u=barcode_image_url(digits,iid)
    if u:urls.append(u)
  urls=urls[:8]
  if not name or not urls:continue
  cats=p.get('categories_tags') or [];cat=first_value(cats[0] if cats else '') or 'مواد غذائية'
  found.append({'id':'off-'+digits,'nameAr':name,'brand':first_value(p.get('brands')),'category':cat.replace('en:','').replace('-',' '),'packSize':first_value(p.get('quantity')),'source':'Open Food Facts full JSONL stream','sourceUrl':f'https://world.openfoodfacts.org/product/{digits}','sourceType':'open_food_facts_jsonl','imageUrls':urls,'barcode':digits,'priceYER':None,'openingQuantity':None})
  seen.add(digits)
  if len(found)>=target:return found
 return found

def choose_batch(target,start_index,include_seed):
 pool=off_products(start_index + target*4 + 2000)
 seed=json.loads(SEED.read_text(encoding='utf-8')).get('products',[]) if include_seed else []
 catalog=[];ids=set()
 for p in seed:
  if p.get('imageUrls'):
   catalog.append(dict(p));ids.add(p.get('id'))
 for p in pool[start_index:]:
  if p['id'] in ids:continue
  catalog.append(p);ids.add(p['id'])
  if len(catalog)>=target*4:break
 return catalog

def download_one(job):
 idx,urls,path=job
 for url in urls:
  try:
   r=requests.get(url,headers={'User-Agent':UA,'Accept':'image/avif,image/webp,image/jpeg,image/png,*/*'},timeout=20)
   r.raise_for_status();im=Image.open(io.BytesIO(r.content)).convert('RGB')
   if min(im.size)<96:continue
   im.thumbnail((960,960),Image.Resampling.LANCZOS);path.parent.mkdir(parents=True,exist_ok=True);im.save(path,'JPEG',quality=90);return idx,path,url
  except Exception:continue
 return idx,None,None

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
 OUT.mkdir(parents=True,exist_ok=True);candidates=choose_batch(a.target_products,a.start_index,a.include_seed)
 if len(candidates)<a.target_products:raise SystemExit(f'candidate discovery returned {len(candidates)}; wanted at least {a.target_products}')
 path_map={};jobs=[]
 for i,p in enumerate(candidates):
  dest=OUT/'images'/p['id']/'front.jpg';jobs.append((i,p.get('imageUrls',[]),dest));path_map[p['id']]=dest
 successful=[]
 with ThreadPoolExecutor(max_workers=a.download_workers) as ex:
  futures=[ex.submit(download_one,j) for j in jobs]
  for f in as_completed(futures):
   result=f.result()
   if result[1] is not None:successful.append(result)
   if len(successful)>=a.target_products:break
 if len(successful)<a.target_products:raise SystemExit(f'Only {len(successful)}/{a.target_products} images hydrated from {len(candidates)} candidates')
 successful.sort(key=lambda x:x[0]);selected=[dict(candidates[i]) for i,_,_ in successful[:a.target_products]]
 for p,(i,path,url) in zip(selected,successful[:a.target_products]):
  p['imageUrls']=[url];p['recognitionReady']=False
 (OUT/'catalog.json').write_text(json.dumps(selected,ensure_ascii=False),encoding='utf-8')
 session=ort.InferenceSession(str(MODEL),providers=['CPUExecutionProvider']);rng=random.Random(20260821+a.start_index);centroids=[];trained=[];t0=time.perf_counter()
 for p in selected:
  path=path_map[p['id']];im=Image.open(path).convert('RGB');emb=infer(session,[im]+augment(im,a.augments,rng));centroids.append(l2(emb.mean(0,keepdims=True))[0].astype(np.float32));trained.append(p['id']);p['recognitionReady']=True;p['referenceVariants']=a.augments+1
 matrix=np.stack(centroids);matrix.astype(np.float16).tofile(OUT/'catalog_centroids.f16');(OUT/'catalog_labels.json').write_text(json.dumps(trained,ensure_ascii=False),encoding='utf-8');(OUT/'catalog.json').write_text(json.dumps(selected,ensure_ascii=False),encoding='utf-8')
 stats={'batchStart':a.start_index,'candidateProducts':len(candidates),'batchProducts':a.target_products,'trainedProducts':len(trained),'embeddingDimension':512,'storedVectors':int(matrix.shape[0]),'referenceVariantsPerTrainedProduct':a.augments+1,'hydratedImages':len(successful[:a.target_products]),'encoder':'MobileCLIP2-S0 Vision ONNX','embeddingSeconds':round(time.perf_counter()-t0,2),'catalogMode':'cloud'}
 (OUT/'build_stats.json').write_text(json.dumps(stats,indent=2),encoding='utf-8');print(json.dumps(stats,indent=2))
if __name__=='__main__':main()
