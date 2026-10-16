import 'dart:math' as math;
import '../models/market_models.dart';
import 'market_backend.dart';

class MarketRepository {
  MarketRepository({MarketBackend? backend})
      : _backend = backend ?? MarketBackend.instance;

  final MarketBackend _backend;

  Future<List<MarketOffer>> search({
    required double latitude,
    required double longitude,
    double radiusKm = 5,
    String? query,
    String? category,
  }) async {
    if (_backend.isConfigured) {
      final rows = await _backend.callRpc('search_market_products', {
        'p_lat': latitude,
        'p_lon': longitude,
        'p_radius_km': radiusKm,
        'p_query': query?.trim().isEmpty == true ? null : query?.trim(),
        'p_category': category?.trim().isEmpty == true ? null : category?.trim(),
      });
      return rows.map(MarketOffer.fromJson).toList(growable: false);
    }

    final q = query?.trim().toLowerCase();
    final c = category?.trim().toLowerCase();
    return _demoOffers
        .map((offer) => offer.copyWith(
              distanceKm: haversineKm(
                latitude,
                longitude,
                offer.store.latitude,
                offer.store.longitude,
              ),
            ))
        .where((offer) => (offer.distanceKm ?? 999) <= radiusKm)
        .where((offer) {
          final name = (
            offer.product.nameAr +
            ' ' +
            (offer.product.nameEn ?? '') +
            ' ' +
            (offer.product.brand ?? '')
          ).toLowerCase();
          final matchesQuery = q == null || q.isEmpty || name.contains(q);
          final matchesCategory = c == null ||
              c.isEmpty ||
              (offer.product.category ?? '').toLowerCase() == c;
          return matchesQuery && matchesCategory;
        })
        .toList()
      ..sort((a, b) {
        final d = (a.distanceKm ?? 999).compareTo(b.distanceKm ?? 999);
        return d == 0 ? a.price.compareTo(b.price) : d;
      });
  }

  static double haversineKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371.0088;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.pow(math.sin(dLon / 2), 2);
    return 2 * r *
        math.atan2(math.sqrt(a.toDouble()), math.sqrt(1 - a.toDouble()));
  }

  static const _demoOffers = <MarketOffer>[
    MarketOffer(
      id: 'demo-1',
      store: MarketStore(
        id: 'demo-store-1',
        nameAr: 'متجر إب المركزي',
        phone: '770000001',
        whatsapp: '770000001',
        address: 'وسط مدينة إب',
        latitude: 13.9668,
        longitude: 44.1836,
        verified: true,
      ),
      product: MarketProduct(
        id: 'demo-product-1',
        nameAr: 'أرز بسمتي 5 كجم',
        nameEn: 'Basmati Rice 5kg',
        category: 'أغذية',
      ),
      price: 9200,
    ),
    MarketOffer(
      id: 'demo-2',
      store: MarketStore(
        id: 'demo-store-2',
        nameAr: 'بقالة شارع تعز',
        phone: '770000002',
        address: 'شارع تعز، إب',
        latitude: 13.9582,
        longitude: 44.1747,
      ),
      product: MarketProduct(
        id: 'demo-product-1',
        nameAr: 'أرز بسمتي 5 كجم',
        nameEn: 'Basmati Rice 5kg',
        category: 'أغذية',
      ),
      price: 8950,
    ),
  ];
}
