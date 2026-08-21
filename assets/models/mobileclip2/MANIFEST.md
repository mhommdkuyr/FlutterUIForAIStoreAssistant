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
- Runtime input: RGB float32 in `[0,1]` with mean=`(0,0,0)` and std=`(1,1,1)`, matching the official MobileCLIP2-S0 preprocessing contract
- Embedding dimension: 512
- Output: float32 embedding, L2-normalized by the application before persistence/search

The `normalization` field in `model_metadata.json` records the export metadata retained for provenance. The `runtime_preprocessing` field is the authoritative runtime contract for S0, and the fast Android provider pins the runtime to it.

The `.onnx.data` file is external model data required by the ONNX model and must be packaged with the `.onnx` file. The binary model files must not be replaced by stubs.
