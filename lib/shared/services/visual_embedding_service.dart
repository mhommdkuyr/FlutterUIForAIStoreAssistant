import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

import 'frame_preprocessor.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Abstract interface
// ─────────────────────────────────────────────────────────────────────────────

/// Computes visual feature vectors ("embeddings") from images.
///
/// The current production implementation is [AHashEmbeddingService], which
/// uses a 16×16 average hash. The interface is deliberately thin so a
/// neural-network backend (e.g. MobileNet via tflite) can be swapped in
/// later without touching the pipeline.
abstract class VisualEmbeddingService {
  /// Compute an embedding for a local image file.
  ///
  /// Returns `null` when the file is missing, unreadable, or unsupported.
  /// I/O-bound — await on a non-UI isolate when possible.
  Future<Uint8List?> embedFile(String path);

  /// Compute an embedding for a live camera frame.
  ///
  /// Synchronous — must complete within one frame budget (~16 ms).
  /// Returns `null` on failure.
  Uint8List? embedFrame(CameraImage image);

  /// Similarity between two embeddings: 1.0 = identical, 0.0 = unrelated.
  double similarity(Uint8List a, Uint8List b);

  /// Length of each embedding in bytes.
  int get embeddingLength;
}

// ─────────────────────────────────────────────────────────────────────────────
// AHashEmbeddingService  —  production implementation
// ─────────────────────────────────────────────────────────────────────────────

/// Average-hash (aHash) visual embedding.
///
/// Each embedding is [_n × _n / 8] bytes (32 bytes for the default n=16).
/// Bit i is 1 iff the i-th cell's luminance ≥ the grid's mean luminance.
///
/// Similarity score: `1.0 − (hammingDist / (_n * _n))`
///
/// Empirical thresholds (16×16 grid):
///   • Same product, similar lighting → Hamming ≤ 20 → similarity ≥ 0.92
///   • Different products             → Hamming  > 80 → similarity  < 0.69
class AHashEmbeddingService implements VisualEmbeddingService {
  AHashEmbeddingService({int gridSize = 16})
      : _n = gridSize,
        _preprocessor = FramePreprocessor(gridSize: gridSize);

  final int _n;
  final FramePreprocessor _preprocessor;

  @override
  int get embeddingLength => (_n * _n) >> 3; // 256 bits → 32 bytes

  // ── VisualEmbeddingService ─────────────────────────────────────────────────

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

  // ── Extras ─────────────────────────────────────────────────────────────────

  /// Raw Hamming distance between two hash embeddings.
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

  // ── Internal ────────────────────────────────────────────────────────────────

  static Uint8List _averageHash(List<int> pix) {
    final mean = pix.fold(0, (s, v) => s + v) ~/ pix.length;
    final hash = Uint8List(pix.length >> 3);
    for (var i = 0; i < pix.length; i++) {
      if (pix[i] >= mean) hash[i >> 3] |= 1 << (i & 7);
    }
    return hash;
  }
}
