import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class YemenCatalogImageHydrationService {
  Future<String?> hydrate({
    required String catalogId,
    required List<String> imageUrls,
  }) async {
    final source = imageUrls.firstWhere(
      (url) => url.trim().isNotEmpty,
      orElse: () => '',
    );
    if (source.isEmpty) return null;

    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, 'catalog_references'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, '${_safe(catalogId)}.jpg'));
    if (await file.exists() && await file.length() > 0) return file.path;

    try {
      final response = await http.get(
        Uri.parse(source),
        headers: const {
          'User-Agent': 'AIStoreAssistant/1.0',
          'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300 || response.bodyBytes.isEmpty) {
        return null;
      }
      await file.writeAsBytes(response.bodyBytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  String _safe(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_');
    if (cleaned.isEmpty) return 'catalog_product';
    return cleaned.length <= 90 ? cleaned : cleaned.substring(0, 90);
  }
}
