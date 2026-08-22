#!/usr/bin/env python3
"""Build a large Yemen-food visual catalog from public product pages.

This is catalog enrollment, not base-model fine-tuning. The checked-in
MobileCLIP2-S0 encoder remains fixed; each SKU receives many augmented
reference embeddings so the existing Flutter cosine-search engine can match
products under changed lighting, scale, mild rotation, blur and background.
"""

from __future__ import annotations

import argparse
import io
import json
import math
import os
import random
import re
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib.parse import urljoin, urlparse

import numpy as np
import onnxruntime as ort
import requests
from bs4 import BeautifulSoup
from PIL import Image, ImageEnhance, ImageFilter, ImageOps

UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "Chrome/131 Safari/537.36 yemen-food-catalog-builder/1.0"
)

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "assets/models/mobileclip2/mobileclip2_s0_vision.onnx"
MODEL_DATA = ROOT / "assets/models/mobileclip2/mobileclip2_s0_vision.onnx.data"
SEED = ROOT / "data/yemen_food_catalog_seed.json"
OUT = ROOT / "build/yemen_food_catalog"

CATEGORIES = [
    "https://grocery-sanaa.bazzarry.com/catalog/category/view/s/rice/id/7011/",
    "https://grocery-sanaa.bazzarry.com/catalog/category/view/s/oil/id/7010/",
    "https://grocery-sanaa.bazzarry.com/catalog/category/view/s/ghee/id/7012/",
    "https://grocery-sanaa.bazzarry.com/catalog/category/view/s/pasta/id/7013/",
    "https://grocery-sanaa.bazzarry.com/kitchen-essentials/legumes",
    "https://grocery-sanaa.bazzarry.com/catalog/category/view/s/canned-food/id/7015/",
    "https://grocery-sanaa.bazzarry.com/catalog/category/view/s/sauces/id/7016/",
    "https://grocery-sanaa.bazzarry.com/catalog/category/view/s/sugar/id/7017/",
    "https://grocery-sanaa.bazzarry.com/catalog/category/view/s/sweets/id/7018/",
    "https://grocery-sanaa.bazzarry.com/catalog/category/view/s/spices/id/7019/",
    "https://grocery-sanaa.bazzarry.com/milk-and-dairy-products",
    "https://grocery-sanaa.bazzarry.com/catalog/category/view/s/sweetened-milk/id/7041/",
    "https://grocery-sanaa.bazzarry.com/frozen-foods",
]
OTHER_SOURCES = [
    "https://www.mafco.trade/products",
    "https://alrawdahco.com/en/Shopping",
    "https://yemenica.com/product-category/groceries/",
]


def norm(text: str) -> str:
    text = unicodedata.normalize("NFKD", text or "")
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = re.sub(r"[\u064B-\u065F\u0670]", "", text)
    text = text.replace("ـ", "")
    text = text.lower()
    return re.sub(r"[^\w\u0600-\u06ff]+", " ", text).strip()


def slug(text: str) -> str:
    s = norm(text).replace(" ", "-")
    return re.sub(r"[^a-z0-9\u0600-\u06ff_-]+", "", s)[:90] or "product"


def same_domain(a: str, b: str) -> bool:
    return urlparse(a).netloc == urlparse(b).netloc


def fetch(session: requests.Session, url: str, timeout: int = 25) -> str | bytes | None:
    try:
        r = session.get(url, headers={"User-Agent": UA}, timeout=timeout)
        r.raise_for_status()
        return r.content if "image" in r.headers.get("content-type", "") else r.text
    except requests.RequestException:
        return None


def product_cards(html: str, base: str) -> list[tuple[str, str, str]]:
    soup = BeautifulSoup(html, "html.parser")
    out: list[tuple[str, str, str]] = []
    links = soup.select("a.product-item-link, .product-item-link, a.product-name, h2.product-name a")
    imgs = soup.select("img.product-image-photo, .product-image img, img")
    img_urls = [
        urljoin(base, i.get("src") or i.get("data-src") or i.get("data-lazy-src") or "")
        for i in imgs
    ]
    img_urls = [u for u in img_urls if u.startswith("http")]
    for link in links:
        name = link.get_text(" ", strip=True)
        href = urljoin(base, link.get("href", ""))
        if not name or not href:
            continue
        # Prefer an image in the nearest product container.
        container = link
        for _ in range(6):
            if container.parent is None:
                break
            container = container.parent
            found = container.select_one("img.product-image-photo, .product-image img")
            if found:
                src = found.get("src") or found.get("data-src") or found.get("data-lazy-src")
                if src:
                    out.append((name, href, urljoin(base, src)))
                    break
        else:
            if img_urls:
                out.append((name, href, img_urls[0]))
    return out


def crawl_bazzarry(session: requests.Session, max_pages: int) -> list[dict]:
    found: dict[str, dict] = {}
    queue = [(u, 1) for u in CATEGORIES]
    seen: set[str] = set()
    while queue:
        url, page = queue.pop(0)
        if url in seen or page > max_pages:
            continue
        seen.add(url)
        html = fetch(session, url)
        if not isinstance(html, str):
            continue
        for name, href, image in product_cards(html, url):
            key = norm(name)
            if key and image:
                found[key] = {
                    "name": name,
                    "productUrl": href,
                    "imageUrl": image,
                    "source": "Bazzarry",
                    "sourceUrl": url,
                }
        # Magento-like pagination.
        soup = BeautifulSoup(html, "html.parser")
        for a in soup.select("a.next, .pages-item-next a, a[rel='next']"):
            nxt = urljoin(url, a.get("href", ""))
            if same_domain(nxt, url):
                queue.append((nxt, page + 1))
                break
    return list(found.values())


def crawl_generic(session: requests.Session, base_urls: Iterable[str], limit: int = 1200) -> list[dict]:
    found: dict[str, dict] = {}
    for base in base_urls:
        html = fetch(session, base)
        if not isinstance(html, str):
            continue
        soup = BeautifulSoup(html, "html.parser")
        for img in soup.select("img"):
            src = img.get("src") or img.get("data-src") or img.get("data-lazy-src")
            if not src:
                continue
            src = urljoin(base, src)
            alt = (img.get("alt") or img.get("title") or "").strip()
            parent = img.parent
            text = parent.get_text(" ", strip=True) if parent else ""
            name = alt or text[:160]
            if not name or not src.startswith("http"):
                continue
            key = norm(name)
            if len(key) < 4:
                continue
            found[key] = {
                "name": name,
                "productUrl": base,
                "imageUrl": src,
                "source": urlparse(base).netloc,
                "sourceUrl": base,
            }
            if len(found) >= limit:
                break
    return list(found.values())


def build_catalog(seed: list[dict], discovered: list[dict]) -> list[dict]:
    out = {x["id"]: dict(x) for x in seed}
    by_name = [(k, v) for k, v in ((norm(x.get("nameAr", "")), x) for x in out.values()) if k]
    for item in discovered:
        n = norm(item["name"])
        exact = next((p for k, p in by_name if k == n), None)
        if exact:
            exact.setdefault("imageUrls", [])
            if item["imageUrl"] not in exact["imageUrls"]:
                exact["imageUrls"].append(item["imageUrl"])
            continue
        # Only auto-add products carrying clear food-ish keywords.
        food_words = [
            "بسك", "شوك", "حليب", "مكر", "ارز", "أرز", "تونة", "فول", "صلصة", "زيت",
            "سكر", "عسل", "تمر", "ويفر", "كيك", "قهوة", "شاي", "juice", "milk", "rice",
            "pasta", "biscuit", "chocolate", "tuna", "beans",
        ]
        if not any(w in n for w in map(norm, food_words)):
            continue
        pid = "web-" + slug(item["name"])
        i = 2
        while pid in out:
            pid = f"web-{slug(item['name'])}-{i}"
            i += 1
        out[pid] = {
            "id": pid,
            "nameAr": item["name"],
            "brand": "",
            "category": "auto-discovered",
            "packSize": "",
            "source": item["source"],
            "sourceUrl": item["sourceUrl"],
            "sourceType": "discovered_listing",
            "imageUrls": [item["imageUrl"]],
            "priceYER": None,
            "openingQuantity": None,
            "barcode": None,
        }
        by_name.append((n, out[pid]))
    return list(out.values())


def download_image(session: requests.Session, url: str, dest: Path) -> bool:
    try:
        r = session.get(url, headers={"User-Agent": UA}, timeout=20)
        r.raise_for_status()
        im = Image.open(io.BytesIO(r.content)).convert("RGB")
        if min(im.size) < 64:
            return False
        im.thumbnail((1024, 1024), Image.Resampling.LANCZOS)
        dest.parent.mkdir(parents=True, exist_ok=True)
        im.save(dest, "JPEG", quality=92)
        return True
    except Exception:
        return False


def augment(im: Image.Image, count: int, rng: random.Random) -> list[Image.Image]:
    out: list[Image.Image] = []
    base = ImageOps.contain(im, (320, 320), Image.Resampling.LANCZOS)
    for i in range(count):
        x = base.copy()
        if rng.random() < 0.85:
            angle = rng.uniform(-18, 18)
            x = x.rotate(angle, resample=Image.Resampling.BICUBIC, expand=False, fillcolor=(rng.randrange(180,255),) * 3)
        if rng.random() < 0.7:
            scale = rng.uniform(0.78, 1.0)
            w, h = x.size
            nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
            x = x.resize((nw, nh), Image.Resampling.LANCZOS)
            bg = Image.new("RGB", (320, 320), tuple(rng.randrange(0, 256) for _ in range(3)))
            px = rng.randrange(max(1, 320 - nw + 1))
            py = rng.randrange(max(1, 320 - nh + 1))
            bg.paste(x, (px, py))
            x = bg
        else:
            x = ImageOps.fit(x, (320, 320), Image.Resampling.LANCZOS)
        if rng.random() < 0.55:
            x = ImageEnhance.Brightness(x).enhance(rng.uniform(0.65, 1.35))
        if rng.random() < 0.45:
            x = ImageEnhance.Contrast(x).enhance(rng.uniform(0.7, 1.35))
        if rng.random() < 0.35:
            x = x.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 1.6)))
        out.append(x)
    return out


def preprocess(im: Image.Image) -> np.ndarray:
    mean = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
    std = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)
    x = ImageOps.fit(im.convert("RGB"), (224, 224), Image.Resampling.BICUBIC)
    a = np.asarray(x).astype(np.float32) / 255.0
    a = (a - mean) / std
    a = np.transpose(a, (2, 0, 1))[None, ...]
    return a


def l2(v: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(v, axis=1, keepdims=True)
    return v / np.clip(n, 1e-12, None)


def infer(session: ort.InferenceSession, images: list[Image.Image]) -> np.ndarray:
    inp = session.get_inputs()[0].name
    arr = np.concatenate([preprocess(im) for im in images], axis=0)
    outs = session.run(None, {inp: arr})[0].astype(np.float32)
    return l2(outs)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-pages", type=int, default=25)
    ap.add_argument("--max-products", type=int, default=4000)
    ap.add_argument("--augments", type=int, default=10)
    ap.add_argument("--max-images-per-product", type=int, default=3)
    ap.add_argument("--seed", type=int, default=20260821)
    args = ap.parse_args()

    if not MODEL.exists() or not MODEL_DATA.exists():
        raise SystemExit("MobileCLIP2 ONNX + external data must exist in the checkout.")

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "source_licenses.md").write_text(
        "# Image-source rights review\n\n"
        "This build records source URLs for provenance. A source being public or\n"
        "easy to download does **not** by itself prove redistribution rights.\n"
        "Before shipping the generated image corpus or a commercial catalog,\n"
        "review each source's terms/licence or obtain written permission.\n",
        encoding="utf-8",
    )

    seed = json.loads(SEED.read_text(encoding="utf-8"))["products"]
    rng = random.Random(args.seed)
    session_http = requests.Session()

    discovered = crawl_bazzarry(session_http, args.max_pages)
    discovered += crawl_generic(session_http, OTHER_SOURCES)
    catalog = build_catalog(seed, discovered)[: args.max_products]
    (OUT / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=2), encoding="utf-8")

    local_dir = OUT / "images"
    hydrated: dict[str, list[Path]] = {}
    for idx, product in enumerate(catalog, 1):
        urls = [u for u in product.get("imageUrls", []) if isinstance(u, str)][: args.max_images_per_product]
        paths: list[Path] = []
        for j, url in enumerate(urls):
            p = local_dir / product["id"] / f"ref-{j}.jpg"
            if download_image(session_http, url, p):
                paths.append(p)
        if paths:
            hydrated[product["id"]] = paths
        if idx % 100 == 0:
            print(f"hydration: {idx}/{len(catalog)}")

    ort_session = ort.InferenceSession(str(MODEL), providers=["CPUExecutionProvider"])
    rows = []
    vectors: list[np.ndarray] = []
    labels: list[str] = []
    images_used = 0
    t0 = time.perf_counter()

    for n, (pid, paths) in enumerate(hydrated.items(), 1):
        ims: list[Image.Image] = []
        for p in paths:
            try:
                im = Image.open(p).convert("RGB")
                ims.extend(augment(im, args.augments, rng))
            except Exception:
                continue
        if not ims:
            continue
        # Bound memory while keeping multiple viewpoints per SKU.
        emb_parts: list[np.ndarray] = []
        for s in range(0, len(ims), 16):
            emb_parts.append(infer(ort_session, ims[s : s + 16]))
        emb = np.concatenate(emb_parts, axis=0)
        vectors.append(emb.astype(np.float32))
        labels.extend([pid] * len(emb))
        images_used += len(ims)
        rows.append({"productId": pid, "referenceCount": len(emb), "localImages": [str(p.relative_to(ROOT)) for p in paths]})
        if n % 50 == 0:
            print(f"embedding: {n}/{len(hydrated)}")

    if not vectors:
        raise SystemExit("No product images could be hydrated; embedding build would be empty.")

    matrix = np.concatenate(vectors, axis=0)
    np.savez_compressed(OUT / "catalog_embeddings.npz", embeddings=matrix.astype(np.float16))
    (OUT / "catalog_embedding_rows.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    (OUT / "catalog_embedding_labels.json").write_text(json.dumps(labels, ensure_ascii=False), encoding="utf-8")

    dt = time.perf_counter() - t0
    stats = {
        "productsInSeed": len(seed),
        "productsInCatalog": len(catalog),
        "productsWithImages": len(hydrated),
        "augmentedReferenceImages": images_used,
        "embeddingDimension": int(matrix.shape[1]),
        "embeddingVectors": int(matrix.shape[0]),
        "encoder": "MobileCLIP2-S0 Vision ONNX",
        "encoding": "float16 archive; convert to float32 bytes for current Flutter embedding persistence",
        "cpuEmbeddingSeconds": round(dt, 2),
        "cpuEmbeddingMillisecondsPerVector": round((dt / max(1, len(labels))) * 1000, 2),
        "builtAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sources": ["Bazzarry", "MAFCO", "Al-Rawdah", "Yemenica"],
        "rights": "source-by-source review required before commercial redistribution",
    }
    (OUT / "build_stats.json").write_text(json.dumps(stats, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(stats, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
