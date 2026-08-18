# MobileCLIP2-S0 model asset

Expected runtime asset:

- `mobileclip2_s0_image_encoder.tflite`

Source of weights:

- Official Apple repository: https://github.com/apple/ml-mobileclip
- Official Apple Hugging Face checkpoint: https://huggingface.co/apple/MobileCLIP2-S0

Requirements:

- Export only the image encoder.
- Input shape: `[1, 256, 256, 3]`, float32 RGB after CLIP normalization.
- Output shape: `[1, 512]`, float32.
- Service normalizes output with L2 before persistence/search.

The binary model is intentionally not replaced by a stub. If this file is absent,
`MobileVisionEmbeddingService.initialize()` fails and the scanner reports that the
visual engine is unavailable instead of falling back to aHash.
