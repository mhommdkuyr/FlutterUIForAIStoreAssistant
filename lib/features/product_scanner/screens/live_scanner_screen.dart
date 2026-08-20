import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/i18n/app_translations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/models/product_model.dart';
import '../../../shared/repositories/product_repository.dart';
import '../../../shared/repositories/repository_exceptions.dart';
import '../../../shared/services/embedding_persistence_service.dart';
import '../../../shared/services/product_image_service.dart';
import '../../../shared/services/product_recognition_result.dart';
import '../../../shared/services/recognition_pipeline.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public data class shared with SalesScreen via router extra.
// ─────────────────────────────────────────────────────────────────────────────
class ScanCartItem {
  final String id;
  final String name;
  final double unitPrice;
  int quantity;

  ScanCartItem({
    required this.id,
    required this.name,
    required this.unitPrice,
    this.quantity = 1,
  });

  double get totalPrice => unitPrice * quantity;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'unitPrice': unitPrice,
        'quantity': quantity,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Scan status
// ─────────────────────────────────────────────────────────────────────────────
enum _ScanStatus { initializing, ready, processing, noMatch, uncertain, confirmed, error }

// ─────────────────────────────────────────────────────────────────────────────
// LiveScannerScreen
// ─────────────────────────────────────────────────────────────────────────────
class LiveScannerScreen extends StatefulWidget {
  const LiveScannerScreen({super.key});

  @override
  State<LiveScannerScreen> createState() => _LiveScannerScreenState();
}

class _LiveScannerScreenState extends State<LiveScannerScreen>
    with TickerProviderStateMixin {
  final ProductRepository _repository = ProductRepository();
  final ProductImageService _imageService = ProductImageService();
  late final RecognitionPipeline _pipeline;
  CameraController? _cameraController;

  List<ProductModel> _products = [];
  final List<ScanCartItem> _cart = [];

  _ScanStatus _status = _ScanStatus.initializing;
  ProductModel? _currentCandidate;
  ProductModel? _lastConfirmedProduct;
  ProductRecognitionResult? _currentFrameResult;
  RecognitionDiagnostics? _diagnostics;
  String? _errorMessage;

  Timer? _statusResetTimer;
  CameraImage? _latestFrame;
  bool _frameWorkerActive = false;
  int _cameraFrameCount = 0;
  int _cameraFps = 0;
  DateTime _fpsWindowStarted = DateTime.now();

  late final AnimationController _frameAnimCtrl;
  late final AnimationController _overlayAnimCtrl;
  late final Animation<double> _frameOpacity;
  late final Animation<double> _overlayAnim;

  bool _isLoading = true;

  @override
  void initState() {
    super.initState();

    _frameAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _overlayAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );

    _frameOpacity = Tween<double>(begin: 0.55, end: 1.0).animate(
      CurvedAnimation(parent: _frameAnimCtrl, curve: Curves.easeInOut),
    );

    _overlayAnim = CurvedAnimation(
      parent: _overlayAnimCtrl,
      curve: Curves.easeOut,
    );

    _pipeline = RecognitionPipeline(
      persistenceService: EmbeddingPersistenceService(),
      config: const RecognitionConfig(
        frameSkip: 5,
        minMargin: 0.12,
        minSupportingReferences: 1,
        confirmationFrames: 3,
        absentTicksToUnlock: 12,
      ),
    );
    _pipeline.onReport = _handleRecognitionReport;
    _pipeline.onConfirmed = _handleConfirmed;
    _loadProductsAndStartVisualRecognition();
  }

  @override
  void dispose() {
    _statusResetTimer?.cancel();
    _cameraController?.dispose();
    _frameAnimCtrl.dispose();
    _overlayAnimCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProductsAndStartVisualRecognition() async {
    try {
      final products = await _repository.getAllProducts();
      final extraPaths = <String, List<String>>{};
      for (final product in products) {
        extraPaths[product.id] =
            await _imageService.getAdditionalImagePaths(product.id);
      }

      if (mounted) setState(() => _products = products);

      await _pipeline.initialize();
      if (!_pipeline.isOnnxActive) {
        throw StateError(
          _pipeline.initializationError?.toString() ??
              'MobileCLIP2 ONNX visual engine is unavailable.',
        );
      }
      await _pipeline.buildIndex(products, extraImagePaths: extraPaths);
      if (!_pipeline.isIndexReady || _pipeline.indexedEmbeddingCount == 0) {
        throw StateError(
          'MobileCLIP2 index contains no usable product embeddings. Verify product image paths and runtime initialization.',
        );
      }
      await _startVisualCamera();

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _status = _ScanStatus.ready;
      });
    } on RepositoryException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _startVisualCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw StateError('No camera available');
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await controller.initialize();
    _cameraController = controller;
    await controller.startImageStream(_onCameraFrame);
  }

  void _onCameraFrame(CameraImage image) {
    _trackCameraFps();
    _latestFrame = image;
    if (_frameWorkerActive) return;
    _frameWorkerActive = true;
    Future<void>(_drainLatestFrame);
  }

  Future<void> _drainLatestFrame() async {
    try {
      while (mounted && _latestFrame != null) {
        final frame = _latestFrame!;
        _latestFrame = null;
        final report = await _pipeline.processFrame(frame);
        if (!report.processed) continue;
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _frameWorkerActive = false;
      if (mounted && _latestFrame != null) {
        _onCameraFrame(_latestFrame!);
      }
    }
  }

  void _trackCameraFps() {
    _cameraFrameCount++;
    final now = DateTime.now();
    final elapsed = now.difference(_fpsWindowStarted);
    if (elapsed >= const Duration(seconds: 1)) {
      _cameraFps = (_cameraFrameCount * 1000 / elapsed.inMilliseconds).round();
      _cameraFrameCount = 0;
      _fpsWindowStarted = now;
    }
  }

  void _handleRecognitionReport(RecognitionFrameReport report) {
    if (!mounted) return;
    final result = report.result;
    final candidate = result.productId == null ? null : _findById(result.productId!);
    setState(() {
      _diagnostics = report.diagnostics;
      _currentFrameResult = result;
      _currentCandidate = result.isNoMatch ? null : candidate;
      _status = _statusFromRecognition(result.status);
      if (result.isNoMatch) {
        _overlayAnimCtrl.reverse();
      }
    });
  }

  void _handleConfirmed(ProductRecognitionResult result) {
    final product = result.productId == null ? null : _findById(result.productId!);
    if (!mounted || product == null) return;
    setState(() {
      _lastConfirmedProduct = product;
      _currentCandidate = product;
      _status = _ScanStatus.confirmed;
    });
    _addToCart(product);
    _pipeline.pause();
    _overlayAnimCtrl.forward(from: 0);
    _statusResetTimer?.cancel();
    _statusResetTimer = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      _overlayAnimCtrl.reverse();
      _pipeline.resume();
      setState(() {
        _status = _ScanStatus.ready;
        _currentCandidate = null;
        _currentFrameResult = ProductRecognitionResult.ready();
      });
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _status = _ScanStatus.error;
      _errorMessage = message;
    });
  }

  _ScanStatus _statusFromRecognition(RecognitionStatus status) {
    switch (status) {
      case RecognitionStatus.initializing:
        return _ScanStatus.initializing;
      case RecognitionStatus.ready:
        return _ScanStatus.ready;
      case RecognitionStatus.processing:
        return _ScanStatus.processing;
      case RecognitionStatus.uncertain:
        return _ScanStatus.uncertain;
      case RecognitionStatus.confirmed:
        return _ScanStatus.confirmed;
      case RecognitionStatus.noMatch:
      case RecognitionStatus.rejected:
        return _ScanStatus.noMatch;
      case RecognitionStatus.error:
        return _ScanStatus.error;
    }
  }

  ProductModel? _findById(String id) {
    try {
      return _products.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  void _addToCart(ProductModel product) {
    final idx = _cart.indexWhere((c) => c.id == product.id);
    if (idx >= 0) {
      setState(() => _cart[idx].quantity++);
    } else {
      setState(() => _cart.add(ScanCartItem(
            id: product.id,
            name: product.name,
            unitPrice: product.sellingPrice,
          )));
    }
  }

  int get _totalItems => _cart.fold(0, (s, c) => s + c.quantity);

  void _goToInvoice() {
    _statusResetTimer?.cancel();
    context.go('/invoice', extra: {
      'cartItems': _cart.map((c) => c.toMap()).toList(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.tr;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: _cameraController != null &&
                    _cameraController!.value.isInitialized
                ? CameraPreview(_cameraController!)
                : const _CameraBackground(),
          ),

          Center(
            child: AnimatedBuilder(
              animation: _frameOpacity,
              builder: (context, _) {
                final color = switch (_status) {
                  _ScanStatus.confirmed => AppColors.success,
                  _ScanStatus.noMatch || _ScanStatus.error => AppColors.error,
                  _ScanStatus.uncertain || _ScanStatus.processing => AppColors.warning,
                  _ => AppColors.primary,
                };
                return _ScanFrame(
                  size: 220,
                  color: color.withOpacity(_frameOpacity.value),
                  isRecognizing: _status == _ScanStatus.processing ||
                      _status == _ScanStatus.uncertain,
                );
              },
            ),
          ),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => context.pop(),
                          icon: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            color: Colors.white,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            tr.liveScanTitle,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(blurRadius: 6, color: Colors.black54),
                              ],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        _CartBadge(count: _totalItems),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _StatusChip(status: _status, tr: tr),
                  const SizedBox(height: 8),
                  _VisualDebugPanel(
                    status: _status,
                    candidate: _currentCandidate,
                    lastConfirmed: _lastConfirmedProduct,
                    result: _currentFrameResult,
                    diagnostics: _diagnostics,
                    cameraFps: _cameraFps,
                    fallbackActive: _pipeline.isFallbackActive,
                    minConfidence: _pipeline.minConfidence,
                    minMargin: _pipeline.minMargin,
                    errorMessage: _errorMessage,
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => context.push('/scanner'),
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                    label: const Text('Barcode / manual fallback'),
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                  ),
                ],
              ),
            ),
          ),

          if (_lastConfirmedProduct != null)
            Positioned(
              left: 24,
              right: 24,
              bottom: 130,
              child: FadeTransition(
                opacity: _overlayAnim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.25),
                    end: Offset.zero,
                  ).animate(_overlayAnim),
                  child: _ProductFoundCard(
                    product: _lastConfirmedProduct!,
                    quantity: _cart
                        .where((c) => c.id == _lastConfirmedProduct!.id)
                        .fold(0, (_, c) => c.quantity),
                    tr: tr,
                  ),
                ),
              ),
            ),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_cart.isNotEmpty) ...[
                      _CartSummaryBar(cart: _cart, tr: tr),
                      const SizedBox(height: 10),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _cart.isEmpty ? null : _goToInvoice,
                        icon: const Icon(Icons.receipt_long_rounded),
                        label: Text(
                          _cart.isEmpty
                              ? tr.aimCameraAtProduct
                              : '${tr.doneScanning}  ·  $_totalItems ${tr.items}',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              _cart.isEmpty ? Colors.white24 : AppColors.success,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.white24,
                          disabledForegroundColor: Colors.white54,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              AppConstants.radiusMedium,
                            ),
                          ),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (_isLoading)
            Container(
              color: Colors.black54,
              child: const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CameraBackground  –  dark dot-grid to suggest a camera viewfinder
// ─────────────────────────────────────────────────────────────────────────────
class _CameraBackground extends StatelessWidget {
  const _CameraBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.2,
          colors: [Color(0xFF1A1A2E), Color(0xFF000000)],
        ),
      ),
      child: CustomPaint(
        painter: _DotGridPainter(),
        size: Size.infinite,
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.06)
      ..style = PaintingStyle.fill;
    const step = 22.0;
    for (double x = 0; x < size.width; x += step) {
      for (double y = 0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1.2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter _) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// _ScanFrame  –  corner-bracket viewfinder frame
// ─────────────────────────────────────────────────────────────────────────────
class _ScanFrame extends StatelessWidget {
  const _ScanFrame({
    required this.size,
    required this.color,
    required this.isRecognizing,
  });
  final double size;
  final Color color;
  final bool isRecognizing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          // Dimmed inner fill
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: color, width: 1.5),
              borderRadius: BorderRadius.circular(12),
              color: color.withOpacity(0.05),
            ),
          ),
          // Corner brackets
          ..._corners(color),
          // Scanning line animation
          if (isRecognizing)
            ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: _ScanLine(color: color),
            ),
        ],
      ),
    );
  }

  static List<Widget> _corners(Color color) {
    const len = 28.0;
    const thick = 3.5;
    Widget corner({
      required Alignment alignment,
      required BorderRadius radius,
      required EdgeInsets padding,
    }) =>
        Positioned.fill(
          child: Align(
            alignment: alignment,
            child: Padding(
              padding: padding,
              child: SizedBox(
                width: len,
                height: len,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: alignment.y < 0
                          ? BorderSide(color: color, width: thick)
                          : BorderSide.none,
                      bottom: alignment.y > 0
                          ? BorderSide(color: color, width: thick)
                          : BorderSide.none,
                      left: alignment.x < 0
                          ? BorderSide(color: color, width: thick)
                          : BorderSide.none,
                      right: alignment.x > 0
                          ? BorderSide(color: color, width: thick)
                          : BorderSide.none,
                    ),
                    borderRadius: radius,
                  ),
                ),
              ),
            ),
          ),
        );

    const p8 = EdgeInsets.all(8);
    return [
      corner(
        alignment: Alignment.topLeft,
        radius: const BorderRadius.only(topLeft: Radius.circular(10)),
        padding: p8,
      ),
      corner(
        alignment: Alignment.topRight,
        radius: const BorderRadius.only(topRight: Radius.circular(10)),
        padding: p8,
      ),
      corner(
        alignment: Alignment.bottomLeft,
        radius: const BorderRadius.only(bottomLeft: Radius.circular(10)),
        padding: p8,
      ),
      corner(
        alignment: Alignment.bottomRight,
        radius: const BorderRadius.only(bottomRight: Radius.circular(10)),
        padding: p8,
      ),
    ];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ScanLine  –  animated horizontal sweep line inside the frame
// ─────────────────────────────────────────────────────────────────────────────
class _ScanLine extends StatefulWidget {
  const _ScanLine({required this.color});
  final Color color;

  @override
  State<_ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<_ScanLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) => Align(
        alignment: Alignment(0, (_anim.value * 2) - 1),
        child: Container(
          height: 2,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.transparent,
                widget.color.withOpacity(0.9),
                Colors.transparent,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _StatusChip  –  status pill below the title bar
// ─────────────────────────────────────────────────────────────────────────────
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.tr});
  final _ScanStatus status;
  final AppTranslations tr;

  @override
  Widget build(BuildContext context) {
    final (text, color, icon) = switch (status) {
      _ScanStatus.initializing => (
          'Initializing visual model...',
          AppColors.warning,
          Icons.hourglass_top_rounded,
        ),
      _ScanStatus.ready => (
          tr.aimCameraAtProduct,
          Colors.white.withOpacity(0.85),
          Icons.center_focus_strong_rounded,
        ),
      _ScanStatus.processing => (
          tr.recognizing,
          AppColors.warning,
          Icons.radar_rounded,
        ),
      _ScanStatus.uncertain => (
          'Verifying match...',
          AppColors.warning,
          Icons.youtube_searched_for_rounded,
        ),
      _ScanStatus.confirmed => (
          tr.productFoundLabel,
          AppColors.success,
          Icons.check_circle_rounded,
        ),
      _ScanStatus.noMatch => (
          'No visual match',
          AppColors.error,
          Icons.highlight_off_rounded,
        ),
      _ScanStatus.error => (
          'Visual recognition error',
          AppColors.error,
          Icons.error_outline_rounded,
        ),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Container(
        key: ValueKey(status),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          borderRadius: BorderRadius.circular(AppConstants.radiusFull),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status == _ScanStatus.processing || status == _ScanStatus.uncertain)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(icon, color: color, size: 16),
              ),
            Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VisualDebugPanel extends StatelessWidget {
  const _VisualDebugPanel({
    required this.status,
    required this.candidate,
    required this.lastConfirmed,
    required this.result,
    required this.diagnostics,
    required this.cameraFps,
    required this.fallbackActive,
    required this.minConfidence,
    required this.minMargin,
    required this.errorMessage,
  });

  final _ScanStatus status;
  final ProductModel? candidate;
  final ProductModel? lastConfirmed;
  final ProductRecognitionResult? result;
  final RecognitionDiagnostics? diagnostics;
  final int cameraFps;
  final bool fallbackActive;
  final double minConfidence;
  final double minMargin;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final d = diagnostics;
    String pct(double value) => '${(value * 100).toStringAsFixed(1)}%';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 18),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.58),
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: Colors.white.withOpacity(0.18)),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.35),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('State: ${status.name}${fallbackActive ? ' · fallback active' : ''}'),
            if (errorMessage != null) Text('Error: $errorMessage'),
            Text('Candidate: ${candidate?.name ?? '—'}'),
            Text('Last confirmed: ${lastConfirmed?.name ?? '—'}'),
            Text('Product ID: ${result?.productId ?? '—'}'),
            Text(
              'Best: ${pct(d?.bestScore ?? result?.confidence ?? 0)} · '
              'Second: ${pct(d?.secondBestScore ?? result?.secondBestConfidence ?? 0)} · '
              'Margin: ${pct(d?.margin ?? result?.margin ?? 0)}',
            ),
            Text('Threshold: ${pct(minConfidence)} · Min margin: ${pct(minMargin)}'),
            Text(
              'Indexed: ${d?.indexedProducts ?? 0} products / '
              '${d?.indexedEmbeddings ?? 0} embeddings',
            ),
            Text('Backend: ${d?.backend ?? 'initializing'}'),
            Text(
              'FPS: $cameraFps · prep ${d?.preprocessingMs ?? 0}ms · '
              'infer ${d?.inferenceMs ?? 0}ms · search ${d?.searchMs ?? 0}ms · '
              'total ${d?.totalMs ?? 0}ms',
            ),
            Text(
              'Frame: brightness ${d?.meanBrightness?.toStringAsFixed(1) ?? '—'} · '
              'texture ${d?.lumaStdDev?.toStringAsFixed(1) ?? '—'}',
            ),
            if (result?.reason != null) Text('Reason: ${result!.reason}'),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CartBadge  –  top-right item counter
// ─────────────────────────────────────────────────────────────────────────────
class _CartBadge extends StatelessWidget {
  const _CartBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: count == 0
          ? const SizedBox(width: 48)
          : Container(
              key: ValueKey(count),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.success,
                borderRadius:
                    BorderRadius.circular(AppConstants.radiusFull),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.shopping_cart_rounded,
                      color: Colors.white, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    '$count',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ProductFoundCard  –  green popup showing name + price + qty
// ─────────────────────────────────────────────────────────────────────────────
class _ProductFoundCard extends StatelessWidget {
  const _ProductFoundCard({
    required this.product,
    required this.quantity,
    required this.tr,
  });
  final ProductModel product;
  final int quantity;
  final AppTranslations tr;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.success.withOpacity(0.95),
        borderRadius: BorderRadius.circular(AppConstants.radiusLarge),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.check_rounded,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  product.name,
                  style: textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  tr.formatCurrency(product.sellingPrice),
                  style: textTheme.bodySmall?.copyWith(
                    color: Colors.white.withOpacity(0.88),
                  ),
                ),
              ],
            ),
          ),
          if (quantity > 1)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius:
                    BorderRadius.circular(AppConstants.radiusFull),
              ),
              child: Text(
                '${tr.timesScanned}$quantity',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CartSummaryBar  –  compact strip showing scanned items above Done button
// ─────────────────────────────────────────────────────────────────────────────
class _CartSummaryBar extends StatelessWidget {
  const _CartSummaryBar({required this.cart, required this.tr});
  final List<ScanCartItem> cart;
  final AppTranslations tr;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border:
            Border.all(color: Colors.white.withOpacity(0.18)),
      ),
      child: Row(
        children: [
          const Icon(Icons.inventory_2_outlined,
              color: Colors.white70, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              cart.map((c) => c.quantity > 1 ? '${c.name} ×${c.quantity}' : c.name).join('  ·  '),
              style: textTheme.bodySmall?.copyWith(color: Colors.white70),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            tr.formatCurrency(
                cart.fold(0.0, (s, c) => s + c.totalPrice)),
            style: textTheme.labelMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
