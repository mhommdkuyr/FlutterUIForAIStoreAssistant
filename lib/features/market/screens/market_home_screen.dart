import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/market_models.dart';
import '../services/market_location_service.dart';
import '../services/market_repository.dart';
import '../widgets/osm_map_view.dart';

class MarketHomeScreen extends StatefulWidget {
  const MarketHomeScreen({super.key});

  @override
  State<MarketHomeScreen> createState() => _MarketHomeScreenState();
}

class _MarketHomeScreenState extends State<MarketHomeScreen> {
  static const _defaultLat = 13.9667;
  static const _defaultLon = 44.1833;

  final _search = TextEditingController();
  final _repo = MarketRepository();
  final _location = MarketLocationService();

  double _lat = _defaultLat;
  double _lon = _defaultLon;
  double _radius = 5;
  String? _category;
  List<MarketOffer> _offers = const [];
  bool _loading = true;

  static const _cats = [
    'أغذية',
    'مشروبات',
    'صحة',
    'منزلية',
    'إلكترونيات',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await _repo.search(
        latitude: _lat,
        longitude: _lon,
        radiusKm: _radius,
        query: _search.text,
        category: _category,
      );
      if (mounted) setState(() => _offers = rows);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر تحميل السوق الآن.')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _gps() async {
    final position = await _location.currentPosition();
    if (!mounted) return;
    if (position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('فعّل الموقع وإذن الوصول إلى الموقع من إعدادات الهاتف.'),
        ),
      );
      return;
    }
    setState(() {
      _lat = position.latitude;
      _lon = position.longitude;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final stores = <String, MarketStore>{};
    for (final offer in _offers) {
      stores[offer.store.id] = offer.store;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('محرك السوق اليمني'),
        actions: [
          IconButton(
            onPressed: _gps,
            icon: const Icon(Icons.my_location_rounded),
            tooltip: 'استخدم موقعي',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'ابحث عن منتج أو متجر قريب منك',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                hintText: 'أرز، حليب، صيدلية...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                  onPressed: _load,
                  icon: const Icon(Icons.search),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilterChip(
                  label: Text(_radius.toString() + ' كم'),
                  selected: false,
                  onSelected: (_) => _selectRadius(),
                ),
                ..._cats.map(
                  (cat) => FilterChip(
                    label: Text(cat),
                    selected: _category == cat,
                    onSelected: (_) {
                      setState(
                        () => _category = _category == cat ? null : cat,
                      );
                      _load();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 270,
              child: OsmMapView(
                latitude: _lat,
                longitude: _lon,
                stores: stores.values.toList(growable: false),
                onStoreTap: _openStore,
              ),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_offers.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Text('لا توجد نتائج ضمن النطاق الحالي.'),
                ),
              )
            else
              ..._offers.map(
                (offer) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    onTap: () => _openStore(offer.store),
                    leading: const CircleAvatar(
                      child: Icon(Icons.storefront_rounded),
                    ),
                    title: Text(offer.product.nameAr),
                    subtitle: Text(
                      offer.store.nameAr +
                          ' • ' +
                          (offer.distanceKm == null
                              ? '—'
                              : offer.distanceKm!.toStringAsFixed(1)) +
                          ' كم • ' +
                          (offer.available ? 'متوفر' : 'غير متوفر'),
                    ),
                    trailing: Text(
                      offer.price.toStringAsFixed(0) +
                          ' ' +
                          offer.currency,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectRadius() async {
    final value = await showModalBottomSheet<double>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [1, 2, 5, 10, 20]
              .map(
                (km) => ListTile(
                  title: Text(km.toString() + ' كم'),
                  onTap: () => Navigator.pop(context, km.toDouble()),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (value == null) return;
    setState(() => _radius = value);
    await _load();
  }

  void _openStore(MarketStore store) {
    final offers = _offers.where((o) => o.store.id == store.id).toList();
    context.push('/market/store', extra: {'store': store, 'offers': offers});
  }
}
