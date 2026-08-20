import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  CameraDescription? _cameraDescription;

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
    unawaited(_pipeline.dispose());
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

      // Show the actual camera before ONNX/index initialization finishes.
      await _startVisualCamera(startStream: false);
      if (mounted) {
        setState(() {
          _isLoading = false;
          _status = _ScanStatus.initializing;
        });
      }

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
      await _cameraController?.startImageStream(_onCameraFrame);

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

  Future<void> _startVisualCamera({bool startStream = true}) async {
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
    _cameraDescription = camera;
    _cameraController = controller;
    try {
      await controller.setFocusMode(FocusMode.auto);
    } catch (_) {
      // Some devices do not expose programmable autofocus.
    }
    if (startStream) {
      await controller.startImageStream(_onCameraFrame);
    }
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
        final report = await _pipeline.processFrame(
          frame,
          rotationDegrees: _frameRotationDegrees(),
        );
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

  int _frameRotationDegrees() {
    final description = _cameraDescription;
    final controller = _cameraController;
    if (!Platform.isAndroid || description == null || controller == null) {
      return 0;
    }
    final deviceRotation = switch (controller.value.deviceOrientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    if (description.lensDirection == CameraLensDirection.front) {
      return (description.sensorOrientation + deviceRotation) % 360;
    }
    return (description.sensorOrientation - deviceRotation + 360) % 360;
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
                      _CartSummary(cart: _cart, tr: tr),
                      const SizedBox(height: 10),
                    ],
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: _cart.isEmpty ? null : _goToInvoice,
                        icon: const Icon(Icons.receipt_long_rounded),
                        label: Text(
                          _cart.isEmpty
                              ? tr.scanProductsToContinue
                              : '${tr.completeSale} ($_totalItems)',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.white12,
                          disabledForegroundColor: Colors.white54,
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppConstants.radiusLarge),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}