import 'dart:typed_data';

import '../models/product_model.dart';
import 'product_recognition_result.dart';
import 'visual_embedding_service.dart';

/// In-memory product recognition index.
///
/// Preloads visual embeddings (hashes) for all enrolled products at session
/// start, then answers [search] queries in microseconds — pure in-memory
/// Hamming distance comparisons, no disk I/O per frame.
///
/// **Multiple reference images per product** are supported: supply additional
/// file paths via [extraImagePaths] in [buildIndex] or [refreshProduct].
/// All embeddings for a product are stored together; the best-matching one
/// wins in a search.
///
/// Lifecycle:
/// 1. Call [buildIndex] once when the live-scan session starts.
/// 2. Call [refreshProduct] after any create/update operation.
/// 3. Call [removeProduct] after a deletion.
/// 4. Call [search] per camera frame.
class LocalProductIndexService {
  LocalProductIndexService({VisualEmbeddingService? embeddingService})
      : _embedding = embeddingService ?? AHashEmbeddingService();

  final VisualEmbeddingService _embedding;

  /// productId → list of precomputed embeddings (one per reference image).
  final Map<String, List<Uint8List>> _index = {};

  bool _built = false;

  /// Whether [buildIndex] has completed at least once.
  bool get isBuilt => _built;

  /// Number of products currently in the index.
  int get indexedProductCount => _index.length;

  // ── Index management ───────────────────────────────────────────────────────

  /// Build (or rebuild) the index from [products].
  ///
  /// For each product, embeds:
  ///   1. The primary [ProductModel.imageUrl] (if present).
  ///   2. Any additional paths supplied in [extraImagePaths].
  ///
  /// Typically called once at session start. Disk-bound; run on a non-UI
  /// isolate or in an async gap before displaying the camera.
  Future<void> buildIndex(
    List<ProductModel> products, {
    Map<String, List<String>> extraImagePaths = const {},
  }) async {
    _index.clear();
    _built = false;

    for (final product in products) {
      await _embedAndStore(product.id,
          _pathsFor(product, extraImagePaths[product.id] ?? const []));
    }
    _built = true;
  }

  /// Refresh a single product's entry (call after create / update / new image).
  ///
  /// Safe to call while the scanner is running — updates atomically.
  Future<void> refreshProduct(
    ProductModel product, {
    List<String> extraPaths = const [],
  }) =>
      _embedAndStore(product.id, _pathsFor(product, extraPaths));

  /// Remove a product from the index (call after deletion).
  void removeProduct(String productId) => _index.remove(productId);

  // ── Search ─────────────────────────────────────────────────────────────────

  /// Return the top-K best-matching products for [queryHash].
  ///
  /// Only candidates with [confidence] ≥ [minConfidence] are included.
  /// Results are sorted by confidence descending.
  List<RecognitionCandidate> search(
    Uint8List queryHash, {
    int topK = 3,
    double minConfidence = 0.70,
  }) {
    if (_index.isEmpty) return const [];

    final results = <RecognitionCandidate>[];

    for (final entry in _index.entries) {
      int bestDist = 256;
      for (final storedHash in entry.value) {
        final d = _hammingDistance(queryHash, storedHash);
        if (d < bestDist) bestDist = d;
      }
      // Confidence = 1 − normalised Hamming distance (0.0–1.0)
      final confidence = 1.0 - (bestDist / 256.0);
      if (confidence >= minConfidence) {
        results.add(RecognitionCandidate(
          productId: entry.key,
          confidence: confidence,
          hammingDistance: bestDist,
        ));
      }
    }

    results.sort((a, b) => b.confidence.compareTo(a.confidence));
    return results.take(topK).toList();
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  static List<String> _pathsFor(
    ProductModel product,
    List<String> extras,
  ) {
    final paths = <String>[];
    final url = product.imageUrl;
    if (url != null && url.isNotEmpty) paths.add(url);
    paths.addAll(extras);
    return paths;
  }

  Future<void> _embedAndStore(String productId, List<String> paths) async {
    final hashes = <Uint8List>[];
    for (final path in paths) {
      final h = await _embedding.embedFile(path);
      if (h != null) hashes.add(h);
    }
    if (hashes.isNotEmpty) {
      _index[productId] = hashes;
    } else {
      _index.remove(productId);
    }
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
}
