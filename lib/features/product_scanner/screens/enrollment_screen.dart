import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/i18n/app_translations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/repositories/product_repository.dart';
import '../../../shared/repositories/repository_exceptions.dart';
import '../../../shared/services/product_image_service.dart';
import '../../../shared/services/web_image_enrichment_service.dart';
import '../../../shared/widgets/custom_button.dart';
import '../../../shared/widgets/custom_text_field.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Enrollment Screen
//
// Dedicated product-addition flow:
//   • Product photo flow — capture primary + multiple reference images,
//     optional web image search, full product details form.
//   • Invoice flow — photograph an invoice, add line items manually,
//     save all as new products in one step.
// ─────────────────────────────────────────────────────────────────────────────

enum _EnrollFlow { landing, product, invoice }

/// A single line-item added during invoice capture.
class _LineItem {
  final TextEditingController name;
  final TextEditingController qty;
  final TextEditingController price;
  _LineItem()
      : name = TextEditingController(),
        qty = TextEditingController(text: '1'),
        price = TextEditingController();

  void dispose() {
    name.dispose();
    qty.dispose();
    price.dispose();
  }
}

class EnrollmentScreen extends StatefulWidget {
  const EnrollmentScreen({super.key});

  @override
  State<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

class _EnrollmentScreenState extends State<EnrollmentScreen> {
  // ── Services ───────────────────────────────────────────────────────────────
  final _repo = ProductRepository();
  final _imageService = ProductImageService();
  final _enrichment = WebImageEnrichmentService();
  final _picker = ImagePicker();

  // ── Navigation ─────────────────────────────────────────────────────────────
  _EnrollFlow _flow = _EnrollFlow.landing;

  // ── Product flow state ─────────────────────────────────────────────────────
  String? _primaryImagePath;
  final List<String> _refImagePaths = []; // saved locally
  bool _isSearchingWeb = false;
  List<String> _webImageUrls = [];
  final Set<String> _addedWebUrls = {}; // urls already downloaded
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _purchasePriceCtrl = TextEditingController();
  final _sellingPriceCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '1');
  final _barcodeCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  bool _isSaving = false;

  // ── Invoice flow state ─────────────────────────────────────────────────────
  String? _invoiceImagePath;
  final List<_LineItem> _lineItems = [];
  bool _isSavingInvoice = false;

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _nameCtrl.dispose();
    _categoryCtrl.dispose();
    _purchasePriceCtrl.dispose();
    _sellingPriceCtrl.dispose();
    _qtyCtrl.dispose();
    _barcodeCtrl.dispose();
    _descCtrl.dispose();
    for (final item in _lineItems) {
      item.dispose();
    }
    super.dispose();
  }

  // ─── Navigation helpers ─────────────────────────────────────────────────────

  void _goLanding() => setState(() {
        _flow = _EnrollFlow.landing;
        _clearProductState();
        _clearInvoiceState();
      });

  void _clearProductState() {
    _primaryImagePath = null;
    _refImagePaths.clear();
    _webImageUrls = [];
    _addedWebUrls.clear();
    _nameCtrl.clear();
    _categoryCtrl.clear();
    _purchasePriceCtrl.clear();
    _sellingPriceCtrl.clear();
    _qtyCtrl.text = '1';
    _barcodeCtrl.clear();
    _descCtrl.clear();
  }

  void _clearInvoiceState() {
    _invoiceImagePath = null;
    for (final item in _lineItems) {
      item.dispose();
    }
    _lineItems.clear();
  }

  // ─── Image capture helpers ──────────────────────────────────────────────────

  Future<void> _capturePrimary(ImageSource source) async {
    final file = await _picker.pickImage(
        source: source, imageQuality: 88, maxWidth: 1200);
    if (file == null || !mounted) return;
    final saved = await _imageService.savePickedImage(file);
    setState(() => _primaryImagePath = saved);
  }

  Future<void> _captureReference(ImageSource source) async {
    final file = await _picker.pickImage(
        source: source, imageQuality: 85, maxWidth: 1000);
    if (file == null || !mounted) return;
    // We need a productId-scoped dir. Use a temp key until the product is
    // saved; on save we move them into the real product dir.
    final saved = await _imageService.savePickedImage(file);
    setState(() => _refImagePaths.add(saved));
  }

  Future<void> _captureInvoicePhoto(ImageSource source) async {
    final file = await _picker.pickImage(
        source: source, imageQuality: 88, maxWidth: 1400);
    if (file == null || !mounted) return;
    final saved = await _imageService.savePickedImage(file);
    setState(() => _invoiceImagePath = saved);
  }

  // ─── Web enrichment ─────────────────────────────────────────────────────────

  Future<void> _searchWebImages() async {
    final query = _nameCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _isSearchingWeb = true;
      _webImageUrls = [];
    });
    final urls = await _enrichment.searchImages(query, maxResults: 8);
    if (!mounted) return;
    setState(() {
      _isSearchingWeb = false;
      _webImageUrls = urls;
    });
  }

  Future<void> _addWebImageAsReference(String url) async {
    if (_addedWebUrls.contains(url)) return;
    _addedWebUrls.add(url);
    // Download using a temporary product id "enroll_tmp" — will be moved on save
    final localPath = await _enrichment.downloadAndSave('enroll_tmp', url);
    if (!mounted) return;
    if (localPath != null) {
      setState(() => _refImagePaths.add(localPath));
      _showMessage(context.tr.webImageAdded);
    }
  }

  // ─── Product save ───────────────────────────────────────────────────────────

  Future<void> _saveProduct() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_primaryImagePath == null) {
      _showMessage(context.tr.tapToCapture, isError: true);
      return;
    }
    setState(() => _isSaving = true);
    try {
      final product = await _repo.createProduct(
        name: _nameCtrl.text.trim(),
        category: _categoryCtrl.text.trim(),
        purchasePrice: double.parse(_purchasePriceCtrl.text),
        sellingPrice: double.parse(_sellingPriceCtrl.text),
        quantity: int.parse(_qtyCtrl.text),
        barcode:
            _barcodeCtrl.text.trim().isEmpty ? null : _barcodeCtrl.text.trim(),
        description:
            _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
        imageUrl: _primaryImagePath,
      );

      // Copy each reference image from its temporary/shared location into
      // the permanent product directory (product_images/{productId}/),
      // then persist the permanent path into the ProductImages table.
      for (final tmpPath in _refImagePaths) {
        final permanentPath =
            await _imageService.saveAdditionalImageFromPath(product.id, tmpPath);
        await _repo.addProductImage(product.id, permanentPath);
      }

      if (!mounted) return;
      _showMessage(context.tr.enrollmentComplete);
      Navigator.pop(context);
    } on RepositoryException catch (e) {
      if (!mounted) return;
      _showMessage(e.message, isError: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ─── Invoice save ───────────────────────────────────────────────────────────

  Future<void> _saveAllLineItems() async {
    final valid = _lineItems.isNotEmpty &&
        _lineItems.every((item) => item.name.text.trim().isNotEmpty);
    if (!valid) {
      _showMessage(context.tr.noLineItems, isError: true);
      return;
    }
    setState(() => _isSavingInvoice = true);
    try {
      for (final item in _lineItems) {
        final name = item.name.text.trim();
        if (name.isEmpty) continue;
        final qty = int.tryParse(item.qty.text.trim()) ?? 1;
        final price = double.tryParse(item.price.text.trim()) ?? 0;
        await _repo.createProduct(
          name: name,
          category: 'فاتورة',
          purchasePrice: price,
          sellingPrice: price,
          quantity: qty,
          imageUrl: _invoiceImagePath,
        );
      }
      if (!mounted) return;
      _showMessage(context.tr.draftsSaved);
      Navigator.pop(context);
    } on RepositoryException catch (e) {
      if (!mounted) return;
      _showMessage(e.message, isError: true);
    } finally {
      if (mounted) setState(() => _isSavingInvoice = false);
    }
  }

  void _showMessage(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? AppColors.error : AppColors.success,
    ));
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return switch (_flow) {
      _EnrollFlow.landing => _buildLanding(),
      _EnrollFlow.product => _buildProductFlow(),
      _EnrollFlow.invoice => _buildInvoiceFlow(),
    };
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LANDING
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildLanding() {
    final tr = context.tr;
    return Scaffold(
      appBar: AppBar(title: Text(tr.addProduct)),
      body: Padding(
        padding: const EdgeInsets.all(AppConstants.paddingLG),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _FlowCard(
              icon: Icons.camera_alt_rounded,
              title: tr.addViaPhoto,
              description: tr.addViaPhotoDesc,
              color: AppColors.primary,
              onTap: () => setState(() => _flow = _EnrollFlow.product),
            ),
            const SizedBox(height: 20),
            _FlowCard(
              icon: Icons.receipt_long_rounded,
              title: tr.addFromInvoice,
              description: tr.addFromInvoiceDesc,
              color: AppColors.warning,
              onTap: () => setState(() => _flow = _EnrollFlow.invoice),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PRODUCT PHOTO FLOW
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildProductFlow() {
    final tr = context.tr;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.enrollProduct),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: _goLanding,
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppConstants.paddingMD),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Hint banner ────────────────────────────────────────────────
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius:
                    BorderRadius.circular(AppConstants.radiusMedium),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded,
                      size: 16, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(tr.enrollmentHint,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.primary)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Primary image ──────────────────────────────────────────────
            _SectionTitle(tr.primaryPhoto),
            const SizedBox(height: 8),
            _PrimaryImageCapture(
              imagePath: _primaryImagePath,
              hint: tr.tapToCapture,
              replaceLabel: tr.replacePhoto,
              galleryLabel: tr.orPickFromGallery,
              onCamera: () => _capturePrimary(ImageSource.camera),
              onGallery: () => _capturePrimary(ImageSource.gallery),
            ),
            const SizedBox(height: 20),

            // ── Reference images ───────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _SectionTitle(tr.referenceImages),
                Text(
                  '${_refImagePaths.length} ${tr.imagesCount}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_refImagePaths.isNotEmpty) ...[
              _ReferenceImageList(
                paths: _refImagePaths,
                onRemove: (path) =>
                    setState(() => _refImagePaths.remove(path)),
              ),
              const SizedBox(height: 10),
            ],
            _AddReferenceButtons(
              addLabel: tr.addReferenceImage,
              galleryLabel: tr.orPickFromGallery,
              onCamera: () => _captureReference(ImageSource.camera),
              onGallery: () => _captureReference(ImageSource.gallery),
            ),
            const SizedBox(height: 20),

            // ── Web enrichment ─────────────────────────────────────────────
            _SectionTitle(tr.searchWebImages),
            const SizedBox(height: 8),
            _WebEnrichmentPanel(
              isSearching: _isSearchingWeb,
              imageUrls: _webImageUrls,
              addedUrls: _addedWebUrls,
              nameIsEmpty: _nameCtrl.text.trim().isEmpty,
              searchLabel: tr.searchWebImages,
              searchingLabel: tr.searchingImages,
              noResultsLabel: tr.noWebImages,
              tapHint: tr.tapImageToAdd,
              onSearch: _searchWebImages,
              onSelect: _addWebImageAsReference,
            ),
            const SizedBox(height: 24),

            // ── Product details form ───────────────────────────────────────
            _SectionTitle(tr.productDetails),
            const SizedBox(height: 12),
            Form(
              key: _formKey,
              child: Column(
                children: [
                  CustomTextField(
                    label: tr.productName,
                    hint: tr.productNameHint,
                    controller: _nameCtrl,
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        (v?.trim().isEmpty ?? true) ? tr.required : null,
                    onChanged: (_) => setState(() {}), // refresh web panel
                  ),
                  const SizedBox(height: 12),
                  CustomTextField(
                    label: tr.category,
                    hint: tr.categoryHint,
                    controller: _categoryCtrl,
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        (v?.trim().isEmpty ?? true) ? tr.required : null,
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: CustomTextField(
                        label: tr.purchasePrice,
                        hint: '0.00',
                        controller: _purchasePriceCtrl,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.next,
                        validator: (v) =>
                            (double.tryParse(v ?? '') == null)
                                ? tr.mustBeNumber
                                : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: CustomTextField(
                        label: tr.sellingPrice,
                        hint: '0.00',
                        controller: _sellingPriceCtrl,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.next,
                        validator: (v) =>
                            (double.tryParse(v ?? '') == null)
                                ? tr.mustBeNumber
                                : null,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: CustomTextField(
                        label: tr.quantity,
                        hint: '1',
                        controller: _qtyCtrl,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.next,
                        validator: (v) =>
                            (int.tryParse(v ?? '') == null)
                                ? tr.mustBeNumber
                                : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: CustomTextField(
                        label: tr.barcodeOptional,
                        hint: tr.barcode,
                        controller: _barcodeCtrl,
                        textInputAction: TextInputAction.next,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  CustomTextField(
                    label: tr.descriptionOptional,
                    hint: '',
                    controller: _descCtrl,
                    maxLines: 2,
                    textInputAction: TextInputAction.done,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            CustomButton(
              label: tr.saveProduct,
              onPressed: _isSaving ? null : _saveProduct,
              isLoading: _isSaving,
              leading:
                  const Icon(Icons.check_rounded, color: Colors.white),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // INVOICE FLOW
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildInvoiceFlow() {
    final tr = context.tr;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.addFromInvoice),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: _goLanding,
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppConstants.paddingMD),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Invoice image ────────────────────────────────────────
                  _InvoiceCapture(
                    imagePath: _invoiceImagePath,
                    hint: tr.captureInvoice,
                    replaceLabel: tr.replaceInvoicePhoto,
                    galleryLabel: tr.orPickFromGallery,
                    onCamera: () =>
                        _captureInvoicePhoto(ImageSource.camera),
                    onGallery: () =>
                        _captureInvoicePhoto(ImageSource.gallery),
                  ),
                  const SizedBox(height: 24),

                  // ── Line items ───────────────────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _SectionTitle(tr.invoiceLineItems),
                      FilledButton.tonalIcon(
                        onPressed: () =>
                            setState(() => _lineItems.add(_LineItem())),
                        icon:
                            const Icon(Icons.add_rounded, size: 16),
                        label: Text(tr.addLineItem,
                            style: const TextStyle(fontSize: 13)),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_lineItems.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(
                            AppConstants.radiusMedium),
                      ),
                      child: Center(
                        child: Text(
                          tr.noLineItems,
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.outline),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _lineItems.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: 10),
                      itemBuilder: (_, i) => _LineItemTile(
                        item: _lineItems[i],
                        index: i + 1,
                        tr: tr,
                        onRemove: () => setState(() {
                          _lineItems[i].dispose();
                          _lineItems.removeAt(i);
                        }),
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),

          // ── Save footer ────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(
                    color: theme.colorScheme.outline
                        .withValues(alpha: 0.15)),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: CustomButton(
                  label: tr.saveAllDrafts,
                  onPressed:
                      _isSavingInvoice ? null : _saveAllLineItems,
                  isLoading: _isSavingInvoice,
                  leading: const Icon(Icons.save_alt_rounded,
                      color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private widget helpers
// ─────────────────────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context)
          .textTheme
          .titleSmall
          ?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

// ── Landing flow card ────────────────────────────────────────────────────────

class _FlowCard extends StatelessWidget {
  const _FlowCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String description;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
          borderRadius: BorderRadius.circular(AppConstants.radiusLarge),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius:
                    BorderRadius.circular(AppConstants.radiusMedium),
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(description,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: theme.colorScheme.outline),
          ],
        ),
      ),
    );
  }
}

// ── Primary image capture ────────────────────────────────────────────────────

class _PrimaryImageCapture extends StatelessWidget {
  const _PrimaryImageCapture({
    required this.imagePath,
    required this.hint,
    required this.replaceLabel,
    required this.galleryLabel,
    required this.onCamera,
    required this.onGallery,
  });
  final String? imagePath;
  final String hint;
  final String replaceLabel;
  final String galleryLabel;
  final VoidCallback onCamera;
  final VoidCallback onGallery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasImage = imagePath != null && File(imagePath!).existsSync();
    return Column(
      children: [
        GestureDetector(
          onTap: onCamera,
          child: ClipRRect(
            borderRadius:
                BorderRadius.circular(AppConstants.radiusLarge),
            child: Container(
              height: 200,
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
              child: hasImage
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(File(imagePath!), fit: BoxFit.cover),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            color: Colors.black54,
                            child: Text(
                              replaceLabel,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.camera_alt_rounded,
                            size: 48,
                            color: theme.colorScheme.outline
                                .withValues(alpha: 0.5)),
                        const SizedBox(height: 8),
                        Text(hint,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline),
                            textAlign: TextAlign.center),
                      ],
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: onGallery,
          icon: const Icon(Icons.photo_library_outlined, size: 16),
          label: Text(galleryLabel,
              style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}

// ── Reference image list ─────────────────────────────────────────────────────

class _ReferenceImageList extends StatelessWidget {
  const _ReferenceImageList(
      {required this.paths, required this.onRemove});
  final List<String> paths;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 90,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: paths.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final path = paths[i];
          final exists = File(path).existsSync();
          return Stack(
            children: [
              ClipRRect(
                borderRadius:
                    BorderRadius.circular(AppConstants.radiusMedium),
                child: SizedBox(
                  width: 90,
                  height: 90,
                  child: exists
                      ? Image.file(File(path), fit: BoxFit.cover)
                      : Container(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: GestureDetector(
                  onTap: () => onRemove(path),
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close_rounded,
                        size: 16, color: Colors.white),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Add reference buttons ────────────────────────────────────────────────────

class _AddReferenceButtons extends StatelessWidget {
  const _AddReferenceButtons({
    required this.addLabel,
    required this.galleryLabel,
    required this.onCamera,
    required this.onGallery,
  });
  final String addLabel;
  final String galleryLabel;
  final VoidCallback onCamera;
  final VoidCallback onGallery;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onCamera,
            icon: const Icon(Icons.add_a_photo_outlined, size: 18),
            label: Text(addLabel, style: const TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 10)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onGallery,
            icon: const Icon(Icons.photo_library_outlined, size: 18),
            label: Text(galleryLabel, style: const TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 10)),
          ),
        ),
      ],
    );
  }
}

// ── Web enrichment panel ─────────────────────────────────────────────────────

class _WebEnrichmentPanel extends StatelessWidget {
  const _WebEnrichmentPanel({
    required this.isSearching,
    required this.imageUrls,
    required this.addedUrls,
    required this.nameIsEmpty,
    required this.searchLabel,
    required this.searchingLabel,
    required this.noResultsLabel,
    required this.tapHint,
    required this.onSearch,
    required this.onSelect,
  });
  final bool isSearching;
  final List<String> imageUrls;
  final Set<String> addedUrls;
  final bool nameIsEmpty;
  final String searchLabel;
  final String searchingLabel;
  final String noResultsLabel;
  final String tapHint;
  final VoidCallback onSearch;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: nameIsEmpty || isSearching ? null : onSearch,
          icon: isSearching
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.image_search_rounded, size: 18),
          label: Text(
            isSearching ? searchingLabel : searchLabel,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        if (imageUrls.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(tapHint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 8),
          SizedBox(
            height: 100,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: imageUrls.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final url = imageUrls[i];
                final added = addedUrls.contains(url);
                return GestureDetector(
                  onTap: added ? null : () => onSelect(url),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(
                            AppConstants.radiusMedium),
                        child: SizedBox(
                          width: 100,
                          height: 100,
                          child: Image.network(
                            url,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: theme
                                  .colorScheme.surfaceContainerHighest,
                              child: const Icon(
                                  Icons.broken_image_outlined),
                            ),
                          ),
                        ),
                      ),
                      if (added)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(
                              AppConstants.radiusMedium),
                          child: Container(
                            width: 100,
                            height: 100,
                            color: Colors.black45,
                            child: const Icon(Icons.check_circle_rounded,
                                color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ] else if (!isSearching && imageUrls.isEmpty && !nameIsEmpty) ...[
          // Only show no-results if a search was actually attempted
        ],
      ],
    );
  }
}

// ── Invoice capture widget ───────────────────────────────────────────────────

class _InvoiceCapture extends StatelessWidget {
  const _InvoiceCapture({
    required this.imagePath,
    required this.hint,
    required this.replaceLabel,
    required this.galleryLabel,
    required this.onCamera,
    required this.onGallery,
  });
  final String? imagePath;
  final String hint;
  final String replaceLabel;
  final String galleryLabel;
  final VoidCallback onCamera;
  final VoidCallback onGallery;

  @override
  Widget build(BuildContext context) {
    final hasImage = imagePath != null && File(imagePath!).existsSync();
    return Column(
      children: [
        GestureDetector(
          onTap: onCamera,
          child: ClipRRect(
            borderRadius:
                BorderRadius.circular(AppConstants.radiusLarge),
            child: Container(
              height: 220,
              width: double.infinity,
              color: Colors.black87,
              child: hasImage
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(File(imagePath!), fit: BoxFit.contain),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            color: Colors.black54,
                            child: Text(
                              replaceLabel,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.receipt_long_rounded,
                            size: 56, color: Colors.white54),
                        const SizedBox(height: 10),
                        Text(hint,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13),
                            textAlign: TextAlign.center),
                      ],
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: onGallery,
          icon: const Icon(Icons.photo_library_outlined, size: 16),
          label: Text(galleryLabel,
              style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}

// ── Line item tile ───────────────────────────────────────────────────────────

class _LineItemTile extends StatelessWidget {
  const _LineItemTile({
    required this.item,
    required this.index,
    required this.tr,
    required this.onRemove,
  });
  final _LineItem item;
  final int index;
  final AppTranslations tr;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('$index.',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.outline)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: onRemove,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                style: IconButton.styleFrom(
                  foregroundColor: AppColors.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: item.name,
            decoration: InputDecoration(
              labelText: tr.productName,
              hintText: tr.lineItemNameHint,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: item.qty,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: tr.quantity,
                    hintText: '1',
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: item.price,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: tr.sellingPrice,
                    hintText: '0.00',
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
