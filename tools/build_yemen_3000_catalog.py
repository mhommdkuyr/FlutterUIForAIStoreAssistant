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
