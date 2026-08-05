import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'frame_preprocessor.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Abstract interface
// ─────────────────────────────────────────────────────────────────────────────

/// Computes visual feature vectors ("embeddings") from images.
///
/// Two production implementations are provided:
///   • [TfLiteEmbeddingService]  — MobileNetV3-Small on-device model (primary)
///   • [AHashEmbeddingService]   — 16×16 average hash (fallback / fast path)
///
/// Use [VisualEmbeddingProvider] to get automatic primary/fallback dispatch
/// without knowing which backend is active.
abstract class VisualEmbeddingService {
  /// Compute an embedding for a local image file (I/O-bound, async).
  Future<Uint8List?> embedFile(String path);

  /// Compute an embedding for a live camera frame (synchronous, ~frame budget).
  Uint8List? embedFrame(CameraImage image);

  /// Similarity score: 1.0 = identical, 0.0 = completely unrelated.
  double similarity(Uint8List a, Uint8List b);

  /// Length of each embedding in bytes.
  int get embeddingLength;

  /// Identifies the model so persisted embeddings can be invalidated on upgrade.
  String get modelVersion;

  /// Recommended minimum similarity threshold for this embedding type.
  double get recommendedMinConfidence;
}

// ─────────────────────────────────────────────────────────────────────────────
// TfLiteEmbeddingService  —  MobileNetV3-Small local inference (primary)
// ─────────────────────────────────────────────────────────────────────────────

/// Real on-device visual embedding using a bundled MobileNetV3-Small model.
///
/// **Model**: `assets/models/mobilenet_v3_small_embedder.tflite`
///   Input  : [1, 224, 224, 3] float32, values normalised to [0.0, 1.0]
///   Output : [1, N] float32 feature vector (N discovered at load time, ~1024)
///
/// The model is packaged inside the APK/IPA — no internet required.
/// Call [initialize] once before use; the service is safe to share.
class TfLiteEmbeddingService implements VisualEmbeddingService {
  static const String assetPath =
      'assets/models/mobilenet_v3_small_embedder.tflite';

  static const int _inputSize = 224;

  Interpreter? _interpreter;
  int _outputDims = 1024; // updated after model load

  bool get isInitialized => _interpreter != null;

  /// Load the bundled TFLite model. Throws on failure.
  Future<void> initialize() async {
    final data = await rootBundle.load(assetPath);
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final interpreter = Interpreter.fromBuffer(bytes);
    // Discover actual output dimension from the model graph.
    final outShape = interpreter.getOutputTensor(0).shape;
    _outputDims = outShape.last; // [1, N] → N
    _interpreter = interpreter;
  }

  // ── VisualEmbeddingService ─────────────────────────────────────────────────

  @override
  String get modelVersion => 'mv3_small_224_float32_v1';

  @override
  double get recommendedMinConfidence => 0.45;

  @override
  int get embeddingLength => _outputDims * 4; // float32 = 4 bytes each

  @override
  Future<Uint8List?> embedFile(String path) async {
    if (_interpreter == null) return null;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final raw = await file.readAsBytes();
      final decoded = img.decodeImage(raw);
      if (decoded == null) return null;
      return _runInference(_prepareImageTensor(decoded));
    } catch (_) {
      return null;
    }
  }

  @override
  Uint8List? embedFrame(CameraImage image) {
    if (_interpreter == null) return null;
    try {
      final input = _prepareFrameTensor(image);
      if (input == null) return null;
      return _runInference(input);
    } catch (_) {
      return null;
    }
  }

  @override
  double similarity(Uint8List a, Uint8List b) => _cosineSimilarity(a, b);

  // ── Tensor preparation ─────────────────────────────────────────────────────

  /// Decode and resize an image to [_inputSize]×[_inputSize], return as
  /// flat Float32List [H×W×3] with values normalised to [0.0, 1.0].
  Float32List _prepareImageTensor(img.Image decoded) {
    final resized =
        img.copyResize(decoded, width: _inputSize, height: _inputSize);
    final input = Float32List(_inputSize * _inputSize * 3);
    var i = 0;
    for (var y = 0; y < _inputSize; y++) {
      for (var x = 0; x < _inputSize; x++) {
        final p = resized.getPixel(x, y);
        input[i++] = p.r / 255.0;
        input[i++] = p.g / 255.0;
        input[i++] = p.b / 255.0;
      }
    }
    return input;
  }

  /// Convert a live camera frame directly into a 224×224×3 Float32List,
  /// sampling at [_inputSize]×[_inputSize] grid points for efficiency
  /// (avoids creating a full-resolution intermediate image).
  Float32List? _prepareFrameTensor(CameraImage image) {
    try {
      switch (image.format.group) {
        case ImageFormatGroup.yuv420:
          return _fromYuv420(image);
        case ImageFormatGroup.bgra8888:
          return _fromBgra8888(image);
        default:
          // Fallback: full decode (slow path — usually not reached)
          final decoded = img.decodeImage(image.planes[0].bytes);
          if (decoded == null) return null;
          return _prepareImageTensor(decoded);
      }
    } catch (_) {
      return null;
    }
  }

  Float32List _fromYuv420(CameraImage image) {
    final w = image.width;
    final h = image.height;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final uvStep = uPlane.bytesPerPixel ?? 1;

    final input = Float32List(_inputSize * _inputSize * 3);
    var idx = 0;

    for (var row = 0; row < _inputSize; row++) {
      for (var col = 0; col < _inputSize; col++) {
        final sx = (col * w / _inputSize).toInt().clamp(0, w - 1);
        final sy = (row * h / _inputSize).toInt().clamp(0, h - 1);

        final yIdx = sy * yPlane.bytesPerRow + sx;
        final uvRow = sy >> 1;
        final uvCol = sx >> 1;
        final uIdx = uvRow * uPlane.bytesPerRow + uvCol * uvStep;
        final vIdx = uvRow * vPlane.bytesPerRow + uvCol * uvStep;

        if (yIdx >= yPlane.bytes.length) {
          input[idx++] = 0;
          input[idx++] = 0;
          input[idx++] = 0;
          continue;
        }

        final yv = yPlane.bytes[yIdx];
        final uv = uIdx < uPlane.bytes.length ? uPlane.bytes[uIdx] - 128 : 0;
        final vv = vIdx < vPlane.bytes.length ? vPlane.bytes[vIdx] - 128 : 0;

        final r = (yv + 1.402 * vv).clamp(0, 255).toInt();
        final g = (yv - 0.344136 * uv - 0.714136 * vv).clamp(0, 255).toInt();
        final b = (yv + 1.772 * uv).clamp(0, 255).toInt();

        input[idx++] = r / 255.0;
        input[idx++] = g / 255.0;
        input[idx++] = b / 255.0;
      }
    }
    return input;
  }

  Float32List _fromBgra8888(CameraImage image) {
    final w = image.width;
    final h = image.height;
    final bytes = image.planes[0].bytes;
    final stride = image.planes[0].bytesPerRow;

    final input = Float32List(_inputSize * _inputSize * 3);
    var idx = 0;

    for (var row = 0; row < _inputSize; row++) {
      for (var col = 0; col < _inputSize; col++) {
        final sx = (col * w / _inputSize).toInt().clamp(0, w - 1);
        final sy = (row * h / _inputSize).toInt().clamp(0, h - 1);
        final base = sy * stride + sx * 4;

        if (base + 2 >= bytes.length) {
          input[idx++] = 0;
          input[idx++] = 0;
          input[idx++] = 0;
          continue;
        }
        input[idx++] = bytes[base + 2] / 255.0; // R
        input[idx++] = bytes[base + 1] / 255.0; // G
        input[idx++] = bytes[base + 0] / 255.0; // B (BGRA → B at base+0)
      }
    }
    return input;
  }

  // ── Inference ──────────────────────────────────────────────────────────────

  Uint8List? _runInference(Float32List inputTensor) {
    final interpreter = _interpreter;
    if (interpreter == null) return null;

    final output = Float32List(_outputDims);
    interpreter.run(inputTensor, output);

    // L2-normalise so cosine similarity == dot product
    _l2Normalize(output);
    return output.buffer.asUint8List();
  }

  static void _l2Normalize(Float32List v) {
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    norm = sqrt(norm);
    if (norm < 1e-10) return;
    for (var i = 0; i < v.length; i++) {
      v[i] /= norm;
    }
  }

  // ── Cosine similarity ──────────────────────────────────────────────────────

  static double _cosineSimilarity(Uint8List a, Uint8List b) {
    if (a.length != b.length) return 0.0;
    final fa = a.buffer.asFloat32List(a.offsetInBytes, a.lengthInBytes ~/ 4);
    final fb = b.buffer.asFloat32List(b.offsetInBytes, b.lengthInBytes ~/ 4);
    // Both vectors are L2-normalised → cosine sim == dot product
    var dot = 0.0;
    for (var i = 0; i < fa.length; i++) {
      dot += fa[i] * fb[i];
    }
    return dot.clamp(0.0, 1.0);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// VisualEmbeddingProvider  —  primary/fallback dispatch
// ─────────────────────────────────────────────────────────────────────────────

/// Wraps [TfLiteEmbeddingService] (primary) with [AHashEmbeddingService]
/// (fallback) so the rest of the stack never has to deal with init failures.
///
/// Call [initialize] once before using the provider. If TFLite fails to load
/// (model missing, platform unsupported, etc.) the provider transparently
/// falls back to aHash — the scanner keeps working, just with lower accuracy.
class VisualEmbeddingProvider implements VisualEmbeddingService {
  final TfLiteEmbeddingService _tflite = TfLiteEmbeddingService();
  final AHashEmbeddingService _ahash = AHashEmbeddingService();

  bool _tfliteReady = false;

  bool get isTfLiteActive => _tfliteReady;

  Future<void> initialize() async {
    try {
      await _tflite.initialize();
      _tfliteReady = true;
      debugPrint(
        '[Embedding] TFLite backend active '
        '(${TfLiteEmbeddingService.assetPath})',
      );
    } catch (e) {
      // TFLite unavailable (e.g. unit-test host without native libs) → aHash.
      // Recognition still works, but accuracy is lower (perceptual hash only).
      _tfliteReady = false;
      debugPrint(
        '[Embedding] TFLite init failed ($e). '
        'Falling back to aHash — recognition is active but accuracy is reduced.',
      );
    }
  }

  VisualEmbeddingService get _active => _tfliteReady ? _tflite : _ahash;

  @override
  String get modelVersion => _active.modelVersion;
  @override
  double get recommendedMinConfidence => _active.recommendedMinConfidence;
  @override
  int get embeddingLength => _active.embeddingLength;
  @override
  Future<Uint8List?> embedFile(String path) => _active.embedFile(path);
  @override
  Uint8List? embedFrame(CameraImage image) => _active.embedFrame(image);
  @override
  double similarity(Uint8List a, Uint8List b) => _active.similarity(a, b);
}

// ─────────────────────────────────────────────────────────────────────────────
// AHashEmbeddingService  —  16×16 average hash (fallback)
// ─────────────────────────────────────────────────────────────────────────────

/// Average-hash (aHash) visual embedding — 256-bit hash stored in 32 bytes.
///
/// Used as the fallback when TFLite is unavailable (e.g. in unit tests running
/// on the host machine, or on devices without TFLite native libraries).
class AHashEmbeddingService implements VisualEmbeddingService {
  AHashEmbeddingService({int gridSize = 16})
      : _n = gridSize,
        _preprocessor = FramePreprocessor(gridSize: gridSize);

  final int _n;
  final FramePreprocessor _preprocessor;

  @override
  String get modelVersion => 'ahash_${_n}x${_n}';
  @override
  double get recommendedMinConfidence => 0.70;
  @override
  int get embeddingLength => (_n * _n) >> 3; // 256 bits → 32 bytes

  @override
  Future<Uint8List?> embedFile(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final rawBytes = await file.readAsBytes();
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) return null;
      final gray = img.grayscale(decoded);
      final small = img.copyResize(gray, width: _n, height: _n);
      final pix = List<int>.filled(_n * _n, 0);
      for (var y = 0; y < _n; y++) {
        for (var x = 0; x < _n; x++) {
          pix[y * _n + x] = small.getPixel(x, y).r.toInt();
        }
      }
      return _averageHash(pix);
    } catch (_) {
      return null;
    }
  }

  @override
  Uint8List? embedFrame(CameraImage image) {
    try {
      final pix = _preprocessor.extractLuminanceGrid(image);
      if (pix == null) return null;
      return _averageHash(pix);
    } catch (_) {
      return null;
    }
  }

  @override
  double similarity(Uint8List a, Uint8List b) {
    final dist = hammingDistance(a, b);
    return 1.0 - (dist / (_n * _n));
  }

  int hammingDistance(Uint8List a, Uint8List b) {
    if (a.length != b.length) return _n * _n;
    var dist = 0;
    for (var i = 0; i < a.length; i++) {
      var x = a[i] ^ b[i];
      while (x != 0) {
        dist += x & 1;
        x >>= 1;
      }
    }
    return dist;
  }

  static Uint8List _averageHash(List<int> pix) {
    final mean = pix.fold(0, (s, v) => s + v) ~/ pix.length;
    final hash = Uint8List(pix.length >> 3);
    for (var i = 0; i < pix.length; i++) {
      if (pix[i] >= mean) hash[i >> 3] |= 1 << (i & 7);
    }
    return hash;
  }
}
