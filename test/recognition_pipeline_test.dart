import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_store_assistant/shared/services/local_product_index_service.dart';
import 'package:ai_store_assistant/shared/services/product_recognition_result.dart';
import 'package:ai_store_assistant/shared/services/visual_embedding_service.dart';
import 'package:ai_store_assistant/shared/models/product_model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

ProductModel _makeProduct(String id, {String? imageUrl}) => ProductModel(
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

/// Stub embedding service — returns predictable hashes without file I/O.
class _StubEmbedding implements VisualEmbeddingService {
  /// productId → hash bytes. Registered hashes are returned by [embedFile].
  final Map<String, Uint8List> _hashes;

  _StubEmbedding(this._hashes);

  @override
  int get embeddingLength => 32;

  @override
  String get modelVersion => 'test_stub_v1';

  @override
  double get recommendedMinConfidence => 0.70;

  @override
  Future<Uint8List?> embedFile(String path) async {
    // The path IS the productId in the stub.
    return _hashes[path];
  }

  @override
  Future<Uint8List?> embedFrame(camera) async => null;

  @override
  double similarity(Uint8List a, Uint8List b) {
    final dist = _hammingDist(a, b);
    return 1.0 - (dist / 256.0);
  }

  static int _hammingDist(Uint8List a, Uint8List b) {
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      var x = a[i] ^ b[i];
      while (x != 0) {
        d += x & 1;
        x >>= 1;
      }
    }
    return d;
  }
}

/// Returns a 32-byte hash where the first [setBits] bits are 1, rest 0.
Uint8List _makeHash(int setBits) {
  final h = Uint8List(32);
  for (var i = 0; i < setBits; i++) {
    h[i >> 3] |= 1 << (i & 7);
  }
  return h;
}

// ─────────────────────────────────────────────────────────────────────────────
// LocalProductIndexService tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('LocalProductIndexService', () {
    test('isBuilt is false before buildIndex', () {
      final svc = LocalProductIndexService();
      expect(svc.isBuilt, isFalse);
    });

    test('isBuilt is true after buildIndex completes', () async {
      final svc = LocalProductIndexService(embeddingService: _StubEmbedding({}));
      await svc.buildIndex([]);
      expect(svc.isBuilt, isTrue);
    });

    test('indexedProductCount reflects enrolled products', () async {
      final hashA = _makeHash(10);
      final stub = _StubEmbedding({'pathA': hashA});
      final svc = LocalProductIndexService(embeddingService: stub);

      final product = _makeProduct('a', imageUrl: 'pathA');
      await svc.buildIndex([product]);

      expect(svc.indexedProductCount, 1);
    });

    test('search returns best candidate for exact hash', () async {
      final hashA = _makeHash(10);
      final hashB = _makeHash(128); // very different
      final stub = _StubEmbedding({'pathA': hashA, 'pathB': hashB});
      final svc = LocalProductIndexService(embeddingService: stub);

      await svc.buildIndex([
        _makeProduct('a', imageUrl: 'pathA'),
        _makeProduct('b', imageUrl: 'pathB'),
      ]);

      final results = svc.search(hashA);
      expect(results, isNotEmpty);
      expect(results.first.productId, 'a');
      expect(results.first.confidence, greaterThan(0.95));
    });

    test('search returns empty when confidence is below threshold', () async {
      final hashA = _makeHash(10);
      final queryHash = _makeHash(200); // very different
      final stub = _StubEmbedding({'pathA': hashA});
      final svc = LocalProductIndexService(embeddingService: stub);
      await svc.buildIndex([_makeProduct('a', imageUrl: 'pathA')]);

      final results = svc.search(queryHash, minConfidence: 0.70);
      expect(results, isEmpty);
    });

    test('multiple reference images per product all participate in search',
        () async {
      final hashRef1 = _makeHash(10);
      final hashRef2 = _makeHash(50); // second angle
      final stub = _StubEmbedding({'ref1': hashRef1, 'ref2': hashRef2});
      final svc = LocalProductIndexService(embeddingService: stub);

      final product = _makeProduct('a', imageUrl: 'ref1');
      await svc.buildIndex([product], extraImagePaths: {
        'a': ['ref2']
      });

      // A query close to ref2 should still match product 'a'
      final closeToRef2 = Uint8List(32);
      closeToRef2.setAll(0, hashRef2);
      closeToRef2[0] ^= 0x01; // flip 1 bit — still very similar

      final results = svc.search(closeToRef2, minConfidence: 0.90);
      expect(results, isNotEmpty);
      expect(results.first.productId, 'a');
    });

    test('removeProduct removes it from subsequent searches', () async {
      final hash = _makeHash(10);
      final stub = _StubEmbedding({'path': hash});
      final svc = LocalProductIndexService(embeddingService: stub);
      await svc.buildIndex([_makeProduct('a', imageUrl: 'path')]);

      svc.removeProduct('a');
      final results = svc.search(hash);
      expect(results, isEmpty);
    });
  });

  // ── RecognitionCandidate & ProductRecognitionResult ─────────────────────────

  group('ProductRecognitionResult', () {
    test('confirmed factory sets correct fields', () {
      final r = ProductRecognitionResult.confirmed(
        productId: 'p1',
        confidence: 0.95,
      );
      expect(r.isConfirmed, isTrue);
      expect(r.productId, 'p1');
      expect(r.confidence, closeTo(0.95, 0.001));
    });

    test('uncertain factory sets correct fields', () {
      final r = ProductRecognitionResult.uncertain(
        productId: 'p1',
        confidence: 0.80,
      );
      expect(r.isUncertain, isTrue);
      expect(r.isConfirmed, isFalse);
    });

    test('rejected factory sets correct fields', () {
      final r = ProductRecognitionResult.rejected(reason: 'low confidence');
      expect(r.isRejected, isTrue);
      expect(r.productId, isNull);
      expect(r.reason, 'low confidence');
    });
  });

  // ── RecognitionCandidate ───────────────────────────────────────────────────

  group('RecognitionCandidate', () {
    test('toString includes productId and confidence', () {
      const c = RecognitionCandidate(
        productId: 'abc',
        confidence: 0.88,
        hammingDistance: 30,
      );
      expect(c.toString(), contains('abc'));
      expect(c.toString(), contains('0.88'));
    });
  });

  // ── AHashEmbeddingService ──────────────────────────────────────────────────

  group('AHashEmbeddingService', () {
    test('embedFile returns null for missing file', () async {
      final svc = AHashEmbeddingService();
      final result = await svc.embedFile('/nonexistent/file.jpg');
      expect(result, isNull);
    });

    test('embeddingLength is 32 bytes (256-bit)', () {
      expect(AHashEmbeddingService().embeddingLength, 32);
    });

    test('similarity of identical hashes is 1.0', () {
      final svc = AHashEmbeddingService();
      final h = Uint8List(32)..fillRange(0, 32, 0xAB);
      expect(svc.similarity(h, h), closeTo(1.0, 0.001));
    });

    test('similarity of inverted hashes is 0.0', () {
      final svc = AHashEmbeddingService();
      final h1 = Uint8List(32)..fillRange(0, 32, 0xFF);
      final h2 = Uint8List(32)..fillRange(0, 32, 0x00);
      expect(svc.similarity(h1, h2), closeTo(0.0, 0.001));
    });
  });
}
