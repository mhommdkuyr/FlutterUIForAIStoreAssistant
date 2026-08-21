import 'dart:typed_data';

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
/// to cache embeddings in SQLite. Precomputed catalog embeddings are also
/// supported, even when the product has no local image file.
class LocalProductIndexService {
  LocalProductIndexService({
    VisualEmbeddingService? embeddingService,
    EmbeddingPersistenceService? persistenceService,
  })  : _embedding = embeddingService ?? VisualEmbeddingProvider(),
        _persistence = persistenceService;

  final VisualEmbeddingService _embedding;
  final EmbeddingPersistenceService? _persistence;
  final Map<String, List<Uint8List>> _index = {};
  bool _built = false;

  bool get isBuilt => _built;
  int get indexedProductCount => _index.length;
  int get indexedEmbeddingCount =>
      _index.values.fold(0, (sum, embeddings) => sum + embeddings.length);

  Future<void> buildIndex(
    List<ProductModel> products, {
    Map<String, List<String>> extraImagePaths = const {},
  }) async {
    _index.clear();
    _built = false;

    final cached = await _persistence?.loadAll(_embedding.modelVersion) ?? {};

    for (final product in products) {
      final paths = _pathsFor(product, extraImagePaths[product.id] ?? const []);
      final hashes = <Uint8List>[];

      // Precomputed catalog embeddings do not require a product imageUrl.
      final cachedForProduct = cached[product.id];
      if (cachedForProduct != null && cachedForProduct.isNotEmpty) {
        hashes.addAll(cachedForProduct.values);
      }

      for (final path in paths) {
        if (cachedForProduct?.containsKey(path) ?? false) continue;
        final computed = await _embedding.embedFile(path);
        if (computed != null) {
          hashes.add(computed);
          await _persistence?.save(
            productId: product.id,
            imagePath: path,
            embedding: computed,
            modelVersion: _embedding.modelVersion,
          );
        }
      }

      if (hashes.isNotEmpty) _index[product.id] = hashes;
    }

    _built = true;
  }

  Future<void> refreshProduct(
    ProductModel product, {
    List<String> extraPaths = const [],
  }) async {
    final paths = _pathsFor(product, extraPaths);
    final cached = await _persistence?.loadAll(_embedding.modelVersion);

    // A catalog-only product can be indexed entirely from its precomputed
    // embeddings; do not delete those rows just because imageUrl is empty.
    if (paths.isEmpty) {
      final existing = cached?[product.id];
      if (existing != null && existing.isNotEmpty) {
        _index[product.id] = existing.values.toList(growable: false);
        return;
      }
      _index.remove(product.id);
      return;
    }

    final hashes = <Uint8List>[];
    await _persistence?.deleteProduct(product.id);

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

  void removeProduct(String productId) {
    _index.remove(productId);
    _persistence?.deleteProduct(productId);
  }

  List<RecognitionCandidate> search(
    Uint8List queryEmbedding, {
    int topK = 3,
    double? minConfidence,
  }) {
    final threshold = minConfidence ?? _embedding.recommendedMinConfidence;
    return evaluate(
      queryEmbedding,
      topK: topK,
      minConfidence: threshold,
      minMargin: 0,
    ).candidates.where((c) => c.confidence >= threshold).toList();
  }

  RecognitionSearchResult evaluate(
    Uint8List queryEmbedding, {
    int topK = 3,
    double? minConfidence,
    double minMargin = 0.12,
    double? supportDelta,
    int minSupportingReferences = 1,
  }) {
    final threshold = minConfidence ?? _embedding.recommendedMinConfidence;
    final supportWindow = supportDelta ?? (1 - threshold) / 2;
    if (_index.isEmpty) {
      return RecognitionSearchResult(
        candidates: const [],
        minConfidence: threshold,
        minMargin: minMargin,
        minSupportingReferences: minSupportingReferences,
      );
    }

    final results = <RecognitionCandidate>[];
    for (final entry in _index.entries) {
      var bestSim = 0.0;
      var support = 0;
      for (final stored in entry.value) {
        final s = _embedding.similarity(queryEmbedding, stored);
        if (s > bestSim) bestSim = s;
      }
      final supportThreshold = (bestSim - supportWindow).clamp(0.0, 1.0);
      for (final stored in entry.value) {
        final s = _embedding.similarity(queryEmbedding, stored);
        if (s >= supportThreshold && s >= threshold) support++;
      }
      results.add(RecognitionCandidate(
        productId: entry.key,
        confidence: bestSim,
        hammingDistance: 0,
        referenceCount: entry.value.length,
        supportingReferenceCount: support,
      ));
    }

    results.sort((a, b) => b.confidence.compareTo(a.confidence));
    return RecognitionSearchResult(
      candidates: results.take(topK).toList(),
      minConfidence: threshold,
      minMargin: minMargin,
      minSupportingReferences: minSupportingReferences,
    );
  }

  static List<String> _pathsFor(ProductModel product, List<String> extras) {
    final paths = <String>[];
    final url = product.imageUrl;
    if (url != null && url.isNotEmpty) paths.add(url);
    paths.addAll(extras);
    return paths;
  }
}