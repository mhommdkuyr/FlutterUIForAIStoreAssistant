import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/i18n/app_translations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/repositories/product_repository.dart';
import '../../../shared/repositories/repository_exceptions.dart';
import '../../../shared/services/product_image_service.dart';
import '../../../shared/widgets/custom_button.dart';
import '../../../shared/widgets/custom_text_field.dart';

/// Product scanner screen.
/// Supports three input modes:
///   1. Barcode scanning (placeholder — requires camera_barcode_scanner integration)
///   2. Product image scanning (placeholder — requires Gemini Vision API)
///   3. Manual entry fallback
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key, this.initialBarcode});

  /// When set (e.g. coming from the live scanner after a "not found" scan),
  /// the barcode field is pre-filled and the form is shown immediately.
  final String? initialBarcode;

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  _ScanMode _mode = _ScanMode.barcode;
  bool _scanned = false;
  bool _isSaving = false;
  bool _inlineScanHandled = false;
  XFile? _pickedImage;
  final List<XFile> _additionalImages = [];
  late MobileScannerController _barcodeController;
  final ProductRepository _repository = ProductRepository();
  final ProductImageService _imageService = ProductImageService();

  // Form controllers for manual / confirmed entry
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _purchasePriceCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _barcodeCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _barcodeController = MobileScannerController();
    if (widget.initialBarcode != null && widget.initialBarcode!.isNotEmpty) {
      _barcodeCtrl.text = widget.initialBarcode!;
      _scanned = true; // Skip inline scanner, show form immediately
      // Try to pre-fill from DB asynchronously
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _lookupAndPreFill(widget.initialBarcode!));
    }
  }

  @override
  void dispose() {
    _barcodeController.dispose();
    _nameCtrl.dispose();
    _categoryCtrl.dispose();
    _priceCtrl.dispose();
    _purchasePriceCtrl.dispose();
    _qtyCtrl.dispose();
    _barcodeCtrl.dispose();
    super.dispose();
  }

  /// Called by the inline MobileScanner when a barcode frame is detected.
  Future<void> _onInlineBarcodeDetected(BarcodeCapture capture) async {
    if (_scanned || _inlineScanHandled) return;
    final value = capture.barcodes.firstOrNull?.rawValue;
    if (value == null || value.isEmpty) return;
    _inlineScanHandled = true;
    _barcodeCtrl.text = value;
    await _barcodeController.stop();
    await _lookupAndPreFill(value);
  }

  /// Searches the DB for a product matching [barcode] and pre-fills the form.
  /// Always calls setState to set _scanned = true regardless of whether a
  /// match is found (barcode field is already filled; user completes the rest).
  Future<void> _lookupAndPreFill(String barcode) async {
    try {
      final products = await _repository.getAllProducts();
      for (final p in products) {
        if (p.barcode?.trim() == barcode.trim()) {
          if (mounted) {
            _nameCtrl.text = p.name;
            _categoryCtrl.text = p.category;
            _priceCtrl.text = p.sellingPrice.toString();
            _purchasePriceCtrl.text = p.purchasePrice.toString();
            _qtyCtrl.text = p.quantity.toString();
          }
          break;
        }
      }
    } catch (_) {
      // No match — barcode field is filled; user enters the rest manually.
    }
    if (mounted) setState(() => _scanned = true);
  }

  /// Opens the device camera to capture a product image.
  Future<void> _openImageCamera() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.camera, imageQuality: 80);
    if (!mounted) return;
    if (file != null) {
      setState(() {
        _pickedImage = file;
        _scanned = true;
      });
    }
  }

  Future<void> _pickAdditionalImages() async {
    final files = await ImagePicker().pickMultiImage(imageQuality: 80);
    if (!mounted || files.isEmpty) return;
    setState(() => _additionalImages.addAll(files));
  }

  void _handleActivate() {
    // Barcode mode uses the inline live scanner — no tap needed.
    if (_mode == _ScanMode.image) {
      _openImageCamera();
    }
  }

  Future<void> _saveProduct() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isSaving = true);
    try {
      final primaryImagePath = _pickedImage == null
          ? null
          : await _imageService.savePickedImage(_pickedImage!);

      final product = await _repository.createProduct(
        name: _nameCtrl.text.trim(),
        category: _categoryCtrl.text.trim(),
        purchasePrice: double.parse(_purchasePriceCtrl.text),
        sellingPrice: double.parse(_priceCtrl.text),
        quantity: int.parse(_qtyCtrl.text),
        barcode: _barcodeCtrl.text.trim().isEmpty ? null : _barcodeCtrl.text.trim(),
        imageUrl: primaryImagePath,
      );

      for (final image in _additionalImages) {
        await _imageService.saveAdditionalImage(product.id, image);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr.productSaved),
          backgroundColor: AppColors.success,
        ),
      );
      Navigator.pop(context);
    } on RepositoryException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: AppColors.error),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.tr;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.addProduct)),
      body: Column(
        children: [
          // Mode selector
          Padding(
            padding: const EdgeInsets.all(AppConstants.paddingMD),
            child: Row(
              children: _ScanMode.values.map((m) {
                final isActive = _mode == m;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: m != _ScanMode.values.last ? 8 : 0),
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _mode = m;
                        _scanned = false;
                        _inlineScanHandled = false;
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: isActive ? AppColors.primary : Theme.of(context).cardTheme.color,
                          borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
                          border: Border.all(
                            color: isActive ? AppColors.primary : Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(m.icon, size: 20, color: isActive ? Colors.white : null),
                            const SizedBox(height: 2),
                            Text(
                              m.label(context),
                              style: textTheme.labelSmall?.copyWith(
                                color: isActive ? Colors.white : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppConstants.paddingMD),
              child: Column(
                children: [
                  // Scanner viewport — live camera for barcode mode, static for others
                  if (!_scanned) ...[
                    if (_mode == _ScanMode.barcode)
                      _InlineBarcodeViewport(
                        controller: _barcodeController,
                        onDetect: _onInlineBarcodeDetected,
                      )
                    else
                      _ScannerViewport(mode: _mode, onActivate: _handleActivate),
                    const SizedBox(height: 24),
                  ],

                  // Product form (shown after scan or for manual entry)
                  if (_scanned || _mode == _ScanMode.manual) ...[
                    if (_scanned) ...[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.success.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
                          border: Border.all(color: AppColors.success.withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              _mode == _ScanMode.barcode
                                  ? tr.barcodeScanned
                                  : tr.productDetected,
                              style: textTheme.bodySmall?.copyWith(color: AppColors.success),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          CustomTextField(
                            label: tr.productName,
                            hint: tr.productNameHint,
                            controller: _nameCtrl,
                            textInputAction: TextInputAction.next,
                            validator: (v) => (v?.isEmpty ?? true) ? tr.required : null,
                          ),
                          const SizedBox(height: 12),
                          CustomTextField(
                            label: tr.category,
                            hint: tr.categoryHint,
                            controller: _categoryCtrl,
                            textInputAction: TextInputAction.next,
                            validator: (v) => (v?.isEmpty ?? true) ? tr.required : null,
                          ),
                          const SizedBox(height: 12),
                          _ProductImagesSection(
                            primaryImage: _pickedImage,
                            additionalImageCount: _additionalImages.length,
                            onPickPrimary: _openImageCamera,
                            onPickAdditional: _pickAdditionalImages,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: CustomTextField(
                                  label: tr.purchasePrice,
                                  hint: '0.00',
                                  controller: _purchasePriceCtrl,
                                  keyboardType: TextInputType.number,
                                  textInputAction: TextInputAction.next,
                                  validator: (v) => (v?.isEmpty ?? true) ? tr.required : null,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: CustomTextField(
                                  label: tr.sellingPrice,
                                  hint: '0.00',
                                  controller: _priceCtrl,
                                  keyboardType: TextInputType.number,
                                  textInputAction: TextInputAction.next,
                                  validator: (v) => (v?.isEmpty ?? true) ? tr.required : null,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: CustomTextField(
                                  label: tr.quantity,
                                  hint: '0',
                                  controller: _qtyCtrl,
                                  keyboardType: TextInputType.number,
                                  textInputAction: TextInputAction.next,
                                  validator: (v) => (v?.isEmpty ?? true) ? tr.required : null,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: CustomTextField(
                                  label: tr.barcodeOptional,
                                  hint: tr.barcode,
                                  controller: _barcodeCtrl,
                                  textInputAction: TextInputAction.done,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          CustomButton(
                            label: tr.saveProduct,
                            onPressed: _saveProduct,
                            isLoading: _isSaving,
                            leading: const Icon(Icons.check_rounded, color: Colors.white),
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _InlineBarcodeViewport — shows a live camera feed directly in the form page.
// The MobileScanner widget starts the camera automatically when added to the
// tree and stops it when removed. No button press required.
// ─────────────────────────────────────────────────────────────────────────────
class _InlineBarcodeViewport extends StatelessWidget {
  const _InlineBarcodeViewport({
    required this.controller,
    required this.onDetect,
  });
  final MobileScannerController controller;
  final void Function(BarcodeCapture) onDetect;

  @override
  Widget build(BuildContext context) {
    final tr = context.tr;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppConstants.radiusLarge),
      child: SizedBox(
        height: 240,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(controller: controller, onDetect: onDetect),
            // Semi-transparent scan-frame overlay
            Center(
              child: Container(
                width: 190,
                height: 130,
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.primary, width: 2.5),
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.transparent,
                ),
              ),
            ),
            // Instruction pill at the bottom of the preview
            Positioned(
              bottom: 12,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(AppConstants.radiusFull),
                  ),
                  child: Text(
                    tr.pointAtBarcode,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScannerViewport extends StatelessWidget {
  const _ScannerViewport({required this.mode, required this.onActivate});
  final _ScanMode mode;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final tr = context.tr;
    return Container(
      height: 240,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(AppConstants.radiusLarge),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Scan frame
          Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.primary, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(mode.icon, size: 40, color: AppColors.primary),
              const SizedBox(height: 8),
              Text(
                mode == _ScanMode.barcode
                    ? tr.pointAtBarcode
                    : mode == _ScanMode.image
                        ? tr.pointAtProduct
                        : tr.enterDetails,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: onActivate,
                icon: const Icon(Icons.center_focus_strong_rounded),
                label: Text(tr.openCamera),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProductImagesSection extends StatelessWidget {
  const _ProductImagesSection({
    required this.primaryImage,
    required this.additionalImageCount,
    required this.onPickPrimary,
    required this.onPickAdditional,
  });

  final XFile? primaryImage;
  final int additionalImageCount;
  final VoidCallback onPickPrimary;
  final VoidCallback onPickAdditional;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.paddingSM),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Product images', style: textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onPickPrimary,
                icon: const Icon(Icons.add_a_photo_rounded),
                label: Text(
                  primaryImage == null
                      ? 'Add primary image'
                      : 'Replace primary image',
                ),
              ),
              OutlinedButton.icon(
                onPressed: onPickAdditional,
                icon: const Icon(Icons.photo_library_rounded),
                label: Text('Add references ($additionalImageCount)'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _ScanMode {
  barcode,
  image,
  manual;

  String label(BuildContext context) {
    switch (this) {
      case barcode: return context.tr.scanModeBarcode;
      case image: return context.tr.scanModeImage;
      case manual: return context.tr.scanModeManual;
    }
  }

  IconData get icon {
    switch (this) {
      case barcode: return Icons.qr_code_scanner_rounded;
      case image: return Icons.image_search_rounded;
      case manual: return Icons.edit_note_rounded;
    }
  }
}
