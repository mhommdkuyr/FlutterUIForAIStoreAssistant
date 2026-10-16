class MarketStore {
  final String id;
  final String nameAr;
  final String? nameEn;
  final String? phone;
  final String? whatsapp;
  final String? address;
  final String city;
  final double latitude;
  final double longitude;
  final bool verified;
  final String? source;
  final DateTime? lastDataRefresh;

  const MarketStore({
    required this.id,
    required this.nameAr,
    this.nameEn,
    this.phone,
    this.whatsapp,
    this.address,
    this.city = 'إب',
    required this.latitude,
    required this.longitude,
    this.verified = false,
    this.source,
    this.lastDataRefresh,
  });

  factory MarketStore.fromJson(Map<String, dynamic> json) => MarketStore(
        id: (json['store_id'] ?? json['id'] ?? '').toString(),
        nameAr: (json['store_name_ar'] ?? json['name_ar'] ?? '').toString(),
        nameEn: json['store_name_en']?.toString() ?? json['name_en']?.toString(),
        phone: json['phone']?.toString(),
        whatsapp: json['whatsapp']?.toString(),
        address: json['address']?.toString(),
        city: (json['city'] ?? 'إب').toString(),
        latitude: _double(json['latitude'] ?? json['lat']),
        longitude: _double(json['longitude'] ?? json['lon']),
        verified: json['verified'] as bool? ?? false,
        source: json['source']?.toString(),
        lastDataRefresh: _date(json['last_data_refresh']),
      );
}

class MarketProduct {
  final String id;
  final String nameAr;
  final String? nameEn;
  final String? brand;
  final String? category;
  final String? barcode;
  final String? descriptionAr;
  final String? imageUrl;
  final String? imageLicense;
  final String? imageAttribution;

  const MarketProduct({
    required this.id,
    required this.nameAr,
    this.nameEn,
    this.brand,
    this.category,
    this.barcode,
    this.descriptionAr,
    this.imageUrl,
    this.imageLicense,
    this.imageAttribution,
  });

  factory MarketProduct.fromJson(Map<String, dynamic> json) => MarketProduct(
        id: (json['product_id'] ?? json['id'] ?? '').toString(),
        nameAr: (json['product_name_ar'] ?? json['name_ar'] ?? '').toString(),
        nameEn: json['product_name_en']?.toString() ?? json['name_en']?.toString(),
        brand: json['brand']?.toString(),
        category: json['category']?.toString(),
        barcode: json['barcode']?.toString(),
        descriptionAr: json['description_ar']?.toString(),
        imageUrl: json['image_url']?.toString(),
        imageLicense: json['image_license']?.toString(),
        imageAttribution: json['image_attribution']?.toString(),
      );
}

class MarketOffer {
  final String id;
  final MarketStore store;
  final MarketProduct product;
  final double price;
  final String currency;
  final bool available;
  final double? quantity;
  final DateTime? lastCheckedAt;
  final double? distanceKm;

  const MarketOffer({
    required this.id,
    required this.store,
    required this.product,
    required this.price,
    this.currency = 'YER',
    this.available = true,
    this.quantity,
    this.lastCheckedAt,
    this.distanceKm,
  });

  MarketOffer copyWith({double? distanceKm}) => MarketOffer(
        id: id,
        store: store,
        product: product,
        price: price,
        currency: currency,
        available: available,
        quantity: quantity,
        lastCheckedAt: lastCheckedAt,
        distanceKm: distanceKm ?? this.distanceKm,
      );

  factory MarketOffer.fromJson(Map<String, dynamic> json) => MarketOffer(
        id: (json['offer_id'] ?? json['id'] ?? '').toString(),
        store: MarketStore.fromJson(json),
        product: MarketProduct.fromJson(json),
        price: _double(json['price']),
        currency: (json['currency'] ?? 'YER').toString(),
        available: json['available'] as bool? ?? true,
        quantity: json['quantity'] == null ? null : _double(json['quantity']),
        lastCheckedAt: _date(json['last_checked_at']),
        distanceKm: json['distance_km'] == null ? null : _double(json['distance_km']),
      );
}

double _double(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

DateTime? _date(Object? value) {
  final text = value?.toString();
  return text == null || text.isEmpty ? null : DateTime.tryParse(text);
}
