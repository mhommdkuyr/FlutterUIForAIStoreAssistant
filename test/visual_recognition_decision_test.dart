import 'dart:typed_data';

import 'package:ai_store_assistant/shared/models/product_model.dart';
import 'package:ai_store_assistant/shared/services/local_product_index_service.dart';
import 'package:ai_store_assistant/shared/services/product_recognition_result.dart';
import 'package:ai_store_assistant/shared/services/recognition_pipeline.dart';
import 'package:ai_store_assistant/shared/services/visual_embedding_service.dart';
import 'package:flutter_test/flutter_test.dart';

ProductModel _product(String id, String imagePath) => ProductModel(
      id: id,
      name: 'Product $id',
      category: 'Test',
      purchasePrice: 1,
      sellingPrice: 2,
      quantity: 1,
      imageUrl: imagePath,
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

Uint8List _e(int a, [int b = 0, int c = 0]) => Uint8List.fromList([a, b, c]);

class _StubEmbeddingService implements VisualEmbeddingService {
  _StubEmbeddingService(this._files, {this.version = 'stub_v1'});

  final Map<String, Uint8List> _files;
  final String version;

  @override
  Future<Uint8List?> embedFile(String path) async => _files[path];

  @override
  Uint8List? embedFrame(image) => null;

  @override
  int get embeddingLength => 3;

  @override
  String get modelVersion => version;

  @override
  double get recommendedMinConfidence => 0.80;

  @override
  double similarity(Uint8List a, Uint8List b) {
    if (a.length != b.length) return 0;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff += (a[i] - b[i]).abs();
    }
    return (1 - diff / (255 * a.length)).clamp(0, 1).toDouble();
  }
}

RecognitionPipeline _pipeline(
  _StubEmbeddingService embedding, {
  double minMargin = 0.08,
  int confirmationFrames = 3,
}) {
  return RecognitionPipeline(
    embeddingService: embedding,
    config: RecognitionConfig(
      minConfidence: 0.80,
      minMargin: minMargin,
      confirmationFrames: confirmationFrames,
      minSupportingReferences: 1,
      frameSkip: 1,
    ),
  );
}

void main() {
  group('LocalProductIndexService decision safety', () {
    test('reference images produce independent product embeddings', () async {
      final embedding = _StubEmbeddingService({
        'a-front': _e(220, 10),
        'a-side': _e(218, 12),
      });
      final index = LocalProductIndexService(embeddingService: embedding);

      await index.buildIndex([
        _product('A', 'a-front'),
      ], extraImagePaths: {
        'A': ['a-side'],
      });

      final result = index.evaluate(_e(219, 11), minConfidence: 0.80);

      expect(index.indexedProductCount, 1);
      expect(index.indexedEmbeddingCount, 2);
      expect(result.best?.productId, 'A');
      expect(result.best?.referenceCount, 2);
    });

    test('best, second-best, margin and threshold are reported', () async {
      final embedding = _StubEmbeddingService({
        'a': _e(220),
        'b': _e(150),
        'c': _e(20),
      });
      final index = LocalProductIndexService(embeddingService: embedding);
      await index.buildIndex([
        _product('A', 'a'),
        _product('B', 'b'),
        _product('C', 'c'),
      ]);

      final result = index.evaluate(
        _e(218),
        minConfidence: 0.80,
        minMargin: 0.08,
      );

      expect(result.best?.productId, 'A');
      expect(result.secondBest?.productId, 'B');
      expect(result.bestScore, greaterThan(result.secondBestScore));
      expect(result.margin, greaterThan(0.08));
      expect(result.isAccepted, isTrue);
    });

    test('ambiguous best and second-best becomes NoMatch candidate state', () async {
      final embedding = _StubEmbeddingService({
        'a': _e(220),
        'b': _e(216),
      });
      final index = LocalProductIndexService(embeddingService: embedding);
      await index.buildIndex([_product('A', 'a'), _product('B', 'b')]);

      final result = index.evaluate(
        _e(218),
        minConfidence: 0.80,
        minMargin: 0.08,
      );

      expect(result.best?.productId, 'A');
      expect(result.secondBest?.productId, 'B');
      expect(result.isAccepted, isFalse);
      expect(result.rejectionReason, 'ambiguous_margin');
    });

    test('unknown product is NoMatch and does not return the last indexed product',
        () async {
      final embedding = _StubEmbeddingService({
        'a': _e(230, 0, 0),
        'b': _e(0, 230, 0),
        'c': _e(0, 0, 230),
      });
      final index = LocalProductIndexService(embeddingService: embedding);
      await index.buildIndex([
        _product('A', 'a'),
        _product('B', 'b'),
        _product('C', 'c'),
      ]);

      final result = index.evaluate(
        _e(80, 80, 80),
        minConfidence: 0.80,
        minMargin: 0.08,
      );

      expect(result.isAccepted, isFalse);
      expect(result.best?.productId, isNot('C'));
      expect(result.rejectionReason, 'low_confidence');
    });

    test('product ordering does not force the last product over Product A',
        () async {
      final embedding = _StubEmbeddingService({
        'a1': _e(230, 0, 0),
        'a2': _e(228, 2, 0),
        'b1': _e(0, 230, 0),
        'c1': _e(0, 0, 230),
      });
      final index = LocalProductIndexService(embeddingService: embedding);
      await index.buildIndex([
        _product('A', 'a1'),
        _product('B', 'b1'),
        _product('C', 'c1'),
      ], extraImagePaths: {
        'A': ['a2'],
      });

      expect(index.evaluate(_e(229, 1, 0), minConfidence: 0.80).best?.productId,
          'A');
      index.removeProduct('C');
      expect(index.evaluate(_e(229, 1, 0), minConfidence: 0.80).best?.productId,
          'A');
      await index.refreshProduct(_product('C', 'c1'));
      expect(index.evaluate(_e(229, 1, 0), minConfidence: 0.80).best?.productId,
          'A');
    });

    test('refreshProduct updates changed image and adds new reference', () async {
      final embedding = _StubEmbeddingService({
        'old': _e(10),
        'new': _e(220),
        'new-side': _e(218),
      });
      final index = LocalProductIndexService(embeddingService: embedding);
      await index.buildIndex([_product('A', 'old')]);
      await index.refreshProduct(_product('A', 'new'), extraPaths: ['new-side']);

      final newResult = index.evaluate(_e(219), minConfidence: 0.80);
      final oldResult = index.evaluate(_e(10), minConfidence: 0.95);

      expect(newResult.best?.productId, 'A');
      expect(newResult.best?.referenceCount, 2);
      expect(oldResult.isAccepted, isFalse);
    });

    test('different modelVersion can rebuild a clean index', () async {
      final v1 = _StubEmbeddingService({'a': _e(220)}, version: 'v1');
      final v2 = _StubEmbeddingService({'a': _e(40)}, version: 'v2');
      final indexV1 = LocalProductIndexService(embeddingService: v1);
      final indexV2 = LocalProductIndexService(embeddingService: v2);

      await indexV1.buildIndex([_product('A', 'a')]);
      await indexV2.buildIndex([_product('A', 'a')]);

      expect(indexV1.evaluate(_e(220), minConfidence: 0.95).isAccepted, isTrue);
      expect(indexV2.evaluate(_e(40), minConfidence: 0.95).isAccepted, isTrue);
      expect(v1.modelVersion, isNot(v2.modelVersion));
    });
  });

  group('RecognitionPipeline temporal confirmation and cart safety', () {
    test('repeated correct result confirms after configured frame count',
        () async {
      final embedding = _StubEmbeddingService({'a': _e(220), 'b': _e(20)});
      final pipeline = _pipeline(embedding, confirmationFrames: 3);
      await pipeline.initialize();
      await pipeline.buildIndex([_product('A', 'a'), _product('B', 'b')]);

      final r1 = pipeline.evaluateEmbedding(_e(220)).result;
      final r2 = pipeline.evaluateEmbedding(_e(220)).result;
      final r3 = pipeline.evaluateEmbedding(_e(220)).result;

      expect(r1.status, RecognitionStatus.uncertain);
      expect(r2.status, RecognitionStatus.uncertain);
      expect(r3.status, RecognitionStatus.confirmed);
      expect(r3.productId, 'A');
    });

    test('temporal conflict A-B-A does not confirm incorrectly', () async {
      final embedding = _StubEmbeddingService({'a': _e(220), 'b': _e(20)});
      final pipeline = _pipeline(embedding, confirmationFrames: 3);
      await pipeline.initialize();
      await pipeline.buildIndex([_product('A', 'a'), _product('B', 'b')]);

      final r1 = pipeline.evaluateEmbedding(_e(220)).result;
      final r2 = pipeline.evaluateEmbedding(_e(20)).result;
      final r3 = pipeline.evaluateEmbedding(_e(220)).result;

      expect(r1.status, RecognitionStatus.uncertain);
      expect(r2.status, RecognitionStatus.uncertain);
      expect(r3.status, RecognitionStatus.uncertain);
    });

    test('last product scenario: A, unknown, B returns A, NoMatch, B', () async {
      final embedding = _StubEmbeddingService({
        'a': _e(230, 0, 0),
        'b': _e(0, 230, 0),
        'c': _e(0, 0, 230),
      });
      final pipeline = _pipeline(embedding, confirmationFrames: 1);
      await pipeline.initialize();
      await pipeline.buildIndex([
        _product('A', 'a'),
        _product('B', 'b'),
        _product('C', 'c'),
      ]);

      final a = pipeline.evaluateEmbedding(_e(230, 0, 0)).result;
      final unknown = pipeline.evaluateEmbedding(_e(80, 80, 80)).result;
      final b = pipeline.evaluateEmbedding(_e(0, 230, 0)).result;

      expect(a.productId, 'A');
      expect(a.status, RecognitionStatus.confirmed);
      expect(unknown.status, RecognitionStatus.noMatch);
      expect(unknown.productId, isNull);
      expect(b.productId, 'B');
      expect(b.status, RecognitionStatus.confirmed);
    });

    test('low confidence and uncertain results are not sent to cart callback',
        () async {
      final embedding = _StubEmbeddingService({'a': _e(220), 'b': _e(20)});
      final pipeline = _pipeline(embedding, confirmationFrames: 2);
      var addCount = 0;
      pipeline.onConfirmed = (_) => addCount++;
      await pipeline.initialize();
      await pipeline.buildIndex([_product('A', 'a'), _product('B', 'b')]);

      pipeline.evaluateEmbedding(_e(80)).result;
      pipeline.evaluateEmbedding(_e(220)).result;

      expect(addCount, 0);
    });

    test('confirmed product callback is locked against continuous duplicates',
        () async {
      final embedding = _StubEmbeddingService({'a': _e(220)});
      final pipeline = _pipeline(embedding, confirmationFrames: 1);
      var addCount = 0;
      pipeline.onConfirmed = (_) => addCount++;
      await pipeline.initialize();
      await pipeline.buildIndex([_product('A', 'a')]);

      for (var i = 0; i < 5; i++) {
        pipeline.evaluateEmbedding(_e(220));
      }

      expect(addCount, 1);
    });
  });
}
