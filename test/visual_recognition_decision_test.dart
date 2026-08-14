import 'dart:typed_data';

import 'package:ai_store_assistant/shared/models/product_model.dart';
import 'package:ai_store_assistant/shared/services/local_product_index_service.dart';
import 'package:ai_store_assistant/shared/services/visual_embedding_service.dart';
import 'package:flutter_test/flutter_test.dart';

ProductModel _product(String id, {required String imageUrl}) => ProductModel(
      id: id,
      name: 'Product $id',
      category: 'Test',
      purchasePrice: 100,
      sellingPrice: 150,
      quantity: 10,
      imageUrl: imageUrl,
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

Uint8List _embedding(int value, {int size = 32}) =>
    Uint8List(size)..fillRange(0, size, value);

class _StubEmbeddingService implements VisualEmbeddingService {
  _StubEmbeddingService(this._embeddings);

  final Map<String, Uint8List> _embeddings;

  @override
  int get embeddingLength => 32;

  @override
  String get modelVersion => 'decision_test_stub_v1';

  @override
  double get recommendedMinConfidence => 0.70;

  @override
  Future<Uint8List?> embedFile(String path) async => _embeddings[path];

  @override
  Uint8List? embedFrame(camera) => null;

  @override
  double similarity(Uint8List a, Uint8List b) {
    if (a.length != b.length) return 0.0;

    var totalDifference = 0;
    for (var i = 0; i < a.length; i++) {
      totalDifference += (a[i] - b[i]).abs();
    }

    return 1.0 - (totalDifference / (a.length * 255));
  }
}

void main() {
  group('Visual recognition decision', () {
    test('best, second-best, margin and threshold are reported', () async {
      final bestEmbedding = _embedding(220);
      final secondBestEmbedding = _embedding(190);
      final queryEmbedding = _embedding(218);
      final stub = _StubEmbeddingService({
        'pathA': bestEmbedding,
        'pathB': secondBestEmbedding,
      });
      final index = LocalProductIndexService(embeddingService: stub);

      await index.buildIndex([
        _product('a', imageUrl: 'pathA'),
        _product('b', imageUrl: 'pathB'),
      ]);

      final candidates = index.search(queryEmbedding, minConfidence: 0.80);
      final best = candidates.first;
      final secondBest = candidates[1];
      final margin = best.confidence - secondBest.confidence;

      expect(candidates, hasLength(2));
      expect(best.productId, 'a');
      expect(secondBest.productId, 'b');
      expect(best.confidence, greaterThan(secondBest.confidence));
      expect(best.confidence, greaterThanOrEqualTo(0.80));
      expect(margin, greaterThan(0.08));
    });
  });
}
