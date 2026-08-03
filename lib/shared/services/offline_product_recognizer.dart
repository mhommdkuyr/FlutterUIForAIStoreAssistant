import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

import '../models/product_model.dart';

/// Offline product recognition for the PRODUCT-ENTRY scanner screen.
///
/// Provides two matching strategies:
///
/// 1. Text / barcode matching ([findBestMatch]) — used when the user types or
///    scans a barcode string. Scores products by exact barcode, partial
///    barcode, exact name, partial name, category.
///
/// 2. Image matching ([matchImageFile], [matchCameraImage]) — compares a
///    16×16 average hash of the query image against stored product images.
///    Confidence threshold: ≥ 76 % similarity (Hamming distance ≤ 60 / 256).
///
/// For the LIVE SCAN workspace, use [ProductFingerprintService] +
/// [ScanLockManager] instead — they cache hashes at session start and run
/// the hot-path comparison in the frame callback.
class OfflineProductRecognizer {
  // Reject image matches below this similarity (Hamming distance threshold).
  static const int _maxHammingDistance = 60; // out of 256 bits

  // Minimum text/barcode score to accept a match.
  static const double _minTextScore = 0.82;

  /// Debounce used by legacy callers (kept for API compat).
  static const Duration debounceDuration = Duration(seconds: 2);

  // ── Text / barcode matching ─────────────────────────────────────────────────

  /// Find the best product matching [query] (barcode or name text).
  ///
  /// Returns null when no product passes the confidence threshold.
  static ProductModel? findBestMatch(
    List<ProductModel> products,
    String query,
  ) {
    if (products.isEmpty) return null;
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return null;

    ProductModel? best;
    double bestScore = 0;
    for (final p in products) {
      final s = _scoreProduct(p, normalized);
      if (s > bestScore) {
        bestScore = s;
        best = p;
      }
    }
    return (best != null && bestScore >= _minTextScore) ? best : null;
  }

  // ── Image matching ──────────────────────────────────────────────────────────

  /// Match a photo at [imagePath] (local file) against stored product images.
  static Future<ProductModel?> matchImageFile(
    List<ProductModel> products,
    String imagePath,
  ) async {
    final queryHash = await _hashFromFile(imagePath);
    if (queryHash == null) return null;
    return _findBestHashMatch(products, queryHash);
  }

  /// Match a live [CameraImage] frame against stored product images.
  static Future<ProductModel?> matchCameraImage(
    List<ProductModel> products,
    CameraImage image,
  ) async {
    final queryHash = _hashFromCameraImage(image);
    if (queryHash == null) return null;
    return _findBestHashMatch(products, queryHash);
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  static Future<ProductModel?> _findBestHashMatch(
    List<ProductModel> products,
    Uint8List queryHash,
  ) async {
    ProductModel? best;
    int bestDist = _maxHammingDistance + 1;

    for (final p in products) {
      final url = p.imageUrl?.trim();
      if (url == null || url.isEmpty) continue;
      final storedHash = await _hashFromFile(url);
      if (storedHash == null) continue;
      final d = _hammingDistance(queryHash, storedHash);
      if (d < bestDist) {
        bestDist = d;
        best = p;
      }
    }
    return best;
  }

  // ── Hash computation ────────────────────────────────────────────────────────

  static const int _n = 16; // 16×16 = 256-bit hash

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
          pix[y * _n + x] = small.getPixel(x, y).r.toInt();
        }
      }
      return _averageHash(pix);
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _hashFromCameraImage(CameraImage image) {
    try {
      final plane = image.planes[0];
      final w = image.width;
      final h = image.height;
      final bytes = plane.bytes;
      final stride = plane.bytesPerRow;
      final pix = List<int>.filled(_n * _n, 0);
      for (var r = 0; r < _n; r++) {
        for (var c = 0; c < _n; c++) {
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

  static Uint8List _averageHash(List<int> pix) {
    final mean = pix.fold(0, (s, v) => s + v) ~/ pix.length;
    final hash = Uint8List(pix.length >> 3);
    for (var i = 0; i < pix.length; i++) {
      if (pix[i] >= mean) hash[i >> 3] |= 1 << (i & 7);
    }
    return hash;
  }

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

  // ── Text score helper ───────────────────────────────────────────────────────

  static double _scoreProduct(ProductModel p, String q) {
    final barcode = (p.barcode ?? '').trim().toLowerCase();
    final name = p.name.trim().toLowerCase();
    final altName = (p.nameAr ?? '').trim().toLowerCase();
    final category = p.category.trim().toLowerCase();

    if (barcode.isNotEmpty && barcode == q) return 1.0;
    if (barcode.isNotEmpty && barcode.contains(q)) return 0.95;
    if (name == q || altName == q) return 0.90;
    if (name.contains(q) || altName.contains(q)) return 0.84;
    if (category.contains(q)) return 0.72;
    return 0.0;
  }
}
