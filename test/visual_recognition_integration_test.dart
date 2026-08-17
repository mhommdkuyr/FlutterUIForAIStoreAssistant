/// Integration-style tests for the visual recognition stack.
///
/// These tests run on the host machine. They verify that production recognition
/// fails closed when the MobileCLIP2-S0 runtime asset is absent instead of
/// silently falling back to aHash. Tests are designed around:
///   1. VisualEmbeddingProvider fail-closed behavior.
///   2. LocalProductIndexService using the correct similarity dispatch.
///   3. RecognitionPipeline architecture (temporal tracker, scan lock).
///   4. Deterministic embedding round-trips (same image → same embedding).
///   5. Boundary and false-positive guards.
///
/// On a real Android device, MobileVisionEmbeddingService must load the bundled
/// MobileCLIP2-S0 image encoder; aHash remains tests/diagnostics only.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_store_assistant/shared/models/product_model.dart';
import 'package:ai_store_assistant/shared/services/embedding_persistence_service.dart';
import 'package:ai_store_assistant/shared/services/local_product_index_service.dart';
import 'package:ai_store_assistant/shared/services/product_recognition_result.dart';
import 'package:ai_store_assistant/shared/services/scan_lock_manager.dart';
import 'package:ai_store_assistant/shared/services/visual_embedding_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

ProductModel _product(String id, {String? imageUrl}) => ProductModel(
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

/// Deterministic stub embedding: fills [size] bytes with [seed] XOR pattern.
Uint8List _makeEmbedding(int seed, {int size = 32}) {
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = (seed ^ i) & 0xFF;
  }
  return bytes;
}

/// Stub embedding service: paths act as keys mapping to pre-registered hashes.
class _StubEmbeddingService implements VisualEmbeddingService {
  _StubEmbeddingService(this._map);
  final Map<String, Uint8List> _map;

  @override
  String get modelVersion => 'stub_v1';
  @override
  double get recommendedMinConfidence => 0.70;
  @override
  int get embeddingLength => 32;

  @override
  Future<Uint8List?> embedFile(String path) async => _map[path];

  @override
  Uint8List? embedFrame(camera) => null;

  @override
  double similarity(Uint8List a, Uint8List b) {
    if (a.length != b.length) return 0.0;
    var same = 0;
    for (var i = 0; i < a.length; i++) {
      final xor = a[i] ^ b[i];
      // Count matching bits via popcount complement
      var bits = xor;
      var diff = 0;
      while (bits != 0) {
        diff += bits & 1;
        bits >>= 1;
      }
      same += 8 - diff;
    }
    return same / (a.length * 8);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. AHashEmbeddingService — deterministic output + similarity contract
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('AHashEmbeddingService — embedding properties', () {
    final svc = AHashEmbeddingService();

    test('embeddingLength is 32 bytes (256 bits)', () {
      expect(svc.embeddingLength, 32);
    });

    test('modelVersion is non-empty', () {
      expect(svc.modelVersion, isNotEmpty);
    });

    test('recommendedMinConfidence is in (0, 1)', () {
      expect(svc.recommendedMinConfidence, greaterThan(0));
      expect(svc.recommendedMinConfidence, lessThan(1));
    });

    test('similarity(x, x) == 1.0 for any hash', () {
      final h = Uint8List(32)..fillRange(0, 32, 0xAB);
      expect(svc.similarity(h, h), closeTo(1.0, 0.001));
    });

    test('similarity of inverted hash is 0.0', () {
      final h1 = Uint8List(32)..fillRange(0, 32, 0xFF);
      final h2 = Uint8List(32)..fillRange(0, 32, 0x00);
      expect(svc.similarity(h1, h2), closeTo(0.0, 0.001));
    });

    test('similarity is in [0, 1] for arbitrary hashes', () {
      final a = _makeEmbedding(42);
      final b = _makeEmbedding(99);
      final s = svc.similarity(a, b);
      expect(s, greaterThanOrEqualTo(0.0));
      expect(s, lessThanOrEqualTo(1.0));
    });

    test('embedFile returns null for missing file', () async {
      final result = await svc.embedFile('/nonexistent/path.jpg');
      expect(result, isNull);
    });
  });

  // ── 2. VisualEmbeddingProvider — fail closed ──────────────────────────────

  group('VisualEmbeddingProvider — no silent aHash fallback', () {
    test('initialize fails closed when MobileCLIP2 asset is absent on host', () async {
      final provider = VisualEmbeddingProvider();
      await expectLater(provider.initialize(), throwsA(isA<Object>()));
      expect(provider.isTfLiteActive, isFalse);
    });

    test('model metadata is MobileCLIP2-S0 before initialization', () {
      final provider = VisualEmbeddingProvider();
      expect(provider.modelVersion, contains('mobileclip2_s0'));
      expect(provider.embeddingLength, 512 * 4);
    });
  });

  // ── 3. LocalProductIndexService — similarity dispatch fix ─────────────────

  group('LocalProductIndexService — uses embedding.similarity() not hardcoded Hamming',
      () {
    test('search dispatches through embedding service similarity', () async {
      final hashA = _makeEmbedding(10);
      final stub = _StubEmbeddingService({'pathA': hashA});
      final index = LocalProductIndexService(embeddingService: stub);

      await index.buildIndex([_product('a', imageUrl: 'pathA')]);
      final results = index.search(hashA, minConfidence: 0.90);

      expect(results, isNotEmpty);
      expect(results.first.productId, 'a');
      expect(results.first.confidence, greaterThan(0.90));
    });

    test('unrelated embedding returns no match above threshold', () async {
      final hashA = _makeEmbedding(10);
      final hashUnrelated = _makeEmbedding(255); // very different
      final stub = _StubEmbeddingService({'pathA': hashA});
      final index = LocalProductIndexService(embeddingService: stub);

      await index.buildIndex([_product('a', imageUrl: 'pathA')]);
      final results = index.search(hashUnrelated, minConfidence: 0.90);

      expect(results, isEmpty);
    });

    test('product with no imageUrl is excluded from index', () async {
      final stub = _StubEmbeddingService({});
      final index = LocalProductIndexService(embeddingService: stub);

      await index.buildIndex([_product('no-image')]); // imageUrl == null

      expect(index.indexedProductCount, 0);
    });

    test('multiple reference images all participate in search', () async {
      final hashRef1 = _makeEmbedding(10);
      final hashRef2 = _makeEmbedding(20);
      final stub = _StubEmbeddingService({
        'ref1': hashRef1,
        'ref2': hashRef2,
      });
      final index = LocalProductIndexService(embeddingService: stub);

      await index.buildIndex(
        [_product('a', imageUrl: 'ref1')],
        extraImagePaths: {
          'a': ['ref2']
        },
      );

      // Query close to ref2
      final closeToRef2 = Uint8List.fromList(hashRef2);
      closeToRef2[0] ^= 0x01; // flip 1 bit

      final results = index.search(closeToRef2, minConfidence: 0.85);
      expect(results, isNotEmpty);
      expect(results.first.productId, 'a');
    });

    test('removeProduct removes it from subsequent searches', () async {
      final hash = _makeEmbedding(42);
      final stub = _StubEmbeddingService({'path': hash});
      final index = LocalProductIndexService(embeddingService: stub);

      await index.buildIndex([_product('a', imageUrl: 'path')]);
      index.removeProduct('a');

      expect(index.search(hash), isEmpty);
    });

    test('refreshProduct updates the index entry', () async {
      final hash1 = _makeEmbedding(10);
      final hash2 = _makeEmbedding(99); // new image
      final stub = _StubEmbeddingService({'img1': hash1, 'img2': hash2});
      final index = LocalProductIndexService(embeddingService: stub);

      await index.buildIndex([_product('a', imageUrl: 'img1')]);
      await index.refreshProduct(_product('a', imageUrl: 'img2'));

      // New hash should match, old one no longer stored (imageUrl changed)
      final r = index.search(hash2, minConfidence: 0.90);
      expect(r, isNotEmpty);
      expect(r.first.productId, 'a');
    });

    test('index update after product enrollment', () async {
      final hashA = _makeEmbedding(10);
      final hashB = _makeEmbedding(200);
      final stub = _StubEmbeddingService({
        'pathA': hashA,
        'pathB': hashB,
      });
      final index = LocalProductIndexService(embeddingService: stub);

      // Start with only product A
      await index.buildIndex([_product('a', imageUrl: 'pathA')]);
      expect(index.indexedProductCount, 1);

      // Enroll product B mid-session
      await index.refreshProduct(_product('b', imageUrl: 'pathB'));
      expect(index.indexedProductCount, 2);

      final results = index.search(hashB, minConfidence: 0.90);
      expect(results.first.productId, 'b');
    });
  });

  // ── 4. Temporal confirmation ───────────────────────────────────────────────

  group('RecognitionCandidate + ProductRecognitionResult', () {
    test('confirmed status is correctly set', () {
      final r = ProductRecognitionResult.confirmed(
          productId: 'p1', confidence: 0.9);
      expect(r.isConfirmed, isTrue);
      expect(r.productId, 'p1');
      expect(r.confidence, closeTo(0.9, 0.001));
    });

    test('uncertain status is correctly set', () {
      final r = ProductRecognitionResult.uncertain(
          productId: 'p1', confidence: 0.8);
      expect(r.isUncertain, isTrue);
      expect(r.isConfirmed, isFalse);
    });

    test('rejected status is correctly set', () {
      final r = ProductRecognitionResult.rejected(reason: 'low confidence');
      expect(r.isRejected, isTrue);
      expect(r.productId, isNull);
    });
  });

  // ── 5. ScanLockManager — duplicate prevention ─────────────────────────────

  group('ScanLockManager — duplicate prevention and re-entry', () {
    test('first detection returns true (add to cart)', () {
      final mgr = ScanLockManager();
      expect(mgr.onDetected('p1'), isTrue);
    });

    test('second detection while locked returns false (suppress)', () {
      final mgr = ScanLockManager();
      mgr.onDetected('p1');
      expect(mgr.onDetected('p1'), isFalse);
    });

    test('product unlocks after enough absent ticks', () {
      final mgr = ScanLockManager(unlockAfterTicks: 3);
      mgr.onDetected('p1');
      for (var i = 0; i < 3; i++) {
        mgr.tick({});
      }
      expect(mgr.isLocked('p1'), isFalse);
    });

    test('product re-enters and is added again after unlock', () {
      final mgr = ScanLockManager(unlockAfterTicks: 2);
      mgr.onDetected('p1');
      mgr.tick({});
      mgr.tick({}); // unlocked
      expect(mgr.onDetected('p1'), isTrue);
    });

    test('different products can be scanned sequentially without interference',
        () {
      final mgr = ScanLockManager();
      expect(mgr.onDetected('p1'), isTrue);
      expect(mgr.onDetected('p2'), isTrue); // independent lock
      expect(mgr.onDetected('p1'), isFalse); // p1 still locked
    });

    test('scanner continues safely when no match exists (no lock set)', () {
      final mgr = ScanLockManager();
      // Tick with empty set — no crash, no state change
      mgr.tick({});
      expect(mgr.lockCount, 0);
    });
  });

  // ── 6. EmbeddingPersistenceService — no DB, test interface contract ────────

  group('EmbeddingPersistenceService — interface contract', () {
    // We test the service's public contract via the index service;
    // actual DB tests require an in-memory database setup.

    test('LocalProductIndexService accepts null persistence (no crash)', () async {
      final stub = _StubEmbeddingService({'p': _makeEmbedding(1)});
      final index = LocalProductIndexService(
        embeddingService: stub,
        persistenceService: null, // no persistence
      );
      await index.buildIndex([_product('a', imageUrl: 'p')]);
      expect(index.indexedProductCount, 1);
    });
  });
}
