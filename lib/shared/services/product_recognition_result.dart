// ─────────────────────────────────────────────────────────────────────────────
// Enumerations
// ─────────────────────────────────────────────────────────────────────────────

/// The matching path that produced a [ProductRecognitionResult].
enum RecognitionSource {
  /// Visual hash / embedding comparison (primary path).
  embedding,

  /// Barcode string comparison (secondary path, confirms or overrides).
  barcode,

  /// No recognition was possible (empty index, fallback not ready, etc.).
  none,
}

/// The final disposition of a recognition attempt.
enum RecognitionStatus {
  /// Confirmed by temporal tracking — safe to add to the cart.
  confirmed,

  /// Candidate visible but not yet stable across enough consecutive frames.
  uncertain,

  /// Confidence below threshold — rejected to prevent wrong product insertion.
  rejected,
}

// ─────────────────────────────────────────────────────────────────────────────
// RecognitionCandidate  —  single search result from LocalProductIndexService
// ─────────────────────────────────────────────────────────────────────────────

/// A single candidate returned by [LocalProductIndexService.search].
///
/// Multiple candidates can be returned per frame (top-K). The pipeline
/// uses the highest-confidence candidate for temporal tracking.
class RecognitionCandidate {
  const RecognitionCandidate({
    required this.productId,
    required this.confidence,
    required this.hammingDistance,
    this.source = RecognitionSource.embedding,
  });

  /// The matching product's identifier.
  final String productId;

  /// Normalised similarity score: 1.0 = perfect match, 0.0 = total mismatch.
  final double confidence;

  /// Raw Hamming distance between query and stored hash (lower = better).
  final int hammingDistance;

  /// Recognition path that produced this candidate.
  final RecognitionSource source;

  @override
  String toString() => 'RecognitionCandidate('
      '$productId '
      'conf=${confidence.toStringAsFixed(2)} '
      'd=$hammingDistance)';
}

// ─────────────────────────────────────────────────────────────────────────────
// ProductRecognitionResult  —  final pipeline output
// ─────────────────────────────────────────────────────────────────────────────

/// Final result emitted by [RecognitionPipeline] after temporal confirmation.
///
/// Consumers should first check [status]:
/// - [RecognitionStatus.confirmed] → add [productId] to cart.
/// - [RecognitionStatus.uncertain] → optionally show a "locking on…" hint.
/// - [RecognitionStatus.rejected]  → ignore; no product found above threshold.
class ProductRecognitionResult {
  const ProductRecognitionResult({
    required this.status,
    this.productId,
    this.confidence = 0.0,
    this.source = RecognitionSource.none,
    this.reason,
  });

  // ── Named constructors ─────────────────────────────────────────────────────

  factory ProductRecognitionResult.confirmed({
    required String productId,
    required double confidence,
    RecognitionSource source = RecognitionSource.embedding,
  }) =>
      ProductRecognitionResult(
        status: RecognitionStatus.confirmed,
        productId: productId,
        confidence: confidence,
        source: source,
      );

  factory ProductRecognitionResult.uncertain({
    required String productId,
    required double confidence,
    RecognitionSource source = RecognitionSource.embedding,
  }) =>
      ProductRecognitionResult(
        status: RecognitionStatus.uncertain,
        productId: productId,
        confidence: confidence,
        source: source,
      );

  factory ProductRecognitionResult.rejected({String? reason}) =>
      ProductRecognitionResult(
        status: RecognitionStatus.rejected,
        reason: reason,
      );

  // ── Fields ─────────────────────────────────────────────────────────────────

  final RecognitionStatus status;

  /// Non-null when [status] is [confirmed] or [uncertain].
  final String? productId;

  /// Confidence (0.0 – 1.0) of the best candidate that led to this result.
  final double confidence;

  /// The recognition path that produced this result.
  final RecognitionSource source;

  /// Human-readable reason for rejection (debug / logging only).
  final String? reason;

  // ── Convenience ────────────────────────────────────────────────────────────

  bool get isConfirmed => status == RecognitionStatus.confirmed;
  bool get isUncertain => status == RecognitionStatus.uncertain;
  bool get isRejected => status == RecognitionStatus.rejected;

  @override
  String toString() => 'ProductRecognitionResult('
      'status=$status '
      'id=$productId '
      'conf=${confidence.toStringAsFixed(2)} '
      'src=$source)';
}
