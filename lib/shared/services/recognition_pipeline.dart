import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';

import '../models/product_model.dart';
import 'embedding_persistence_service.dart';
import 'local_product_index_service.dart';
import 'product_recognition_result.dart';
import 'scan_lock_manager.dart';
import 'visual_embedding_service.dart';

/// Tuning knobs for [RecognitionPipeline].
class RecognitionConfig {
  const RecognitionConfig({
    this.frameSkip = 4,
    this.minConfidence,
    this.minMargin = 0.12,
    this.minSupportingReferences = 1,
    this.confirmationFrames = 3,
    this.absentTicksToUnlock = 10,
    this.minFrameBrightness = 25,
    this.maxFrameBrightness = 235,
    this.minFrameLumaStdDev = 8,
  });

  /// Process 1 out of every [frameSkip] frames from the camera stream.
  final int frameSkip;

  /// Minimum similarity score to consider a candidate.
  final double? minConfidence;

  /// Required gap between best and second-best candidate.
  final double minMargin;

  /// Minimum number of product references that must support the best match.
  final int minSupportingReferences;

  /// Consecutive processed frames the same product must appear in before
  /// it is declared [RecognitionStatus.confirmed].
  final int confirmationFrames;

  /// Frames without detection before a cart-lock is released.
  final int absentTicksToUnlock;

  /// Cheap frame-quality gates applied before inference.
  final double minFrameBrightness;
  final double maxFrameBrightness;
  final double minFrameLumaStdDev;
}

/// Timing and matching telemetry for one recognition attempt.
class RecognitionDiagnostics {
  const RecognitionDiagnostics({
    this.preprocessingMs = 0,
    this.inferenceMs = 0,
    this.searchMs = 0,
    this.totalMs = 0,
    this.indexedProducts = 0,
    this.indexedEmbeddings = 0,
    this.backend = 'unknown',
    this.bestProductId,
    this.secondBestProductId,
    this.bestScore = 0,
    this.secondBestScore = 0,
    this.margin = 0,
    this.meanBrightness,
    this.lumaStdDev,
  });

  final int preprocessingMs;
  final int inferenceMs;
  final int searchMs;
  final int totalMs;
  final int indexedProducts;
  final int indexedEmbeddings;
  final String backend;
  final String? bestProductId;
  final String? secondBestProductId;
  final double bestScore;
  final double secondBestScore;
  final double margin;
  final double? meanBrightness;
  final double? lumaStdDev;
}

class RecognitionFrameReport {
  const RecognitionFrameReport({
    required this.processed,
    required this.result,
    required this.diagnostics,
  });

  factory RecognitionFrameReport.skipped(RecognitionDiagnostics diagnostics) =>
      RecognitionFrameReport(
        processed: false,
        result: ProductRecognitionResult.ready(),
        diagnostics: diagnostics,
      );

  final bool processed;
  final ProductRecognitionResult result;
  final RecognitionDiagnostics diagnostics;
}

/// Orchestrates the local visual recognition flow:
/// CameraImage → embedding → local index → threshold + margin → temporal
/// confirmation → duplicate lock.
class RecognitionPipeline {
  RecognitionPipeline({
    RecognitionConfig? config,
    VisualEmbeddingService? embeddingService,
    LocalProductIndexService? indexService,
    ScanLockManager? lockManager,
    EmbeddingPersistenceService? persistenceService,
  }) : _config = config ?? const RecognitionConfig() {
    _embedding = embeddingService ?? VisualEmbeddingProvider();
    _persistence = persistenceService;
    _index = indexService ??
        LocalProductIndexService(
          embeddingService: _embedding,
          persistenceService: _persistence,
        );
    _locks = lockManager ??
        ScanLockManager(unlockAfterTicks: _config.absentTicksToUnlock);
    _tracker = _TemporalTracker(requiredFrames: _config.confirmationFrames);
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
  double _minConfidence = 0.45;

  void Function(ProductRecognitionResult result)? onConfirmed;
  void Function(ProductRecognitionResult result)? onUncertain;
  void Function(ProductRecognitionResult result)? onNoMatch;
  void Function(RecognitionFrameReport report)? onReport;

  Future<void> initialize() async {
    if (_embedding is VisualEmbeddingProvider) {
      await (_embedding as VisualEmbeddingProvider).initialize();
    }
    _minConfidence = _config.minConfidence ?? _embedding.recommendedMinConfidence;
  }

  bool get isOnnxActive =>
      _embedding is VisualEmbeddingProvider &&
      (_embedding as VisualEmbeddingProvider).isOnnxActive;

  bool get isFallbackActive =>
      _embedding is VisualEmbeddingProvider && !isOnnxActive;

  String get backendName {
    if (_embedding is VisualEmbeddingProvider) {
      return isOnnxActive ? 'ONNX Runtime' : 'visual engine unavailable';
    }
    return _embedding.runtimeType.toString();
  }

  Future<void> buildIndex(
    List<ProductModel> products, {
    Map<String, List<String>> extraImagePaths = const {},
  }) {
    _minConfidence = _config.minConfidence ?? _embedding.recommendedMinConfidence;
    return _index.buildIndex(products, extraImagePaths: extraImagePaths);
  }

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
  int get indexedEmbeddingCount => _index.indexedEmbeddingCount;
  double get minConfidence => _minConfidence;
  double get minMargin => _config.minMargin;

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

  RecognitionFrameReport processFrame(CameraImage image) {
    final baseDiagnostics = _diagnostics();
    if (!_active || _processing || !isIndexReady) {
      return RecognitionFrameReport.skipped(baseDiagnostics);
    }
    if (++_frameCount % _config.frameSkip != 0) {
      return RecognitionFrameReport.skipped(baseDiagnostics);
    }

    _processing = true;
    final total = Stopwatch()..start();
    try {
      final prep = Stopwatch()..start();
      final quality = _FrameQuality.fromCameraImage(image);
      prep.stop();
      if (!quality.isAcceptable(_config)) {
        final diagnostics = _diagnostics(
          preprocessingMs: prep.elapsedMilliseconds,
          totalMs: total.elapsedMilliseconds,
          meanBrightness: quality.meanBrightness,
          lumaStdDev: quality.lumaStdDev,
        );
        final result = ProductRecognitionResult.noMatch(
          reason: 'FrameQualityTooLow',
        );
        _emitNoMatch(result, diagnostics);
        return RecognitionFrameReport(
          processed: true,
          result: result,
          diagnostics: diagnostics,
        );
      }

      final inference = Stopwatch()..start();
      final embedding = _embedding.embedFrame(image);
      inference.stop();
      final report = embedding == null
          ? _noMatchReport(
              reason: 'embedding_failed',
              total: total,
              preprocessingMs: prep.elapsedMilliseconds,
              inferenceMs: inference.elapsedMilliseconds,
              meanBrightness: quality.meanBrightness,
              lumaStdDev: quality.lumaStdDev,
            )
          : evaluateEmbedding(
              embedding,
              totalStopwatch: total,
              preprocessingMs: prep.elapsedMilliseconds,
              inferenceMs: inference.elapsedMilliseconds,
              meanBrightness: quality.meanBrightness,
              lumaStdDev: quality.lumaStdDev,
            );
      return report;
    } catch (e) {
      final diagnostics = _diagnostics(totalMs: total.elapsedMilliseconds);
      final report = RecognitionFrameReport(
        processed: true,
        result: ProductRecognitionResult.error(e.toString()),
        diagnostics: diagnostics,
      );
      onReport?.call(report);
      return report;
    } finally {
      _processing = false;
    }
  }

  RecognitionFrameReport evaluateEmbedding(
    Uint8List embedding, {
    Stopwatch? totalStopwatch,
    int preprocessingMs = 0,
    int inferenceMs = 0,
    double? meanBrightness,
    double? lumaStdDev,
  }) {
    final total = totalStopwatch ?? (Stopwatch()..start());
    final searchTimer = Stopwatch()..start();
    final search = _index.evaluate(
      embedding,
      minConfidence: _minConfidence,
      minMargin: _config.minMargin,
      minSupportingReferences: _config.minSupportingReferences,
    );
    searchTimer.stop();

    final diagnostics = _diagnostics(
      preprocessingMs: preprocessingMs,
      inferenceMs: inferenceMs,
      searchMs: searchTimer.elapsedMilliseconds,
      totalMs: total.elapsedMilliseconds,
      bestProductId: search.best?.productId,
      secondBestProductId: search.secondBest?.productId,
      bestScore: search.bestScore,
      secondBestScore: search.secondBestScore,
      margin: search.margin,
      meanBrightness: meanBrightness,
      lumaStdDev: lumaStdDev,
    );

    final result = _resultFromSearch(search);
    final report = RecognitionFrameReport(
      processed: true,
      result: result,
      diagnostics: diagnostics,
    );
    onReport?.call(report);
    if (result.isNoMatch) onNoMatch?.call(result);
    return report;
  }

  ProductRecognitionResult _resultFromSearch(RecognitionSearchResult search) {
    if (!search.isAccepted) {
      _tracker.reset();
      _locks.tick(const {});
      return ProductRecognitionResult.noMatch(
        reason: search.rejectionReason,
        confidence: search.bestScore,
        secondBestConfidence: search.secondBestScore,
        margin: search.margin,
      );
    }

    final best = search.best!;
    _locks.tick({best.productId});
    final tracked = _tracker.advance(
      best,
      secondBestConfidence: search.secondBestScore,
      margin: search.margin,
    );

    if (tracked.isConfirmed) {
      final shouldAdd = _locks.onDetected(tracked.productId!);
      if (shouldAdd) onConfirmed?.call(tracked);
      return tracked;
    }

    onUncertain?.call(tracked);
    return tracked;
  }

  RecognitionFrameReport _noMatchReport({
    required String reason,
    required Stopwatch total,
    int preprocessingMs = 0,
    int inferenceMs = 0,
    double? meanBrightness,
    double? lumaStdDev,
  }) {
    final result = ProductRecognitionResult.noMatch(reason: reason);
    final diagnostics = _diagnostics(
      preprocessingMs: preprocessingMs,
      inferenceMs: inferenceMs,
      totalMs: total.elapsedMilliseconds,
      meanBrightness: meanBrightness,
      lumaStdDev: lumaStdDev,
    );
    _emitNoMatch(result, diagnostics);
    return RecognitionFrameReport(
      processed: true,
      result: result,
      diagnostics: diagnostics,
    );
  }

  void _emitNoMatch(
    ProductRecognitionResult result,
    RecognitionDiagnostics diagnostics,
  ) {
    _tracker.reset();
    _locks.tick(const {});
    onNoMatch?.call(result);
    onReport?.call(RecognitionFrameReport(
      processed: true,
      result: result,
      diagnostics: diagnostics,
    ));
  }

  RecognitionDiagnostics _diagnostics({
    int preprocessingMs = 0,
    int inferenceMs = 0,
    int searchMs = 0,
    int totalMs = 0,
    String? bestProductId,
    String? secondBestProductId,
    double bestScore = 0,
    double secondBestScore = 0,
    double margin = 0,
    double? meanBrightness,
    double? lumaStdDev,
  }) =>
      RecognitionDiagnostics(
        preprocessingMs: preprocessingMs,
        inferenceMs: inferenceMs,
        searchMs: searchMs,
        totalMs: totalMs,
        indexedProducts: indexedProductCount,
        indexedEmbeddings: indexedEmbeddingCount,
        backend: backendName,
        bestProductId: bestProductId,
        secondBestProductId: secondBestProductId,
        bestScore: bestScore,
        secondBestScore: secondBestScore,
        margin: margin,
        meanBrightness: meanBrightness,
        lumaStdDev: lumaStdDev,
      );
}

class _TemporalTracker {
  _TemporalTracker({this.requiredFrames = 3});

  final int requiredFrames;

  String? _currentId;
  int _streak = 0;

  ProductRecognitionResult advance(
    RecognitionCandidate best, {
    required double secondBestConfidence,
    required double margin,
  }) {
    if (best.productId != _currentId) {
      _currentId = best.productId;
      _streak = 1;
    } else {
      _streak++;
    }

    if (_streak < requiredFrames) {
      return ProductRecognitionResult.uncertain(
        productId: best.productId,
        confidence: best.confidence,
        secondBestConfidence: secondBestConfidence,
        margin: margin,
        referenceCount: best.referenceCount,
        supportingReferenceCount: best.supportingReferenceCount,
        source: best.source,
      );
    }

    return ProductRecognitionResult.confirmed(
      productId: best.productId,
      confidence: best.confidence,
      secondBestConfidence: secondBestConfidence,
      margin: margin,
      referenceCount: best.referenceCount,
      supportingReferenceCount: best.supportingReferenceCount,
      source: best.source,
    );
  }

  void reset() {
    _currentId = null;
    _streak = 0;
  }
}

class _FrameQuality {
  const _FrameQuality({
    required this.meanBrightness,
    required this.lumaStdDev,
  });

  factory _FrameQuality.fromCameraImage(CameraImage image) {
    final yPlane = image.planes.first.bytes;
    if (yPlane.isEmpty) {
      return const _FrameQuality(meanBrightness: 0, lumaStdDev: 0);
    }

    const maxSamples = 1200;
    final step = (yPlane.length / maxSamples).ceil().clamp(1, 1 << 30);
    var count = 0;
    var sum = 0.0;
    var sumSq = 0.0;
    for (var i = 0; i < yPlane.length; i += step) {
      final v = yPlane[i].toDouble();
      sum += v;
      sumSq += v * v;
      count++;
    }
    final mean = sum / count;
    final variance = (sumSq / count) - (mean * mean);
    return _FrameQuality(
      meanBrightness: mean,
      lumaStdDev: variance <= 0 ? 0 : math.sqrt(variance),
    );
  }

  final double meanBrightness;
  final double lumaStdDev;

  bool isAcceptable(RecognitionConfig config) {
    return meanBrightness >= config.minFrameBrightness &&
        meanBrightness <= config.maxFrameBrightness &&
        lumaStdDev >= config.minFrameLumaStdDev;
  }
}
