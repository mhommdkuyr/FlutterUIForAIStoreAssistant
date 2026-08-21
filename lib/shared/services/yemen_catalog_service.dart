import 'dart:convert';

import 'package:flutter/services.dart';

class YemenCatalogItem {
  const YemenCatalogItem({
    required this.id,
    required this.nameAr,
    required this.brand,
    required this.category,
    required this.packSize,
    required this.source,
    required this.sourceUrl,
    required this.imageUrls,
    this.barcode,
    this.recognitionReady = false,
  });

  final String id;
  final String nameAr;
  final String brand;
  final String category;
  final String packSize;
  final String source;
  final String sourceUrl;
  final List<String> imageUrls;
  final String? barcode;
  final bool recognitionReady;

  bool get hasReferenceImage => imageUrls.any((url) => url.trim().isNotEmpty);

  factory YemenCatalogItem.fromJson(Map<String, dynamic> json) {
    final rawImages = json['imageUrls'];
    final images = rawImages is List
        ? rawImages.whereType<String>().toList(growable: false)
        : const <String>[];
    return YemenCatalogItem(
      id: json['id'] as String,
      nameAr: (json['nameAr'] as String? ?? '').trim(),
      brand: (json['brand'] as String? ?? '').trim(),
      category: (json['category'] as String? ?? '').trim(),
      packSize: (json['packSize'] as String? ?? '').trim(),
      source: (json['source'] as String? ?? '').trim(),
      sourceUrl: (json['sourceUrl'] as String? ?? '').trim(),
      imageUrls: images,
      barcode: (json['barcode'] as String?)?.trim(),
      recognitionReady: json['recognitionReady'] == true,
    );
  }
}

class YemenCatalogService {
  static const generatedAssetPath =
      'assets/generated/yemen_food_catalog_3000.json';
  static const assetPath = 'data/yemen_food_catalog_seed.json';
  static const trainedAdditionsAssetPath =
      'data/yemen_food_catalog_trained_additions.json';

  Future<List<YemenCatalogItem>> load() async {
    try {
      final raw = await rootBundle.loadString(generatedAssetPath);
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded['products'] is List) {
        return (decoded['products'] as List)
            .whereType<Map<String, dynamic>>()
            .map(YemenCatalogItem.fromJson)
            .where((p) => p.nameAr.isNotEmpty)
            .toList(growable: false);
      }
    } catch (_) {
      // The generated 3000-SKU asset is produced in CI/release builds.
      // Local development falls back to the deterministic seed catalog.
    }

    final docs = await Future.wait([
      rootBundle.loadString(assetPath),
      rootBundle.loadString(trainedAdditionsAssetPath),
    ]);
    final merged = <String, YemenCatalogItem>{};
    for (final raw in docs) {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid Yemen catalog root object.');
      }
      final products = decoded['products'];
      if (products is! List) {
        throw const FormatException('Yemen catalog products array is missing.');
      }
      for (final json in products.whereType<Map<String, dynamic>>()) {
        final item = YemenCatalogItem.fromJson(json);
        if (item.nameAr.isNotEmpty) merged[item.id] = item;
      }
    }
    return merged.values.toList(growable: false);
  }

  List<YemenCatalogItem> filter(
    Iterable<YemenCatalogItem> source, {
    String query = '',
    String? category,
  }) {
    final q = query.trim().toLowerCase();
    return source.where((item) {
      if (category != null && category.isNotEmpty && item.category != category) {
        return false;
      }
      if (q.isEmpty) return true;
      final haystack =
          '${item.nameAr} ${item.brand} ${item.category} ${item.packSize}'
              .toLowerCase();
      return haystack.contains(q);
    }).toList(growable: false);
  }
}