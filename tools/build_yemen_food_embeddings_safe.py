"""Safe launcher for the Yemen catalog builder.

The production MobileCLIP2 contract is validated as batch size 1. This wrapper
keeps the crawler/augmentation code unchanged while forcing one-image-at-a-time
ONNX inference so the build works even when the exported graph has a fixed
batch dimension.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import build_yemen_food_embeddings as builder  # noqa: E402
import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402


def infer_fixed_batch(session, images: list[Image.Image]) -> np.ndarray:
    input_name = session.get_inputs()[0].name
    outputs: list[np.ndarray] = []
    for image in images:
        sample = builder.preprocess(image)
        raw = session.run(None, {input_name: sample})[0].astype(np.float32)
        if raw.shape != (1, 512):
            raise RuntimeError(f"MobileCLIP2 output must be [1,512], got {raw.shape}")
        outputs.append(raw[0])
    matrix = np.stack(outputs, axis=0)
    return builder.l2(matrix)


builder.infer = infer_fixed_batch

if __name__ == "__main__":
    builder.main()
