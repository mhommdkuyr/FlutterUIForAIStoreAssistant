import 'package:flutter/material.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/repositories/product_repository.dart';
import '../../../shared/services/yemen_catalog_embedding_service.dart';
import '../../../shared/services/yemen_catalog_image_hydration_service.dart';
import '../../../shared/services/yemen_catalog_service.dart';

class YemenCatalogScreen extends StatefulWidget {
  const YemenCatalogScreen({super.key});

  @override
  State<YemenCatalogScreen> createState() => _YemenCatalogScreenState();
}

class _YemenCatalogScreenState extends State<YemenCatalogScreen> {
  final _catalogService = YemenCatalogService();
  final _repository = ProductRepository();
  final _imageHydrator = YemenCatalogImageHydrationService();
  final _embeddingInstaller = YemenCatalogEmbeddingService();
  final _searchController = TextEditingController();

  List<YemenCatalogItem> _items = const [];
  String? _category;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _catalogService.load();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  List<YemenCatalogItem> get _filtered => _catalogService.filter(
        _items,
        query: _searchController.text,
        category: _category,
      );

  List<String> get _categories {
    final values = _items
        .map((e) => e.category)
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return values;
  }

  Future<void> _select(YemenCatalogItem item) async {
    final result = await showModalBottomSheet<_CatalogFormResult>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CatalogForm(item: item),
    );
    if (result == null) return;

    try {
      String? localReferencePath;
      if (!item.recognitionReady && item.hasReferenceImage) {
        localReferencePath = await _imageHydrator.hydrate(
          catalogId: item.id,
          imageUrls: item.imageUrls,
        );
      }

      final product = await _repository.createProduct(
        name: item.nameAr,
        category: item.category.isEmpty ? 'مواد غذائية' : item.category,
        purchasePrice: result.purchasePrice,
        sellingPrice: result.sellingPrice,
        quantity: result.quantity,
        barcode: item.barcode,
        imageUrl: localReferencePath,
        description:
            'catalogId=${item.id}; brand=${item.brand}; packSize=${item.packSize}; source=${item.source}; sourceUrl=${item.sourceUrl}; recognitionReady=${item.recognitionReady}',
      );

      final trainedInstalled = item.recognitionReady
          ? await _embeddingInstaller.install(
              productId: product.id,
              catalogId: item.id,
            )
          : false;

      if (!mounted) return;
      final message = trainedInstalled
          ? 'تمت إضافة ${item.nameAr}؛ المرجع البصري المدرب جاهز للمسح.'
          : 'تمت إضافة ${item.nameAr} إلى منتجات المتجر.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تعذر إضافة المنتج: $error'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories;
    return Scaffold(
      appBar: AppBar(title: const Text('كتالوج المنتجات اليمنية')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(AppConstants.paddingMD),
                          child: Column(
                            children: [
                              TextField(
                                controller: _searchController,
                                onChanged: (_) => setState(() {}),
                                decoration: InputDecoration(
                                  hintText: 'ابحث باسم المنتج أو العلامة أو الحجم',
                                  prefixIcon: const Icon(Icons.search_rounded),
                                  suffixIcon: _searchController.text.isEmpty
                                      ? null
                                      : IconButton(
                                          onPressed: () {
                                            _searchController.clear();
                                            setState(() {});
                                          },
                                          icon: const Icon(Icons.clear_rounded),
                                        ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                height: 42,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: categories.length + 1,
                                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                                  itemBuilder: (context, index) {
                                    final label = index == 0 ? 'الكل' : categories[index - 1];
                                    final selected = index == 0 ? _category == null : _category == label;
                                    return FilterChip(
                                      selected: selected,
                                      label: Text(label),
                                      onSelected: (_) => setState(() {
                                        _category = index == 0 ? null : label;
                                      }),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 10),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
                                ),
                                child: const Text(
                                  'اختر المنتج ثم أدخل سعر الشراء والبيع والكمية. المنتجات المدربة تُثبت هويتها البصرية مسبقًا؛ المنتجات الجديدة يمكن إضافتها بالتصوير.',
                                  textDirection: TextDirection.rtl,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(AppConstants.paddingMD, 0, AppConstants.paddingMD, 24),
                        sliver: SliverList.builder(
                          itemCount: _filtered.length,
                          itemBuilder: (context, index) {
                            final item = _filtered[index];
                            final ready = item.recognitionReady;
                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: AppColors.primary.withOpacity(0.1),
                                  child: const Icon(Icons.inventory_2_outlined),
                                ),
                                title: Text(item.nameAr, textDirection: TextDirection.rtl),
                                subtitle: Text(
                                  [item.brand, item.packSize, item.category]
                                      .where((e) => e.isNotEmpty)
                                      .join(' • '),
                                  textDirection: TextDirection.rtl,
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      ready ? 'مدرب — جاهز للمسح' : 'غير مدرب — تصوير عند الحاجة',
                                      style: TextStyle(
                                        color: ready ? AppColors.success : AppColors.warning,
                                        fontSize: 11,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    const Icon(Icons.chevron_left_rounded),
                                  ],
                                ),
                                onTap: () => _select(item),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _CatalogFormResult {
  const _CatalogFormResult({
    required this.purchasePrice,
    required this.sellingPrice,
    required this.quantity,
  });

  final double purchasePrice;
  final double sellingPrice;
  final int quantity;
}

class _CatalogForm extends StatefulWidget {
  const _CatalogForm({required this.item});
  final YemenCatalogItem item;

  @override
  State<_CatalogForm> createState() => _CatalogFormState();
}

class _CatalogFormState extends State<_CatalogForm> {
  final _formKey = GlobalKey<FormState>();
  final _purchase = TextEditingController();
  final _selling = TextEditingController();
  final _quantity = TextEditingController(text: '1');

  @override
  void dispose() {
    _purchase.dispose();
    _selling.dispose();
    _quantity.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(
      context,
      _CatalogFormResult(
        purchasePrice: double.parse(_purchase.text),
        sellingPrice: double.parse(_selling.text),
        quantity: int.parse(_quantity.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + viewInsets.bottom),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.item.nameAr, style: Theme.of(context).textTheme.titleMedium, textDirection: TextDirection.rtl),
            const SizedBox(height: 4),
            Text(
              [widget.item.brand, widget.item.packSize, widget.item.category].where((e) => e.isNotEmpty).join(' • '),
              textDirection: TextDirection.rtl,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _purchase,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'سعر الشراء بالريال اليمني'),
              validator: (v) => double.tryParse(v ?? '') == null ? 'أدخل سعرًا صحيحًا' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _selling,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'سعر البيع بالريال اليمني'),
              validator: (v) => double.tryParse(v ?? '') == null ? 'أدخل سعرًا صحيحًا' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _quantity,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'الكمية الافتتاحية'),
              validator: (v) {
                final value = int.tryParse(v ?? '');
                return value == null || value < 0 ? 'أدخل كمية صحيحة' : null;
              },
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.add_rounded),
              label: const Text('إضافة إلى المتجر'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 48),
            const SizedBox(height: 12),
            const Text('تعذر تحميل كتالوج المنتجات', textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('إعادة المحاولة')),
          ],
        ),
      ),
    );
  }
}
