import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Searches for product images online (Open Food Facts API — no key required)
/// and downloads selected images to local storage for use as reference images.
///
/// This service is used ONLY during enrollment. The scanner is fully offline.
class WebImageEnrichmentService {
  static const _timeout = Duration(seconds: 10);

  // ── Public API ────────────────────────────────────────────────────────────

  /// Search for product images by [query].
  ///
  /// Returns a list of remote image URLs (up to [maxResults]).
  /// Returns an empty list on network failure — never throws.
  Future<List<String>> searchImages(String query,
      {int maxResults = 8}) async {
    if (query.trim().isEmpty) return const [];
    try {
      final results = await _searchOpenFoodFacts(query, maxResults);
      return results;
    } catch (_) {
      // Silently degrade — enrollment still works without web images.
      return const [];
    }
  }

  /// Download a remote [imageUrl] and save it into [productId]'s reference
  /// directory.
  ///
  /// Returns the saved local path, or null on failure.
  Future<String?> downloadAndSave(String productId, String imageUrl) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = _timeout;
      final req = await client.getUrl(Uri.parse(imageUrl));
      req.headers.set(HttpHeaders.userAgentHeader,
          'AIStoreAssistant/1.0 (enrollment enrichment)');
      final res = await req.close();
      if (res.statusCode != 200) {
        client.close();
        return null;
      }
      final bytes = await consolidateHttpClientResponseBytes(res);
      client.close(force: false);

      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory(
        p.join(appDir.path, 'product_images', productId),
      );
      if (!dir.existsSync()) await dir.create(recursive: true);

      final ext = _guessExtension(imageUrl);
      final fileName = 'web_${DateTime.now().millisecondsSinceEpoch}$ext';
      final file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  Future<List<String>> _searchOpenFoodFacts(
      String query, int maxResults) async {
    final uri = Uri.parse(
      'https://world.openfoodfacts.org/cgi/search.pl'
      '?search_terms=${Uri.encodeComponent(query)}'
      '&json=1&page_size=$maxResults&fields=image_url,image_front_url',
    );

    final client = HttpClient();
    client.connectionTimeout = _timeout;
    final req = await client.getUrl(uri);
    req.headers.set(HttpHeaders.userAgentHeader,
        'AIStoreAssistant/1.0 (enrollment enrichment)');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    client.close(force: false);

    if (res.statusCode != 200) return const [];

    final json = jsonDecode(body) as Map<String, dynamic>;
    final products = json['products'] as List<dynamic>? ?? [];
    final urls = <String>[];
    for (final product in products) {
      final map = product as Map<String, dynamic>;
      final url = (map['image_front_url'] ?? map['image_url']) as String?;
      if (url != null && url.isNotEmpty) {
        urls.add(url);
        if (urls.length >= maxResults) break;
      }
    }
    return urls;
  }

  String _guessExtension(String url) {
    final lower = url.toLowerCase().split('?').first;
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return '.jpg';
    if (lower.endsWith('.png')) return '.png';
    if (lower.endsWith('.webp')) return '.webp';
    return '.jpg';
  }

  /// Reads all bytes from an [HttpClientResponse].
  static Future<List<int>> consolidateHttpClientResponseBytes(
      HttpClientResponse response) async {
    final chunks = <List<int>>[];
    await for (final chunk in response) {
      chunks.add(chunk);
    }
    return chunks.expand((c) => c).toList();
  }
}
