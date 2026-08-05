import 'dart:async';

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
import '../../../shared/repositories/sale_repository.dart';
import '../../../shared/services/recognition_pipeline.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public data class  (used by SalesScreen via router extra)
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

  double get total => unitPrice * quantity;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'unitPrice': unitPrice,
        'quantity': quantity,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Enums
// ─────────────────────────────────────────────────────────────────────────────

enum _ScanStatus { idle, tracking, found, noMatch }

// ─────────────────────────────────────────────────────────────────────────────
// LiveScannerScreen
// ─────────────────────────────────────────────────────────────────────────────

/// Live Scan Workspace:
///   • SCAN MODE  — camera panel (bottom ~30%, draggable) + live cart (top)
///   • INVOICE MODE — full-screen invoice after the user taps "Done"
///
/// Recognition pipeline:
///   1. Pre-compute 16×16 aHash for every product image at session start.
///   2. Process every 4th camera frame (≈ 7 fps at 30 fps capture).
///   3. Match frame hash against cached product hashes (Hamming distance).
///   4. Per-product lock: a matched product is locked until it leaves the
///      camera view for [ScanLockManager.unlockAfterTicks] frames, then
///      re-entering the view counts as a new scan.
class LiveScannerScreen extends StatefulWidget {
  const LiveScannerScreen({super.key});

  @override
  State<LiveScannerScreen> createState() => _LiveScannerScreenState();
}

class _LiveScannerScreenState extends State<LiveScannerScreen>
    with TickerProviderStateMixin {
  // ── Services ──────────────────────────────────────────────────────────────
  final _repo = ProductRepository();
  final _saleRepo = SaleRepository();

  /// Phase 2 recognition pipeline — owns embedding, index, temporal
  /// confirmation, and scan-lock management.
  final _pipeline = RecognitionPipeline();

  // ── Data ──────────────────────────────────────────────────────────────────
  List<ProductModel> _products = [];
  final List<ScanCartItem> _cart = [];

  // ── Camera ────────────────────────────────────────────────────────────────
  CameraController? _cam;
  bool _camReady = false;

  // ── UI state ──────────────────────────────────────────────────────────────
  bool _loading = true;
  bool _scanActive = true; // true = scan mode, false = invoice mode
  _ScanStatus _status = _ScanStatus.idle;
  ProductModel? _lastFound;
  Timer? _statusTimer;
  bool _isSaving = false;

  // Camera panel height as fraction of screen height (user-draggable)
  double _camFraction = 0.32;
  static const double _camMin = 0.18;
  static const double _camMax = 0.62;

  // ── Animations ────────────────────────────────────────────────────────────
  late final AnimationController _overlayCtrl;
  late final Animation<double> _overlayAnim;
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  // ─── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _overlayCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _overlayAnim = CurvedAnimation(
      parent: _overlayCtrl,
      curve: Curves.easeOut,
    );
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.55, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Wire up Phase 2 pipeline callbacks.
    _pipeline.onConfirmed = (result) {
      if (!mounted || !_scanActive) return;
      final productId = result.productId;
      if (productId == null) return;
      try {
        final product = _products.firstWhere((p) => p.id == productId);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scanActive) _onProductFound(product);
        });
      } catch (_) {
        // Product not in current list — index is stale; ignore this frame.
      }
    };

    _pipeline.onUncertain = (result) {
      if (!mounted || !_scanActive) return;
      // Show a brief "locking on…" indicator without adding to cart.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scanActive && _status != _ScanStatus.found) {
          setState(() => _status = _ScanStatus.tracking);
        }
      });
    };

    _loadProducts();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _pipeline.pause();
    _cam?.dispose();
    _overlayCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ─── Data loading ─────────────────────────────────────────────────────────

  Future<void> _loadProducts() async {
    try {
      // 1. Initialise the ML embedding model (TFLite → aHash fallback).
      //    Safe to call multiple times; no-op after first successful init.
      await _pipeline.initialize();

      final products = await _repo.getAllProducts();

      // 2. Collect extra reference image paths from the ProductImages table
      //    so that multi-angle reference images are included in the index.
      final extraPaths = await _collectExtraImagePaths(products);

      // 3. Build (or rebuild) the recognition index.
      await _pipeline.buildIndex(products, extraImagePaths: extraPaths);

      if (!mounted) return;
      setState(() {
        _products = products;
        _loading = false;
      });
    } on RepositoryException catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Query the [ProductImages] DB table for additional reference image paths
  /// for each product and return a map suitable for
  /// [RecognitionPipeline.buildIndex].
  ///
  /// Using the DB table (written by [EnrollmentScreen]) rather than the
  /// filesystem scan in [ProductImageService] ensures that every image
  /// saved during enrollment is visible to the recognition index.
  Future<Map<String, List<String>>> _collectExtraImagePaths(
      List<ProductModel> products) async {
    final result = <String, List<String>>{};
    for (final p in products) {
      final extras = await _repo.getProductImages(p.id);
      if (extras.isNotEmpty) result[p.id] = extras;
    }
    return result;
  }

  // ─── Camera ───────────────────────────────────────────────────────────────

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      _cam = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cam!.initialize();
      _pipeline.resume();
      await _cam!.startImageStream(_onFrame);
      if (!mounted) return;
      setState(() => _camReady = true);
    } catch (_) {
      // Camera unavailable in this environment — graceful fallback.
    }
  }

  Future<void> _stopCamera() async {
    _pipeline.pause();
    if (_cam == null || !_cam!.value.isInitialized) return;
    try {
      await _cam!.stopImageStream();
    } catch (_) {}
  }

  // ─── Frame processing ─────────────────────────────────────────────────────

  /// Delegates every camera frame to the Phase 2 [RecognitionPipeline].
  ///
  /// The pipeline handles frame skipping, reentrancy, hash computation,
  /// local index search, temporal confirmation, and scan-lock management
  /// internally. Results arrive via [_pipeline.onConfirmed] and
  /// [_pipeline.onUncertain] callbacks wired in [initState].
  void _onFrame(CameraImage image) {
    if (!_scanActive || !mounted) return;
    _pipeline.processFrame(image);
  }

  // ─── Product found ────────────────────────────────────────────────────────

  void _onProductFound(ProductModel product) {
    _addToCart(product);
    setState(() {
      _status = _ScanStatus.found;
      _lastFound = product;
    });
    // Tactile + auditory feedback confirmed scan.
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.click);
    // Animate the found-toast overlay.
    _overlayCtrl.forward(from: 0);
    _statusTimer?.cancel();
    _statusTimer = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      _overlayCtrl.reverse();
      setState(() => _status = _ScanStatus.idle);
    });
  }

  void _addToCart(ProductModel p) {
    final idx = _cart.indexWhere((c) => c.id == p.id);
    if (idx >= 0) {
      setState(() => _cart[idx].quantity++);
    } else {
      setState(
        () => _cart.add(
          ScanCartItem(
            id: p.id,
            name: p.name,
            unitPrice: p.sellingPrice,
          ),
        ),
      );
    }
  }

  // ─── Mode transitions ─────────────────────────────────────────────────────

  /// Stop scan mode and show the full-screen invoice.
  Future<void> _onDone() async {
    _statusTimer?.cancel();
    setState(() {
      _scanActive = false;
      _status = _ScanStatus.idle;
    });
    await _stopCamera();
  }

  /// Return to scan mode from invoice mode and restart the camera.
  ///
  /// Reloads the product list and rebuilds the recognition index so any
  /// products added during this session are immediately recognisable.
  Future<void> _onScanMore() async {
    setState(() {
      _scanActive = true;
      _camReady = false;
      _status = _ScanStatus.idle;
    });
    _cam?.dispose();
    _cam = null;
    // Rebuild index in case products were added while in invoice mode.
    final products = await _repo.getAllProducts();
    final extraPaths = await _collectExtraImagePaths(products);
    await _pipeline.buildIndex(products, extraImagePaths: extraPaths);
    if (!mounted) return;
    setState(() => _products = products);
    _startCamera();
  }

  // ─── Invoice completion ───────────────────────────────────────────────────

  Future<void> _completeSale({String paymentMethod = 'cash'}) async {
    if (_cart.isEmpty || _isSaving) return;
    setState(() => _isSaving = true);
    try {
      await _saleRepo.createSale(
        items: _cart
            .map(
              (c) => ProductModel(
                id: c.id,
                name: c.name,
                category: 'Sale',
                purchasePrice: 0,
                sellingPrice: c.unitPrice,
                quantity: c.quantity,
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
              ),
            )
            .toList(),
        discount: 0,
        workerId: 'local-worker',
        paymentMethod: paymentMethod,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.white),
              const SizedBox(width: 10),
              Text(context.tr.saleConfirmedMsg),
            ],
          ),
          backgroundColor: AppColors.success,
          duration: const Duration(seconds: 2),
        ),
      );
      context.go('/ai-assistant');
    } on RepositoryException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: AppColors.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showElectronicPayment() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ElectronicPaymentSheet(
        total: _cartTotal,
        tr: ctx.tr,
        onConfirm: () {
          Navigator.pop(ctx);
          _completeSale(paymentMethod: 'electronic');
        },
      ),
    );
  }

  // ─── Computed properties ──────────────────────────────────────────────────

  double get _cartTotal => _cart.fold(0.0, (s, c) => s + c.total);
  int get _cartCount => _cart.fold(0, (s, c) => s + c.quantity);

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return _scanActive ? _buildScanMode() : _buildInvoiceMode();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SCAN MODE  — split view
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildScanMode() {
    final screenH = MediaQuery.sizeOf(context).height;
    final camH = (screenH * _camFraction).clamp(
      screenH * _camMin,
      screenH * _camMax,
    );
    final tr = context.tr;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Top header ────────────────────────────────────────────────
            _ScanModeHeader(
              cartCount: _cartCount,
              onBack: () => context.pop(),
              onDone: _cart.isEmpty ? null : _onDone,
              tr: tr,
            ),

            // ── Cart list (expands to fill remaining space) ───────────────
            Expanded(child: _buildCartPanel(tr)),

            // ── Total strip (only when cart has items) ─────────────────────
            if (_cart.isNotEmpty)
              _TotalStrip(total: _cartTotal, count: _cartCount, tr: tr),

            // ── Camera panel (draggable) ──────────────────────────────────
            GestureDetector(
              onVerticalDragUpdate: (d) {
                setState(() {
                  _camFraction = (_camFraction - d.delta.dy / screenH)
                      .clamp(_camMin, _camMax);
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 60),
                height: camH,
                child: _buildCameraPanel(tr),
              ),
            ),

            SizedBox(height: MediaQuery.paddingOf(context).bottom),
          ],
        ),
      ),
    );
  }

  // ── Cart panel ─────────────────────────────────────────────────────────────

  Widget _buildCartPanel(AppTranslations tr) {
    if (_cart.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _pulseAnim,
              builder: (_, __) => Opacity(
                opacity: _pulseAnim.value,
                child: Icon(
                  Icons.document_scanner_rounded,
                  size: 52,
                  color: AppColors.primary.withValues(alpha: 0.45),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              tr.aimCameraAtProduct,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      itemCount: _cart.length,
      itemBuilder: (_, i) {
        final item = _cart[i];
        return _CompactCartTile(
          item: item,
          onInc: () => setState(() => item.quantity++),
          onDec: () {
            if (item.quantity > 1) {
              setState(() => item.quantity--);
            } else {
              setState(() => _cart.removeAt(i));
            }
          },
          tr: tr,
        );
      },
    );
  }

  // ── Camera panel ────────────────────────────────────────────────────────────

  Widget _buildCameraPanel(AppTranslations tr) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: 16,
            offset: Offset(0, -4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // ── Camera preview or placeholder ─────────────────────────────
          Positioned.fill(
            child: _camReady && _cam != null && _cam!.value.isInitialized
                ? CameraPreview(_cam!)
                : _CameraPlaceholder(
                    onStart: _startCamera,
                    tr: tr,
                  ),
          ),

          // ── Drag handle pill ──────────────────────────────────────────
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),

          // ── Scan-frame overlay (center) ───────────────────────────────
          if (_camReady)
            Center(
              child: AnimatedBuilder(
                animation: _pulseAnim,
                builder: (_, __) {
                  final color = switch (_status) {
                    _ScanStatus.found => AppColors.success,
                    _ScanStatus.noMatch => AppColors.error,
                    _ScanStatus.tracking => AppColors.primary,
                    _ScanStatus.idle => AppColors.primary,
                  };
                  final opacity =
                      _status == _ScanStatus.idle ? _pulseAnim.value : 1.0;
                  return _ScanFrame(
                    size: 120,
                    color: color.withValues(alpha: opacity),
                    scanning: _status == _ScanStatus.idle,
                  );
                },
              ),
            ),

          // ── Status chip (bottom of camera panel) ─────────────────────
          if (_camReady)
            Positioned(
              bottom: 10,
              left: 0,
              right: 0,
              child: Center(
                child: _StatusChip(status: _status, tr: tr),
              ),
            ),

          // ── Product-found toast (top of camera panel) ─────────────────
          if (_lastFound != null)
            Positioned(
              top: 18,
              left: 12,
              right: 12,
              child: FadeTransition(
                opacity: _overlayAnim,
                child: _FoundToast(product: _lastFound!),
              ),
            ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // INVOICE MODE  — full-screen, camera stopped
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildInvoiceMode() {
    final tr = context.tr;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.instantInvoice),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => context.pop(),
        ),
        actions: [
          TextButton.icon(
            onPressed: _onScanMore,
            icon: const Icon(Icons.document_scanner_rounded, size: 18),
            label: Text(tr.scanMore),
          ),
        ],
      ),
      body: _cart.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.receipt_long_outlined,
                    size: 56,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(height: 12),
                  Text(tr.invoiceEmpty, style: theme.textTheme.bodyLarge),
                ],
              ),
            )
          : Column(
              children: [
                // Items list
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    itemCount: _cart.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final item = _cart[i];
                      return _InvoiceItemTile(
                        item: item,
                        onInc: () => setState(() => item.quantity++),
                        onDec: () {
                          if (item.quantity > 1) {
                            setState(() => item.quantity--);
                          }
                        },
                        onDelete: () => setState(() => _cart.removeAt(i)),
                        tr: tr,
                      );
                    },
                  ),
                ),

                // Bottom action panel
                _InvoiceBottomPanel(
                  total: _cartTotal,
                  count: _cartCount,
                  isSaving: _isSaving,
                  onCompleteSale: () => _completeSale(),
                  onElectronic: _showElectronicPayment,
                  tr: tr,
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ScanModeHeader
// ─────────────────────────────────────────────────────────────────────────────

class _ScanModeHeader extends StatelessWidget {
  const _ScanModeHeader({
    required this.cartCount,
    required this.onBack,
    required this.onDone,
    required this.tr,
  });
  final int cartCount;
  final VoidCallback onBack;
  final VoidCallback? onDone;
  final AppTranslations tr;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color:
                Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
      ),
      child: Row(
        children: [
          // Back button
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
            onPressed: onBack,
          ),

          // Title
          Expanded(
            child: Text(
              tr.liveScanTitle,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ),

          // Cart count badge
          if (cartCount > 0)
            Container(
              margin: const EdgeInsets.only(right: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppConstants.radiusFull),
              ),
              child: Text(
                '$cartCount ${tr.items}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ),

          // Done button
          TextButton.icon(
            onPressed: onDone,
            icon: const Icon(Icons.check_rounded, size: 18),
            label: Text(tr.done),
            style: TextButton.styleFrom(
              foregroundColor: onDone != null
                  ? AppColors.success
                  : Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _TotalStrip  —  compact total row between cart and camera panels
// ─────────────────────────────────────────────────────────────────────────────

class _TotalStrip extends StatelessWidget {
  const _TotalStrip({
    required this.total,
    required this.count,
    required this.tr,
  });
  final double total;
  final int count;
  final AppTranslations tr;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '$count ${tr.items}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            tr.formatCurrency(total),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CompactCartTile  —  row in the scan-mode cart (tight layout)
// ─────────────────────────────────────────────────────────────────────────────

class _CompactCartTile extends StatelessWidget {
  const _CompactCartTile({
    required this.item,
    required this.onInc,
    required this.onDec,
    required this.tr,
  });
  final ScanCartItem item;
  final VoidCallback onInc;
  final VoidCallback onDec;
  final AppTranslations tr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
        side: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.15),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            // Product name
            Expanded(
              child: Text(
                item.name,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),

            // Quantity controls
            _QtyControl(qty: item.quantity, onInc: onInc, onDec: onDec),
            const SizedBox(width: 12),

            // Line total
            Text(
              tr.formatCurrency(item.total),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _InvoiceItemTile  —  row in the invoice mode (more spacious)
// ─────────────────────────────────────────────────────────────────────────────

class _InvoiceItemTile extends StatelessWidget {
  const _InvoiceItemTile({
    required this.item,
    required this.onInc,
    required this.onDec,
    required this.onDelete,
    required this.tr,
  });
  final ScanCartItem item;
  final VoidCallback onInc;
  final VoidCallback onDec;
  final VoidCallback onDelete;
  final AppTranslations tr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        side: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.15),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // Name + unit price
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${tr.formatCurrency(item.unitPrice)} / ${tr.each}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // Quantity controls
            _QtyControl(qty: item.quantity, onInc: onInc, onDec: onDec),
            const SizedBox(width: 8),

            // Line total
            SizedBox(
              width: 72,
              child: Text(
                tr.formatCurrency(item.total),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
                textAlign: TextAlign.end,
              ),
            ),
            const SizedBox(width: 4),

            // Delete
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: onDelete,
              style: IconButton.styleFrom(
                foregroundColor: theme.colorScheme.outline,
                padding: EdgeInsets.zero,
                minimumSize: const Size(32, 32),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _QtyControl  —  reusable ± quantity widget
// ─────────────────────────────────────────────────────────────────────────────

class _QtyControl extends StatelessWidget {
  const _QtyControl({
    required this.qty,
    required this.onInc,
    required this.onDec,
  });
  final int qty;
  final VoidCallback onInc;
  final VoidCallback onDec;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _QtyBtn(icon: Icons.remove, onTap: onDec),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '$qty',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        _QtyBtn(icon: Icons.add, onTap: onInc),
      ],
    );
  }
}

class _QtyBtn extends StatelessWidget {
  const _QtyBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: 16, color: AppColors.primary),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _InvoiceBottomPanel  —  totals + action buttons in invoice mode
// ─────────────────────────────────────────────────────────────────────────────

class _InvoiceBottomPanel extends StatelessWidget {
  const _InvoiceBottomPanel({
    required this.total,
    required this.count,
    required this.isSaving,
    required this.onCompleteSale,
    required this.onElectronic,
    required this.tr,
  });
  final double total;
  final int count;
  final bool isSaving;
  final VoidCallback onCompleteSale;
  final VoidCallback onElectronic;
  final AppTranslations tr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Total row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('$count ${tr.items}', style: theme.textTheme.bodyMedium),
                Text(
                  tr.formatCurrency(total),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: isSaving ? null : onCompleteSale,
                    icon: isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(tr.completeSale),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.success,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: isSaving ? null : onElectronic,
                  icon: const Icon(Icons.qr_code_rounded, size: 18),
                  label: Text(tr.electronicPayment),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      vertical: 14,
                      horizontal: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CameraPlaceholder  —  shown before the camera is opened
// ─────────────────────────────────────────────────────────────────────────────

class _CameraPlaceholder extends StatelessWidget {
  const _CameraPlaceholder({required this.onStart, required this.tr});
  final VoidCallback onStart;
  final AppTranslations tr;

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
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _DotGridPainter()),
          ),
          Center(
            child: ElevatedButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.videocam_rounded),
              label: Text(tr.openCamera),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppConstants.radiusMedium),
                ),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
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
// _ScanFrame  —  corner-bracket viewfinder overlay
// ─────────────────────────────────────────────────────────────────────────────

class _ScanFrame extends StatelessWidget {
  const _ScanFrame({
    required this.size,
    required this.color,
    required this.scanning,
  });
  final double size;
  final Color color;
  final bool scanning;

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
              borderRadius: BorderRadius.circular(10),
              color: color.withValues(alpha: 0.05),
            ),
          ),
          // Corner brackets
          ..._corners(color),
          // Scanning sweep line
          if (scanning)
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: _ScanLine(color: color),
            ),
        ],
      ),
    );
  }

  static List<Widget> _corners(Color c) {
    const len = 22.0;
    const thick = 3.0;

    Widget corner({
      required Alignment align,
      required BorderRadius radius,
      required EdgeInsets pad,
    }) =>
        Positioned.fill(
          child: Align(
            alignment: align,
            child: Padding(
              padding: pad,
              child: SizedBox(
                width: len,
                height: len,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: align.y < 0
                          ? BorderSide(color: c, width: thick)
                          : BorderSide.none,
                      bottom: align.y > 0
                          ? BorderSide(color: c, width: thick)
                          : BorderSide.none,
                      left: align.x < 0
                          ? BorderSide(color: c, width: thick)
                          : BorderSide.none,
                      right: align.x > 0
                          ? BorderSide(color: c, width: thick)
                          : BorderSide.none,
                    ),
                    borderRadius: radius,
                  ),
                ),
              ),
            ),
          ),
        );

    const p = EdgeInsets.all(6);
    return [
      corner(
        align: Alignment.topLeft,
        radius: const BorderRadius.only(topLeft: Radius.circular(8)),
        pad: p,
      ),
      corner(
        align: Alignment.topRight,
        radius: const BorderRadius.only(topRight: Radius.circular(8)),
        pad: p,
      ),
      corner(
        align: Alignment.bottomLeft,
        radius: const BorderRadius.only(bottomLeft: Radius.circular(8)),
        pad: p,
      ),
      corner(
        align: Alignment.bottomRight,
        radius: const BorderRadius.only(bottomRight: Radius.circular(8)),
        pad: p,
      ),
    ];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ScanLine  —  animated horizontal sweep inside the viewfinder
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
      builder: (_, __) => Align(
        alignment: Alignment(0, _anim.value * 2 - 1),
        child: Container(
          height: 2,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.transparent,
                widget.color.withValues(alpha: 0.9),
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
// _StatusChip  —  pill indicator at bottom of camera panel
// ─────────────────────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.tr});
  final _ScanStatus status;
  final AppTranslations tr;

  @override
  Widget build(BuildContext context) {
    final (text, color, icon) = switch (status) {
      _ScanStatus.idle => (
          tr.aimCameraAtProduct,
          Colors.white.withValues(alpha: 0.85),
          Icons.center_focus_strong_rounded,
        ),
      _ScanStatus.tracking => (
          tr.lockingOn,
          AppColors.primary.withValues(alpha: 0.90),
          Icons.adjust_rounded,
        ),
      _ScanStatus.found => (
          tr.productFoundLabel,
          AppColors.success,
          Icons.check_circle_rounded,
        ),
      _ScanStatus.noMatch => (
          tr.productNotRecognized,
          AppColors.error,
          Icons.highlight_off_rounded,
        ),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Container(
        key: ValueKey(status),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(AppConstants.radiusFull),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _FoundToast  —  product-found notification inside camera panel
// ─────────────────────────────────────────────────────────────────────────────

class _FoundToast extends StatelessWidget {
  const _FoundToast({required this.product});
  final ProductModel product;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  product.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  product.category,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ElectronicPaymentSheet  —  QR payment bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _ElectronicPaymentSheet extends StatelessWidget {
  const _ElectronicPaymentSheet({
    required this.total,
    required this.tr,
    required this.onConfirm,
  });
  final double total;
  final AppTranslations tr;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle pill
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color:
                  Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          // QR placeholder
          Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context)
                    .colorScheme
                    .outline
                    .withValues(alpha: 0.3),
                width: 2,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.qr_code_rounded,
                  size: 80,
                  color: Theme.of(context).colorScheme.outline,
                ),
                Text(
                  tr.formatCurrency(total),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          Text(
            tr.paymentQRHint,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onConfirm,
              icon: const Icon(Icons.check_rounded),
              label: Text(tr.confirmPayment),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.success,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
