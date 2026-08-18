# MobileCLIP2-S0 Vision — ONNX model assets

Runtime assets:

- `mobileclip2_s0_vision.onnx`
- `mobileclip2_s0_vision.onnx.data`
- `model_metadata.json`
- `verification_report.json`
- `README.md`

Model contract:

- Format: ONNX
- ONNX opset: 18
- Input resolution: `224 x 224`
- Input: RGB float32 after metadata-defined CLIP normalization
- Embedding dimension: 512
- Output: float32 embedding, L2-normalized by the application before persistence/search

The `.onnx.data` file is external model data required by the ONNX model and must be packaged with the `.onnx` file. The binary model files must not be replaced by stubs.
