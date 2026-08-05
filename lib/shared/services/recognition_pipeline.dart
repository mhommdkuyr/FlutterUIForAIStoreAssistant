import 'package:camera/camera.dart';

import '../models/product_model.dart';
import 'embedding_persistence_service.dart';
import 'local_product_index_service.dart';
import 'product_recognition_result.dart';
import 'scan_lock_manager.dart';
import 'visual_embedding_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Tuning knobs for [RecognitionPipeline].
class RecognitionConfig {
  const RecognitionConfig({
    this.frameSkip = 4,
    this.minConfidence,
    this.confirmationFrames = 3,
    this.absentTicksToUnlock = 10,
  });

  /// Process 1 out of every [frameSkip] frames from the camera stream.
  final int frameSkip;

  /// Minimum similarity score to consider a candidate.
  ///
  /// When `null` the pipeline uses [VisualEmbeddingService.recommendedMinConfidence],
  /// which adapts automatically to the active backend (TFLite vs aHash).
  final double? minConfidence;

  /// Consecutive processed frames the same product must appear in before
  /// it is declared [RecognitionStatus.confirmed].
  final int confirmationFrames;

  /// Frames without detection before a cart-lock is released.
  final int absentTicksToUnlock;
}

// ─────────────────────────────────────────────────────────────────────────────
// RecognitionPipeline
// ─────────────────────────────────────────────────────────────────────────────

/// Orchestrates the full per-frame visual recognition flow:
///
///   CameraImage
///     → [VisualEmbeddingProvider.embedFrame]    (TFLite or aHash)
///     → [LocalProductIndexService.search]        (cosine or Hamming distance)
///     → [_TemporalTracker.advance]               (N-frame confirmation)
///     → [ScanLockManager]                        (per-product deduplication)
///     → emit via [onConfirmed] / [onUncertain]
///
/// **Setup:**
/// ```dart
/// final pipeline = RecognitionPipeline();
/// await pipeline.initialize();          // loads TFLite model (once)
/// await pipeline.buildIndex(products);  // precomputes / loads embeddings
/// pipeline.onConfirmed = (r) => addToCart(r.productId!);
/// pipeline.onUncertain = (r) => showTrackingHint();
///
/// // Inside camera frame callback:
/// pipeline.processFrame(frame);
/// ```
class RecognitionPipeline {
  RecognitionPipeline({
    RecognitionConfig? config,
    VisualEmbeddingService? embeddingService,
    LocalProductIndexService? indexService,
    ScanLockManager? lockManager,
    EmbeddingPersistenceService? persistenceService,
  }) : _config = config ?? const RecognitionConfig() {
    // Use the provider (TFLite + aHash fallback) unless explicitly overridden.
    _embedding = embeddingService ?? VisualEmbeddingProvider();
    _persistence = persistenceService;
    _index = indexService ??
        LocalProductIndexService(
          embeddingService: _embedding,
          persistenceService: _persistence,
        );
    _locks =
        lockManager ?? ScanLockManager(unlockAfterTicks: _config.absentTicksToUnlock);
    _tracker =
        _TemporalTracker(requiredFrames: _config.confirmationFrames);
  }

  final RecognitionConfig _config;
  late final VisualEmbeddingService _embedding;
  late final EmbeddingPersistenceService? _persistence;
  late final LocalProductIndexService _index;
  late final ScanLockManager _locks;
  late final _TemporalTracker _tracker;

  int _frameCount = 0;
  bool _processing = false;
  bool _active = true;

  // ── Callbacks ──────────────────────────────────────────────────────────────

  void Function(ProductRecognitionResult result)? onConfirmed;
  void Function(ProductRecognitionResult result)? onUncertain;

  // ── Initialization ─────────────────────────────────────────────────────────

  /// Load the ML model (TFLite or aHash fallback).
  ///
  /// Must be called once before [buildIndex] or [processFrame].
  /// Safe to call multiple times (no-op after first successful init).
  Future<void> initialize() async {
    if (_embedding is VisualEmbeddingProvider) {
      await (_embedding as VisualEmbeddingProvider).initialize(); // ignore: unnecessary_cast
    }
  }

  bool get isTfLiteActive =>
      _embedding is VisualEmbeddingProvider &&
      (_embedding as VisualEmbeddingProvider).isTfLiteActive; // ignore: unnecessary_cast

  // ── Index management ───────────────────────────────────────────────────────

  Future<void> buildIndex(
    List<ProductModel> products, {
    Map<String, List<String>> extraImagePaths = const {},
  }) {
    final threshold = _config.minConfidence ?? _embedding.recommendedMinConfidence;
    // Pass the threshold along as context for later searches.
    _minConfidence = threshold;
    return _index.buildIndex(products, extraImagePaths: extraImagePaths);
  }

  double _minConfidence = 0.45;

  Future<void> refreshProduct(
    ProductModel product, {
    List<String> extraPaths = const [],
  }) =>
      _index.refreshProduct(product, extraPaths: extraPaths);

  void removeProduct(String productId) {
    _index.removeProduct(productId);
    _locks.removeProduct(productId);
  }

  bool get isIndexReady => _index.isBuilt;
  int get indexedProductCount => _index.indexedProductCount;

  // ── Session control ────────────────────────────────────────────────────────

  void pause() {
    _active = false;
    _tracker.reset();
  }

  void resume() {
    _active = true;
    _frameCount = 0;
    _processing = false;
    _tracker.reset();
  }

  void reset() {
    _locks.reset();
    _tracker.reset();
    _frameCount = 0;
    _processing = false;
  }

  // ── Frame processing ───────────────────────────────────────────────────────

  void processFrame(CameraImage image) {
    if (!_active || _processing) return;
    if (++_frameCount % _config.frameSkip != 0) return;
    _processing = true;
    try {
      _processSync(image);
    } finally {
      _processing = false;
    }
  }

  void _processSync(CameraImage image) {
    // 1. Compute embedding for this frame.
    final embedding = _embedding.embedFrame(image);

    // 2. Search the index.
    final candidates = embedding != null
        ? _index.search(embedding, minConfidence: _minConfidence)
        : <RecognitionCandidate>[];

    // 3. Advance lock-manager absent counters.
    final detectedIds = candidates.map((c) => c.productId).toSet();
    _locks.tick(detectedIds);

    // 4. Advance temporal tracker.
    final tracked = _tracker.advance(
      candidates.isNotEmpty ? candidates.first : null,
      minConfidence: _minConfidence,
    );
    if (tracked == null) return;

    // 5. Uncertain: show hint, do not add to cart.
    if (tracked.isUncertain) {
      onUncertain?.call(tracked);
      return;
    }

    // 6. Confirmed: per-product cart lock.
    if (tracked.isConfirmed) {
      final shouldAdd = _locks.onDetected(tracked.productId!);
      if (shouldAdd) onConfirmed?.call(tracked);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _TemporalTracker
// ─────────────────────────────────────────────────────────────────────────────

class _TemporalTracker {
  _TemporalTracker({this.requiredFrames = 3});

  final int requiredFrames;

  String? _currentId;
  int _streak = 0;

  ProductRecognitionResult? advance(
    RecognitionCandidate? best, {
    required double minConfidence,
  }) {
    if (best == null || best.confidence < minConfidence) {
      _currentId = null;
      _streak = 0;
      return null;
    }

    if (best.productId != _currentId) {
      _currentId = best.productId;
      _streak = 1;
      return ProductRecognitionResult.uncertain(
        productId: best.productId,
        confidence: best.confidence,
        source: best.source,
      );
    }

    _streak++;

    if (_streak < requiredFrames) {
      return ProductRecognitionResult.uncertain(
        productId: best.productId,
        confidence: best.confidence,
        source: best.source,
      );
    }

    return ProductRecognitionResult.confirmed(
      productId: best.productId,
      confidence: best.confidence,
      source: best.source,
    );
  }

  void reset() {
    _currentId = null;
    _streak = 0;
  }
}
