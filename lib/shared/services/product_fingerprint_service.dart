import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

import '../models/product_model.dart';

/// Fast 16×16 average-hash (256-bit) fingerprint service for product images.
///
/// Usage:
///   1. Call [preload] once when the live-scan session starts.
///   2. For each camera frame, call [hashFromCameraImage] (fast — Y-plane only).
///   3. Call [findBestMatch] with the frame hash to identify the product.
///
/// Multiple fingerprints per product are supported (e.g. front/back/angle).
/// Only 1 is stored by default (the product's stored image). The infrastructure
/// is ready for multi-angle enrollment in future.
class ProductFingerprintService {
  // 16×16 = 256 bits per hash → 32-byte Uint8List
  static const int _n = 16;

  // Hamming distance threshold: ≤ 60 / 256 bits different ≈ 76 % similarity.
  // Empirically: same product under similar lighting → ≤ 20 bits different;
  // different products → typically > 80 bits different.
  static const int _maxDist = 60;

  // productId → list of pre-computed hashes (supports multi-angle)
  final Map<String, List<Uint8List>> _cache = {};

  bool _loaded = false;
  bool get isLoaded => _loaded;

  // ── Pre-loading ─────────────────────────────────────────────────────────────

  /// Pre-computes hashes for all products that have a local image file.
  /// Should be called once at session start (async, I/O-bound).
  Future<void> preload(List<ProductModel> products) async {
    _cache.clear();
    _loaded = false;
    for (final p in products) {
      await _enroll(p);
    }
    _loaded = true;
  }

  /// Update or remove the fingerprint for a single product (e.g. after edit).
  Future<void> updateProduct(ProductModel p) => _enroll(p);

  /// Remove all fingerprints for a product (call after deletion).
  void removeProduct(String productId) => _cache.remove(productId);

  // ── Matching ────────────────────────────────────────────────────────────────

  /// Returns the best-matching product for [frameHash], or null if no product
  /// passes the confidence threshold.
  ProductModel? findBestMatch(
    Uint8List frameHash,
    List<ProductModel> products,
  ) {
    if (_cache.isEmpty) return null;

    String? bestId;
    int bestDist = _maxDist + 1;

    for (final entry in _cache.entries) {
      for (final stored in entry.value) {
        final d = _hammingDistance(frameHash, stored);
        if (d < bestDist) {
          bestDist = d;
          bestId = entry.key;
        }
      }
    }

    if (bestId == null) return null;
    try {
      return products.firstWhere((p) => p.id == bestId);
    } catch (_) {
      return null;
    }
  }

  // ── Frame hash (called per frame — must be fast) ─────────────────────────────

  /// Compute a 16×16 aHash from a [CameraImage].
  ///
  /// Uses only the Y (luminance) plane — no color conversion needed.
  /// This is the hot path; it does 256 integer reads + 256 comparisons.
  static Uint8List? hashFromCameraImage(CameraImage image) {
    try {
      // On Android, planes[0] is Y (full resolution, 1 byte per pixel).
      // On iOS with BGRA8888, planes[0] is the interleaved BGRA plane.
      final plane = image.planes[0];
      final w = image.width;
      final h = image.height;
      final bytes = plane.bytes;
      final stride = plane.bytesPerRow;

      final pix = List<int>.filled(_n * _n, 0);
      for (var r = 0; r < _n; r++) {
        for (var c = 0; c < _n; c++) {
          // Sample center of each cell
          final sx = ((c + 0.5) * w / _n).toInt().clamp(0, w - 1);
          final sy = ((r + 0.5) * h / _n).toInt().clamp(0, h - 1);
          final idx = sy * stride + sx;
          pix[r * _n + c] = idx < bytes.length ? bytes[idx] : 0;
        }
      }
      return _averageHash(pix);
    } catch (_) {
      return null;
    }
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  Future<void> _enroll(ProductModel p) async {
    final url = p.imageUrl;
    if (url == null || url.isEmpty) {
      _cache.remove(p.id);
      return;
    }
    final h = await _hashFromFile(url);
    if (h != null) {
      _cache[p.id] = [h];
    } else {
      _cache.remove(p.id);
    }
  }

  static Future<Uint8List?> _hashFromFile(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      final gray = img.grayscale(decoded);
      final small = img.copyResize(gray, width: _n, height: _n);

      final pix = List<int>.filled(_n * _n, 0);
      for (var y = 0; y < _n; y++) {
        for (var x = 0; x < _n; x++) {
          // img.grayscale sets r == g == b; take the r channel as luminance.
          pix[y * _n + x] = small.getPixel(x, y).r.toInt();
        }
      }
      return _averageHash(pix);
    } catch (_) {
      return null;
    }
  }

  /// 256-bit average hash: bit[i] = 1 if pixel[i] ≥ mean, else 0.
  /// Packed as 32 bytes (little-endian within each byte).
  static Uint8List _averageHash(List<int> pix) {
    final mean = pix.fold(0, (s, v) => s + v) ~/ pix.length;
    final hash = Uint8List(pix.length >> 3); // 256 / 8 = 32
    for (var i = 0; i < pix.length; i++) {
      if (pix[i] >= mean) hash[i >> 3] |= 1 << (i & 7);
    }
    return hash;
  }

  /// Count differing bits (Hamming distance) between two equal-length hashes.
  static int _hammingDistance(Uint8List a, Uint8List b) {
    if (a.length != b.length) return 256;
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
}
