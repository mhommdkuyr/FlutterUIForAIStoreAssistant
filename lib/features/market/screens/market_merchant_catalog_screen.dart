import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/services/auth_service.dart';
import '../models/market_models.dart';
import '../services/market_backend.dart';
import '../services/market_import_service.dart';
import '../services/market_location_service.dart';

class MarketMerchantCatalogScreen extends StatefulWidget {
  const MarketMerchantCatalogScreen({super.key});

  @override
  State<MarketMerchantCatalogScreen> createState() =>
      _MarketMerchantCatalogScreenState();
}

class _MarketMerchantCatalogScreenState
    extends State<MarketMerchantCatalogScreen> {
  final _backend = MarketBackend.instance;
  final _location = MarketLocationService();
  final _importer = const MarketImportService();

  MarketStore? _store;
  List<MarketOffer> _offers = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    if (!_backend.isConfigured) {
      setState(() {
        _loading = false;
        _error =
            'اربط التطبيق بـ Supabase أولًا عبر SUPABASE_URL وSUPABASE_PUBLISHABLE_KEY.';
      });
      return;
    }

    try {
      final storeRows = await _backend.callRpc('merchant_get_store', {});
      _store = storeRows.isEmpty
          ? null
          : MarketStore.fromJson(storeRows.first);
      if (_store != null) {
        final rows = await _backend.callRpc('merchant_get_catalog', {});
        _offers = rows.map(MarketOffer.fromJson).toList(growable: false);
      }
    } catch (error) {
      _error = 'تعذر تحميل الكتالوج: ' + error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveStore({
    String? nameAr,
    String? phone,
    String? whatsapp,
    String? address,
    double? latitude,
    double? longitude,
  }) async {
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final rows = await _backend.callRpc(
        'merchant_create_or_update_store',
        {
          'p_store_id': _store?.id,
          'p_name_ar': nameAr ?? _store?.nameAr ?? '',
          'p_phone': phone ?? _store?.phone,
          'p_whatsapp': whatsapp ?? _store?.whatsapp,
          'p_address': address ?? _store?.address,
          'p_lat': latitude ?? _store?.latitude,
          'p_lon': longitude ?? _store?.longitude,
        },
      );
      if (rows.isNotEmpty) _store = MarketStore.fromJson(rows.first);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ ملف المتجر.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حفظ المتجر: ' + error.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setLocation() async {
    final position = await _location.currentPosition();
    if (position == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('فعّل الموقع وأذونات الموقع أولًا.')),
      );
      return;
    }

    await _saveStore(
      latitude: position.latitude,
      longitude: position.longitude,
    );
  }

  Future<void> _showStoreEditor() async {
    final store = _store;
    final name = TextEditingController(text: store?.nameAr ?? '');
    final phone = TextEditingController(text: store?.phone ?? '');
    final whatsapp = TextEditingController(text: store?.whatsapp ?? '');
    final address = TextEditingController(text: store?.address ?? '');
    final key = GlobalKey<FormState>();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          MediaQuery.viewInsetsOf(sheetContext).bottom + 16,
        ),
        child: Form(
          key: key,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ملف المتجر',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: name,
                  decoration:
                      const InputDecoration(labelText: 'اسم المتجر *'),
                  validator: (value) =>
                      value == null || value.trim().isEmpty
                          ? 'اسم المتجر مطلوب'
                          : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: phone,
                  decoration: const InputDecoration(labelText: 'الهاتف'),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: whatsapp,
                  decoration: const InputDecoration(labelText: 'واتساب'),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: address,
                  decoration: const InputDecoration(labelText: 'العنوان'),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _saving
                            ? null
                            : () async {
                                if (!(key.currentState?.validate() ?? false)) {
                                  return;
                                }
                                await _saveStore(
                                  nameAr: name.text.trim(),
                                  phone: _nullable(phone.text),
                                  whatsapp: _nullable(whatsapp.text),
                                  address: _nullable(address.text),
                                );
                                if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                              },
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('حفظ'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _saving
                          ? null
                          : () async {
                              if (!(key.currentState?.validate() ?? false)) {
                                return;
                              }
                              final position =
                                  await _location.currentPosition();
                              if (position == null) return;
                              await _saveStore(
                                nameAr: name.text.trim(),
                                phone: _nullable(phone.text),
                                whatsapp: _nullable(whatsapp.text),
                                address: _nullable(address.text),
                                latitude: position.latitude,
                                longitude: position.longitude,
                              );
                              if (sheetContext.mounted) {
                                Navigator.pop(sheetContext);
                              }
                            },
                      icon: const Icon(Icons.my_location_rounded),
                      tooltip: 'حفظ الملف والموقع الحالي',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    name.dispose();
    phone.dispose();
    whatsapp.dispose();
    address.dispose();
  }

  Future<void> _showProductEditor({MarketOffer? initial}) async {
    if (_store == null) {
      await _showStoreEditor();
      if (_store == null) return;
    }

    final offer = initial;
    final nameAr = TextEditingController(text: offer?.product.nameAr ?? '');
    final nameEn = TextEditingController(text: offer?.product.nameEn ?? '');
    final brand = TextEditingController(text: offer?.product.brand ?? '');
    final category =
        TextEditingController(text: offer?.product.category ?? 'أغذية');
    final barcode = TextEditingController(text: offer?.product.barcode ?? '');
    final price =
        TextEditingController(text: offer?.price.toStringAsFixed(0) ?? '');
    final quantity =
        TextEditingController(text: offer?.quantity?.toString() ?? '');
    final formKey = GlobalKey<FormState>();
    var available = offer?.available ?? true;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            MediaQuery.viewInsetsOf(sheetContext).bottom + 16,
          ),
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    initial == null
                        ? 'إضافة منتج للسوق'
                        : 'تعديل عرض المنتج',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: nameAr,
                    decoration:
                        const InputDecoration(labelText: 'اسم المنتج *'),
                    validator: (value) =>
                        value == null || value.trim().isEmpty
                            ? 'اسم المنتج مطلوب'
                            : null,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameEn,
                    decoration: const InputDecoration(labelText: 'English'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: brand,
                    decoration:
                        const InputDecoration(labelText: 'العلامة التجارية'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: category,
                    decoration: const InputDecoration(labelText: 'التصنيف'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: barcode,
                    decoration: const InputDecoration(labelText: 'الباركود'),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: price,
                    decoration: const InputDecoration(
                      labelText: 'السعر بالريال اليمني *',
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    validator: (value) {
                      final parsed = double.tryParse(value?.trim() ?? '');
                      return parsed == null || parsed < 0
                          ? 'أدخل سعرًا صحيحًا'
                          : null;
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: quantity,
                    decoration: const InputDecoration(labelText: 'الكمية'),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('متوفر للبيع'),
                    value: available,
                    onChanged: (value) =>
                        setSheetState(() => available = value),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _saving
                        ? null
                        : () async {
                            if (!(formKey.currentState?.validate() ?? false)) {
                              return;
                            }
                            setState(() => _saving = true);
                            try {
                              await _backend.callRpc(
                                'merchant_upsert_offer',
                                {
                                  'p_store_id': _store!.id,
                                  'p_product_id': offer?.product.id,
                                  'p_name_ar': nameAr.text.trim(),
                                  'p_name_en': _nullable(nameEn.text),
                                  'p_brand': _nullable(brand.text),
                                  'p_category': _nullable(category.text),
                                  'p_barcode': _nullable(barcode.text),
                                  'p_price':
                                      double.parse(price.text.trim()),
                                  'p_quantity': _doubleOrNull(quantity.text),
                                  'p_available': available,
                                },
                              );
                              if (!mounted) return;
                              Navigator.pop(sheetContext);
                              await _load();
                            } catch (error) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'تعذر حفظ المنتج: ' +
                                          error.toString(),
                                    ),
                                  ),
                                );
                              }
                            } finally {
                              if (mounted) setState(() => _saving = false);
                            }
                          },
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('حفظ المنتج'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    nameAr.dispose();
    nameEn.dispose();
    brand.dispose();
    category.dispose();
    barcode.dispose();
    price.dispose();
    quantity.dispose();
  }

  Future<void> _import() async {
    if (_store == null) {
      await _showStoreEditor();
      if (_store == null) return;
    }

    final result = await _importer.pickAndParse();
    if (result == null) return;

    if (result.rows.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.errors.join('
'))),
      );
      return;
    }

    setState(() => _saving = true);
    var imported = 0;
    final errors = <String>[...result.errors];

    for (final row in result.rows) {
      try {
        await _backend.callRpc('merchant_upsert_offer', {
          'p_store_id': _store!.id,
          'p_name_ar': row.nameAr,
          'p_name_en': row.nameEn,
          'p_brand': row.brand,
          'p_category': row.category,
          'p_barcode': row.barcode,
          'p_price': row.price ?? 0,
          'p_quantity': row.quantity,
          'p_available': row.available,
        });
        imported++;
      } catch (error) {
        errors.add(row.nameAr + ': ' + error.toString());
      }
    }

    if (!mounted) return;
    await _load();
    if (!mounted) return;
    setState(() => _saving = false);

    final suffix =
        errors.isEmpty ? '' : ' — أخطاء: ' + errors.length.toString();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'تم استيراد ' +
              imported.toString() +
              ' منتجًا من ' +
              result.fileName +
              suffix,
        ),
      ),
    );
  }

  String? _nullable(String value) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  double? _doubleOrNull(String value) {
    final text = value.trim();
    return text.isEmpty ? null : double.tryParse(text);
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.currentUser;
    return Scaffold(
      appBar: AppBar(
        title: const Text('كتالوج المتجر'),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: _store == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _saving ? null : () => _showProductEditor(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('منتج'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppConstants.paddingMD),
              children: [
                if (user != null)
                  Text(
                    'حساب التاجر: ' + user.fullName,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                if (_error != null)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('الإعداد غير مكتمل'),
                      subtitle: Text(_error!),
                    ),
                  ),
                if (_store == null && _error == null)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.store_outlined),
                      title: const Text('أنشئ ملف متجرك'),
                      subtitle: const Text(
                        'أدخل اسم المتجر ثم احفظ الموقع من GPS لإظهاره على خريطة السوق.',
                      ),
                      trailing: FilledButton(
                        onPressed: _showStoreEditor,
                        child: const Text('إنشاء'),
                      ),
                    ),
                  ),
                if (_store != null) ...[
                  Card(
                    child: ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.storefront_rounded),
                      ),
                      title: Text(_store!.nameAr),
                      subtitle: Text(
                        _store!.address ??
                            'الموقع محفوظ في قاعدة بيانات السوق',
                      ),
                      trailing: IconButton(
                        onPressed: _showStoreEditor,
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: _saving ? null : _setLocation,
                    icon: const Icon(Icons.location_on_outlined),
                    label: const Text('تحديث موقع المتجر من GPS'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _import,
                    icon: const Icon(Icons.file_upload_outlined),
                    label: const Text('استيراد CSV أو JSON'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'العروض الحالية (' + _offers.length.toString() + ')',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  if (_offers.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('لا توجد منتجات منشورة حتى الآن.'),
                      ),
                    )
                  else
                    ..._offers.map(
                      (offer) => Card(
                        child: ListTile(
                          onTap: () => _showProductEditor(initial: offer),
                          leading:
                              const Icon(Icons.inventory_2_outlined),
                          title: Text(offer.product.nameAr),
                          subtitle: Text(
                            (offer.product.category ?? 'بدون تصنيف') +
                                ' • ' +
                                (offer.available
                                    ? 'متوفر'
                                    : 'غير متوفر') +
                                ' • ' +
                                _freshness(offer.lastCheckedAt),
                          ),
                          trailing: Text(
                            offer.price.toStringAsFixed(0) +
                                ' ' +
                                offer.currency,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
    );
  }

  String _freshness(DateTime? checkedAt) {
    if (checkedAt == null) return 'غير معروف';
    final age = DateTime.now().difference(checkedAt.toLocal());
    if (age.inHours < 24) return 'محدث اليوم';
    if (age.inDays < 7) {
      return 'منذ ' + age.inDays.toString() + ' يوم';
    }
    return 'قديم — يحتاج تحديث';
  }
}
