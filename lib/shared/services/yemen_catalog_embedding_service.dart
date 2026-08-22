import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'embedding_persistence_service.dart';

class YemenCatalogEmbeddingService {
  static const centroidsAsset =
      'assets/generated/yemen_food_catalog_centroids.f16';
  static const labelsAsset =
      'assets/generated/yemen_food_catalog_labels.json';
  static const modelVersion = 'mobileclip2_s0_vision_onnx_v1';

  YemenCatalogEmbeddingService({EmbeddingPersistenceService? persistence})
      : _persistence = persistence ?? EmbeddingPersistenceService();

  final EmbeddingPersistenceService _persistence;
  Map<String, int>? _labelIndex;
  ByteData? _centroids;

  Future<void> _ensureLoaded() async {
    if (_labelIndex != null && _centroids != null) return;
    final labelsRaw = await rootBundle.loadString(labelsAsset);
    final labels = (jsonDecode(labelsRaw) as List).cast<String>();
    final data = await rootBundle.load(centroidsAsset);
    if (data.lengthInBytes != labels.length * 512 * 2) {
      throw StateError(
        'Invalid Yemen catalog centroid asset: ${data.lengthInBytes} bytes for ${labels.length} labels.',
      );
    }
    _labelIndex = {
      for (var i = 0; i < labels.length; i++) labels[i]: i,
    };
    _centroids = data;
  }

  Future<bool> install({
    required String productId,
    required String catalogId,
  }) async {
    try {
      await _ensureLoaded();
      final index = _labelIndex?[catalogId];
      final data = _centroids;
      if (index == null || data == null) return false;
      final base = data.offsetInBytes + index * 512 * 2;
      final floats = Float32List(512);
      for (var i = 0; i < 512; i++) {
        floats[i] = _halfToFloat(data.getUint16(base + i * 2, Endian.little));
      }
      await _persistence.save(
        productId: productId,
        imagePath: 'catalog://$catalogId',
        embedding: floats.buffer.asUint8List(),
        modelVersion: modelVersion,
      );
      return true;
    } catch (_) {
      // Local/debug builds may not carry the generated asset yet.
      return false;
    }
  }

  static double _halfToFloat(int h) {
    final sign = (h & 0x8000) == 0 ? 1.0 : -1.0;
    final exp = (h >> 10) & 0x1f;
    final frac = h & 0x03ff;
    if (exp == 0) {
      if (frac == 0) return sign * 0.0;
      return sign * (frac / 1024.0) * 0.00006103515625;
    }
    if (exp == 0x1f) {
      if (frac == 0) return sign * double.infinity;
      return double.nan;
    }
    return sign * (1.0 + frac / 1024.0) * _pow2(exp - 15);
  }

  static double _pow2(int e) {
    if (e == 0) return 1.0;
    var value = 1.0;
    if (e > 0) {
      for (var i = 0; i < e; i++) value *= 2.0;
    } else {
      for (var i = 0; i > e; i--) value *= 0.5;
    }
    return value;
  }
}
