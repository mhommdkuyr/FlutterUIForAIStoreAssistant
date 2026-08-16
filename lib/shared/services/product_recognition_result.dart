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
  /// Scanner/model/index is not ready yet.
  initializing,

  /// Scanner/model/index is ready and waiting for a usable frame.
  ready,

  /// A frame is currently being evaluated.
  processing,

  /// No product matched strongly enough for this frame.
  noMatch,

  /// Candidate visible but not yet stable across enough consecutive frames.
  uncertain,

  /// Confirmed by temporal tracking — safe to add to the cart.
  confirmed,

  /// Recognition cannot proceed because of an implementation/runtime error.
  error,

  /// Confidence below threshold — kept for backward compatibility.
  rejected,
}

// ─────────────────────────────────────────────────────────────────────────────
// RecognitionCandidate  —  single product score from LocalProductIndexService
// ─────────────────────────────────────────────────────────────────────────────

/// A single candidate returned by [LocalProductIndexService.search].
///
/// The score is product-level: all reference image embeddings for the product
/// are compared and the product receives the strongest visual match.
class RecognitionCandidate {
  const RecognitionCandidate({
    required this.productId,
    required this.confidence,
    required this.hammingDistance,
    this.referenceCount = 0,
    this.supportingReferenceCount = 0,
    this.source = RecognitionSource.embedding,
  });

  /// The matching product's identifier.
  final String productId;

  /// Normalised similarity score: 1.0 = perfect match, 0.0 = total mismatch.
  final double confidence;

  /// Raw Hamming distance between query and stored hash (lower = better).
  /// Not meaningful for cosine embeddings; retained for API compatibility.
  final int hammingDistance;

  /// Number of reference embeddings indexed for this product.
  final int referenceCount;

  /// Number of references that supported this match strongly enough.
  final int supportingReferenceCount;

  /// Recognition path that produced this candidate.
  final RecognitionSource source;

  @override
  String toString() => 'RecognitionCandidate('
      '$productId '
      'conf=${confidence.toStringAsFixed(2)} '
      'refs=$referenceCount '
      'support=$supportingReferenceCount)';
}

/// Full result of a single index lookup before temporal confirmation.
class RecognitionSearchResult {
  const RecognitionSearchResult({
    required this.candidates,
    this.minConfidence = 0.0,
    this.minMargin = 0.0,
    this.minSupportingReferences = 1,
  });

  final List<RecognitionCandidate> candidates;
  final double minConfidence;
  final double minMargin;
  final int minSupportingReferences;

  RecognitionCandidate? get best =>
      candidates.isEmpty ? null : candidates.first;

  RecognitionCandidate? get secondBest =>
      candidates.length < 2 ? null : candidates[1];

  double get bestScore => best?.confidence ?? 0.0;
  double get secondBestScore => secondBest?.confidence ?? 0.0;
  double get margin => bestScore - secondBestScore;

  bool get hasCandidate => best != null;
  bool get passesConfidence => bestScore >= minConfidence;
  bool get passesMargin => candidates.length <= 1 || margin >= minMargin;
  bool get passesReferenceSupport =>
      (best?.supportingReferenceCount ?? 0) >= minSupportingReferences;

  bool get isAccepted =>
      hasCandidate && passesConfidence && passesMargin && passesReferenceSupport;

  String? get rejectionReason {
    if (!hasCandidate) return 'no_candidate';
    if (!passesConfidence) return 'low_confidence';
    if (!passesMargin) return 'ambiguous_margin';
    if (!passesReferenceSupport) return 'weak_reference_support';
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ProductRecognitionResult  —  final pipeline output
// ─────────────────────────────────────────────────────────────────────────────

/// Final result emitted by [RecognitionPipeline] after per-frame validation and
/// temporal confirmation.
class ProductRecognitionResult {
  const ProductRecognitionResult({
    required this.status,
    this.productId,
    this.confidence = 0.0,
    this.secondBestConfidence = 0.0,
    this.margin = 0.0,
    this.referenceCount = 0,
    this.supportingReferenceCount = 0,
    this.source = RecognitionSource.none,
    this.reason,
  });

  factory ProductRecognitionResult.ready() => const ProductRecognitionResult(
        status: RecognitionStatus.ready,
      );

  factory ProductRecognitionResult.processing() => const ProductRecognitionResult(
        status: RecognitionStatus.processing,
      );

  factory ProductRecognitionResult.noMatch({
    String? reason,
    double confidence = 0.0,
    double secondBestConfidence = 0.0,
    double margin = 0.0,
  }) =>
      ProductRecognitionResult(
        status: RecognitionStatus.noMatch,
        confidence: confidence,
        secondBestConfidence: secondBestConfidence,
        margin: margin,
        reason: reason,
      );

  factory ProductRecognitionResult.confirmed({
    required String productId,
    required double confidence,
    double secondBestConfidence = 0.0,
    double margin = 0.0,
    int referenceCount = 0,
    int supportingReferenceCount = 0,
    RecognitionSource source = RecognitionSource.embedding,
  }) =>
      ProductRecognitionResult(
        status: RecognitionStatus.confirmed,
        productId: productId,
        confidence: confidence,
        secondBestConfidence: secondBestConfidence,
        margin: margin,
        referenceCount: referenceCount,
        supportingReferenceCount: supportingReferenceCount,
        source: source,
      );

  factory ProductRecognitionResult.uncertain({
    required String productId,
    required double confidence,
    double secondBestConfidence = 0.0,
    double margin = 0.0,
    int referenceCount = 0,
    int supportingReferenceCount = 0,
    RecognitionSource source = RecognitionSource.embedding,
  }) =>
      ProductRecognitionResult(
        status: RecognitionStatus.uncertain,
        productId: productId,
        confidence: confidence,
        secondBestConfidence: secondBestConfidence,
        margin: margin,
        referenceCount: referenceCount,
        supportingReferenceCount: supportingReferenceCount,
        source: source,
      );

  factory ProductRecognitionResult.rejected({String? reason}) =>
      ProductRecognitionResult.noMatch(reason: reason);

  factory ProductRecognitionResult.error(String reason) => ProductRecognitionResult(
        status: RecognitionStatus.error,
        reason: reason,
      );

  final RecognitionStatus status;

  /// Non-null only when [status] is [confirmed] or [uncertain].
  final String? productId;

  /// Confidence (0.0 – 1.0) of the best candidate.
  final double confidence;

  /// Confidence of the second-best candidate, if any.
  final double secondBestConfidence;

  /// Difference between best and second-best confidence.
  final double margin;

  /// Number of references indexed for the best candidate product.
  final int referenceCount;

  /// Number of references supporting the candidate strongly enough.
  final int supportingReferenceCount;

  /// Recognition path that produced this result.
  final RecognitionSource source;

  /// Human-readable reason for NoMatch/Error states.
  final String? reason;

  bool get isConfirmed => status == RecognitionStatus.confirmed;
  bool get isUncertain => status == RecognitionStatus.uncertain;
  bool get isNoMatch =>
      status == RecognitionStatus.noMatch || status == RecognitionStatus.rejected;
  bool get isRejected => isNoMatch;
  bool get isError => status == RecognitionStatus.error;

  @override
  String toString() => 'ProductRecognitionResult('
      'status=$status '
      'id=$productId '
      'conf=${confidence.toStringAsFixed(2)} '
      'second=${secondBestConfidence.toStringAsFixed(2)} '
      'margin=${margin.toStringAsFixed(2)} '
      'reason=$reason)';
}
