import 'dart:typed_data';

import '../models/product_model.dart';
import 'embedding_persistence_service.dart';
import 'product_recognition_result.dart';
import 'visual_embedding_service.dart';

/// In-memory product recognition index.
///
/// All reference images are embedded once when the scan session starts. After
/// that, search is pure in-memory cosine similarity with no disk I/O per frame.
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

    final expectedLength = _embedding.embeddingLength;
    if (expectedLength <= 0) {
      throw StateError(
        'Cannot build visual index while the embedding backend is unavailable.',
      );
    }

    final cached = await _persistence?.loadAll(_embedding.modelVersion) ?? {};

    for (final product in products) {
      final paths = _pathsFor(
        product,
        extraImagePaths[product.id] ?? const [],
      ).toSet().toList(growable: false);
      final embeddings = <Uint8List>[];

      for (final path in paths) {
        final fromCache = cached[product.id]?[path];
        if (fromCache != null && fromCache.length == expectedLength) {
          embeddings.add(fromCache);
          continue;
        }

        final computed = await _embedding.embedFile(path);
        if (computed == null || computed.length != expectedLength) continue;

        embeddings.add(computed);
        await _persistence?.save(
          productId: product.id,
          imagePath: path,
          embedding: computed,
          modelVersion: _embedding.modelVersion,
        );
      }

      if (embeddings.isNotEmpty) {
        _index[product.id] = embeddings;
      }
    }

    _built = true;
  }

  Future<void> refreshProduct(
    ProductModel product, {
    List<String> extraPaths = const [],
  }) async {
    final expectedLength = _embedding.embeddingLength;
    if (expectedLength <= 0) {
      throw StateError(
        'Cannot refresh visual index while the embedding backend is unavailable.',
      );
    }

    final paths =
        _pathsFor(product, extraPaths).toSet().toList(growable: false);
    final embeddings = <Uint8List>[];

    await _persistence?.deleteProduct(product.id);
    for (final path in paths) {
      final computed = await _embedding.embedFile(path);
      if (computed == null || computed.length != expectedLength) continue;
      embeddings.add(computed);
      await _persistence?.save(
        productId: product.id,
        imagePath: path,
        embedding: computed,
        modelVersion: _embedding.modelVersion,
      );
    }

    if (embeddings.isEmpty) {
      _index.remove(product.id);
    } else {
      _index[product.id] = embeddings;
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
    if (_index.isEmpty || queryEmbedding.length != _embedding.embeddingLength) {
      return RecognitionSearchResult(
        candidates: const [],
        minConfidence: threshold,
        minMargin: minMargin,
        minSupportingReferences: minSupportingReferences,
      );
    }

    final results = <RecognitionCandidate>[];
    for (final entry in _index.entries) {
      final similarities = <double>[];
      var bestSim = 0.0;
      for (final stored in entry.value) {
        final similarity = _embedding.similarity(queryEmbedding, stored);
        similarities.add(similarity);
        if (similarity > bestSim) bestSim = similarity;
      }

      final supportThreshold = (bestSim - supportWindow).clamp(0.0, 1.0);
      final support = similarities
          .where((similarity) =>
              similarity >= supportThreshold && similarity >= threshold)
          .length;

      results.add(
        RecognitionCandidate(
          productId: entry.key,
          confidence: bestSim,
          hammingDistance: 0,
          referenceCount: entry.value.length,
          supportingReferenceCount: support,
        ),
      );
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
    final primary = product.imageUrl;
    if (primary != null && primary.isNotEmpty) paths.add(primary);
    paths.addAll(extras);
    return paths;
  }
}
