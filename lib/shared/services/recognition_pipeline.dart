import 'dart:typed_data';

import 'package:camera/camera.dart';

import '../models/product_model.dart';
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
    this.minConfidence = 0.765,
    this.confirmationFrames = 3,
    this.absentTicksToUnlock = 10,
  });

  /// Process 1 out of every [frameSkip] frames from the camera stream.
  ///
  /// At 30 fps with frameSkip=4 → ~7.5 recognised frames/sec.
  final int frameSkip;

  /// Minimum similarity score (0.0–1.0) to consider a candidate at all.
  ///
  /// Default 0.765 ≈ Hamming ≤ 60/256 bits different (≈ 76 % similarity).
  final double minConfidence;

  /// How many consecutive processed frames the same product must appear in
  /// before it is declared [RecognitionStatus.confirmed].
  ///
  /// Prevents single-frame false-positives.
  final int confirmationFrames;

  /// Ticks without detection before a cart-lock is released, allowing the
  /// same product to be scanned again after re-entering the frame.
  final int absentTicksToUnlock;
}

// ─────────────────────────────────────────────────────────────────────────────
// RecognitionPipeline
// ─────────────────────────────────────────────────────────────────────────────

/// Orchestrates the full per-frame visual recognition flow:
///
///   CameraImage
///     → [VisualEmbeddingService.embedFrame]   (compute aHash)
///     → [LocalProductIndexService.search]      (top-K candidates)
///     → [_TemporalTracker.advance]             (N-frame confirmation)
///     → [ScanLockManager]                      (cart deduplication)
///     → emit via [onConfirmed] / [onUncertain]
///
/// **Setup:**
/// ```dart
/// final pipeline = RecognitionPipeline();
/// await pipeline.buildIndex(products);
/// pipeline.onConfirmed = (r) => addToCart(r.productId!);
/// pipeline.onUncertain = (r) => showTrackingHint(r.productId!);
///
/// // Inside camera frame callback:
/// pipeline.processFrame(frame);
/// ```
///
/// **Thread-safety note:** [processFrame] is safe to call from the camera
/// background isolate. It uses a simple boolean guard to skip re-entrant calls;
/// callbacks are invoked synchronously on the same thread, so the Flutter
/// binding `addPostFrameCallback` should be used in the callback when touching
/// widget state.
class RecognitionPipeline {
  RecognitionPipeline({
    RecognitionConfig? config,
    VisualEmbeddingService? embeddingService,
    LocalProductIndexService? indexService,
    ScanLockManager? lockManager,
  }) : _config = config ?? const RecognitionConfig() {
    _embedding = embeddingService ?? AHashEmbeddingService();
    _index = indexService ??
        LocalProductIndexService(embeddingService: _embedding);
    _locks = lockManager ??
        ScanLockManager(
            unlockAfterTicks: _config.absentTicksToUnlock);
    _tracker = _TemporalTracker(
        requiredFrames: _config.confirmationFrames);
  }

  final RecognitionConfig _config;
  late final VisualEmbeddingService _embedding;
  late final LocalProductIndexService _index;
  late final ScanLockManager _locks;
  late final _TemporalTracker _tracker;

  int _frameCount = 0;
  bool _processing = false;
  bool _active = true;

  // ── Callbacks ──────────────────────────────────────────────────────────────

  /// Fired when a product is temporally confirmed AND the lock allows adding.
  ///
  /// This is the primary output — wire it to your cart logic.
  void Function(ProductRecognitionResult result)? onConfirmed;

  /// Fired every frame while a product is being tracked but not yet confirmed.
  ///
  /// Use this to show a "locking on…" UI hint. Do NOT add to cart here.
  void Function(ProductRecognitionResult result)? onUncertain;

  // ── Index management ───────────────────────────────────────────────────────

  /// Build the recognition index (call once at session start).
  Future<void> buildIndex(
    List<ProductModel> products, {
    Map<String, List<String>> extraImagePaths = const {},
  }) =>
      _index.buildIndex(products, extraImagePaths: extraImagePaths);

  /// Refresh a single product after it is created or updated.
  ///
  /// Call this immediately after saving so the live scanner recognises the
  /// new product without a full session restart.
  Future<void> refreshProduct(
    ProductModel product, {
    List<String> extraPaths = const [],
  }) =>
      _index.refreshProduct(product, extraPaths: extraPaths);

  /// Remove a product from the index after deletion.
  void removeProduct(String productId) {
    _index.removeProduct(productId);
    _locks.removeProduct(productId);
  }

  bool get isIndexReady => _index.isBuilt;
  int get indexedProductCount => _index.indexedProductCount;

  // ── Session control ────────────────────────────────────────────────────────

  /// Pause frame processing (e.g. when switching to invoice mode).
  void pause() {
    _active = false;
    _tracker.reset();
  }

  /// Resume frame processing (e.g. when returning to scan mode).
  void resume() {
    _active = true;
    _frameCount = 0;
    _processing = false;
    _tracker.reset();
  }

  /// Reset all lock and tracking state (full session restart).
  void reset() {
    _locks.reset();
    _tracker.reset();
    _frameCount = 0;
    _processing = false;
  }

  // ── Frame processing ───────────────────────────────────────────────────────

  /// Entry point — call for every arriving camera frame.
  ///
  /// Internally applies [RecognitionConfig.frameSkip] and a reentrancy guard,
  /// so it is safe (and expected) to call this for every single frame.
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

  // ── Internal ────────────────────────────────────────────────────────────────

  void _processSync(CameraImage image) {
    // 1. Compute embedding for this frame.
    final Uint8List? hash = _embedding.embedFrame(image);

    // 2. Search the index for top candidates.
    final candidates = hash != null
        ? _index.search(hash, minConfidence: _config.minConfidence)
        : <RecognitionCandidate>[];

    // 3. Advance the lock manager: reset absent counters for detected products;
    //    auto-unlock products that have been absent long enough.
    final detectedIds = candidates.map((c) => c.productId).toSet();
    _locks.tick(detectedIds);

    // 4. Advance temporal tracker to get a stable result.
    final tracked = _tracker.advance(
      candidates.isNotEmpty ? candidates.first : null,
      minConfidence: _config.minConfidence,
    );

    if (tracked == null) return;

    // 5. Uncertain: emit hint, do NOT add to cart.
    if (tracked.isUncertain) {
      onUncertain?.call(tracked);
      return;
    }

    // 6. Confirmed: check per-product cart lock.
    if (tracked.isConfirmed) {
      final shouldAdd = _locks.onDetected(tracked.productId!);
      if (shouldAdd) {
        onConfirmed?.call(tracked);
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _TemporalTracker  —  N-frame confirmation window
// ─────────────────────────────────────────────────────────────────────────────

/// Requires the same product to be the top candidate for [requiredFrames]
/// consecutive processed frames before returning a [confirmed] result.
///
/// This is the primary guard against single-frame false-positives.
/// Once a product is confirmed, the streak counter is NOT reset — the
/// [ScanLockManager] handles cart-level deduplication from that point.
class _TemporalTracker {
  _TemporalTracker({this.requiredFrames = 3});

  final int requiredFrames;

  String? _currentId;
  int _streak = 0;

  /// Process [best] (the frame's top candidate) and return a result.
  ///
  /// Returns:
  ///   • `null` — no candidate above [minConfidence]; streak reset.
  ///   • uncertain — candidate visible but streak < [requiredFrames].
  ///   • confirmed — streak reached [requiredFrames].
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
      // New candidate — start fresh streak.
      _currentId = best.productId;
      _streak = 1;
      return ProductRecognitionResult.uncertain(
        productId: best.productId,
        confidence: best.confidence,
        source: best.source,
      );
    }

    // Same candidate — extend streak.
    _streak++;

    if (_streak < requiredFrames) {
      return ProductRecognitionResult.uncertain(
        productId: best.productId,
        confidence: best.confidence,
        source: best.source,
      );
    }

    // Streak met — confirmed.
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
