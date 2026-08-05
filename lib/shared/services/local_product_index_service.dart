import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/product_model.dart';
import 'embedding_persistence_service.dart';
import 'product_recognition_result.dart';
import 'visual_embedding_service.dart';

/// In-memory product recognition index.
///
/// Preloads visual embeddings for all enrolled products at session start and
/// answers [search] queries in microseconds — pure in-memory similarity
/// comparisons, no disk I/O per frame.
///
/// **Multiple reference images per product** are supported.
///
/// **Embedding persistence** (optional): pass an [EmbeddingPersistenceService]
/// to cache embeddings in SQLite. The first open computes and persists them;
/// subsequent opens skip recomputation entirely.
///
/// Lifecycle:
/// 1. Call [buildIndex] once when the live-scan session starts.
/// 2. Call [refreshProduct] after any create/update operation.
/// 3. Call [removeProduct] after a deletion.
/// 4. Call [search] per camera frame.
class LocalProductIndexService {
  LocalProductIndexService({
    VisualEmbeddingService? embeddingService,
    EmbeddingPersistenceService? persistenceService,
  })  : _embedding = embeddingService ?? AHashEmbeddingService(),
        _persistence = persistenceService;

  final VisualEmbeddingService _embedding;
  final EmbeddingPersistenceService? _persistence;

  /// productId → list of precomputed embeddings (one per reference image).
  final Map<String, List<Uint8List>> _index = {};

  bool _built = false;

  bool get isBuilt => _built;
  int get indexedProductCount => _index.length;

  // ── Index management ───────────────────────────────────────────────────────

  /// Build (or rebuild) the full recognition index.
  ///
  /// For each product, embeds:
  ///   1. The primary [ProductModel.imageUrl].
  ///   2. Any additional paths in [extraImagePaths].
  ///
  /// When [_persistence] is set, previously cached embeddings are loaded from
  /// the DB first; only missing ones are recomputed and then saved.
  Future<void> buildIndex(
    List<ProductModel> products, {
    Map<String, List<String>> extraImagePaths = const {},
  }) async {
    _index.clear();
    _built = false;

    // Load cached embeddings for the current model version (if available).
    final cached = await _persistence?.loadAll(_embedding.modelVersion) ?? {};

    for (final product in products) {
      final paths =
          _pathsFor(product, extraImagePaths[product.id] ?? const []);
      final hashes = <Uint8List>[];

      for (final path in paths) {
        // 1. Try the DB cache first.
        final fromCache = cached[product.id]?[path];
        if (fromCache != null) {
          hashes.add(fromCache);
          continue;
        }

        // 2. Compute from disk.
        final computed = await _embedding.embedFile(path);
        if (computed != null) {
          hashes.add(computed);
          // 3. Persist so future builds are instant.
          await _persistence?.save(
            productId: product.id,
            imagePath: path,
            embedding: computed,
            modelVersion: _embedding.modelVersion,
          );
        } else {
          debugPrint(
            '[Index] embedFile returned null for "$path" '
            '(product ${product.id}) — file missing or unreadable; skipping.',
          );
        }
      }

      if (hashes.isNotEmpty) {
        _index[product.id] = hashes;
      }
    }

    _built = true;
  }

  /// Refresh a single product entry (call after create / update / new image).
  Future<void> refreshProduct(
    ProductModel product, {
    List<String> extraPaths = const [],
  }) async {
    final paths = _pathsFor(product, extraPaths);
    final hashes = <Uint8List>[];

    for (final path in paths) {
      final h = await _embedding.embedFile(path);
      if (h != null) {
        hashes.add(h);
        await _persistence?.save(
          productId: product.id,
          imagePath: path,
          embedding: h,
          modelVersion: _embedding.modelVersion,
        );
      }
    }

    if (hashes.isNotEmpty) {
      _index[product.id] = hashes;
    } else {
      _index.remove(product.id);
    }
  }

  /// Remove a product from the index (call after deletion).
  void removeProduct(String productId) {
    _index.remove(productId);
    _persistence?.deleteProduct(productId);
  }

  // ── Search ─────────────────────────────────────────────────────────────────

  /// Return the top-K best-matching products for [queryEmbedding].
  ///
  /// Similarity is computed via [VisualEmbeddingService.similarity], which
  /// dispatches to cosine distance (TFLite) or normalised Hamming (aHash)
  /// depending on the active backend.
  ///
  /// Only candidates with [confidence] ≥ [minConfidence] are included.
  List<RecognitionCandidate> search(
    Uint8List queryEmbedding, {
    int topK = 3,
    double? minConfidence,
  }) {
    final threshold = minConfidence ?? _embedding.recommendedMinConfidence;
    if (_index.isEmpty) return const [];

    final results = <RecognitionCandidate>[];

    for (final entry in _index.entries) {
      var bestSim = 0.0;
      for (final stored in entry.value) {
        final s = _embedding.similarity(queryEmbedding, stored);
        if (s > bestSim) bestSim = s;
      }
      if (bestSim >= threshold) {
        results.add(RecognitionCandidate(
          productId: entry.key,
          confidence: bestSim,
          hammingDistance: 0, // N/A for cosine; kept for API compat
        ));
      }
    }

    results.sort((a, b) => b.confidence.compareTo(a.confidence));
    return results.take(topK).toList();
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  static List<String> _pathsFor(ProductModel product, List<String> extras) {
    final paths = <String>[];
    final url = product.imageUrl;
    if (url != null && url.isNotEmpty) paths.add(url);
    paths.addAll(extras);
    return paths;
  }
}
