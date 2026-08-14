import 'dart:io';
import 'dart:typed_data';

import 'package:ai_store_assistant/shared/models/product_model.dart';
import 'package:ai_store_assistant/shared/services/local_product_index_service.dart';
import 'package:ai_store_assistant/shared/services/visual_embedding_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

ProductModel _product(String id, String imagePath) => ProductModel(
      id: id,
      name: 'Product $id',
      category: 'Test',
      purchasePrice: 1,
      sellingPrice: 2,
      quantity: 1,
      imageUrl: imagePath,
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

Future<String> _writePatternImage(
  Directory dir,
  String name, {
  required int base,
  required int stripe,
}) async {
  final image = img.Image(width: 96, height: 96);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final v = ((x ~/ 12 + y ~/ 12).isEven ? base : stripe).clamp(0, 255);
      image.setPixelRgb(x, y, v, (v + base) ~/ 2, stripe);
    }
  }
  final file = File('${dir.path}/$name.png');
  await file.writeAsBytes(img.encodePng(image));
  return file.path;
}

void main() {
  late Directory tempDir;
  late AHashEmbeddingService embedding;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('visual_embedding_file_');
    embedding = AHashEmbeddingService();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('correct product image produces a non-empty embedding', () async {
    final imagePath = await _writePatternImage(
      tempDir,
      'same_a',
      base: 32,
      stripe: 220,
    );

    final result = await embedding.embedFile(imagePath);

    expect(result, isNotNull);
    expect(result, isNotEmpty);
    expect(result!.length, embedding.embeddingLength);
  });

  test('two views of the same product are more similar than different products',
      () async {
    final sameA = await _writePatternImage(
      tempDir,
      'same_a',
      base: 32,
      stripe: 220,
    );
    final sameB = await _writePatternImage(
      tempDir,
      'same_b',
      base: 36,
      stripe: 216,
    );
    final different = await _writePatternImage(
      tempDir,
      'different',
      base: 230,
      stripe: 24,
    );

    final embA = (await embedding.embedFile(sameA))!;
    final embB = (await embedding.embedFile(sameB))!;
    final embDifferent = (await embedding.embedFile(different))!;

    final sameSimilarity = embedding.similarity(embA, embB);
    final differentSimilarity = embedding.similarity(embA, embDifferent);

    expect(sameSimilarity, greaterThan(0.85));
    expect(differentSimilarity, lessThan(sameSimilarity));
  });

  test('multi-product local index chooses the correct product id', () async {
    final target = await _writePatternImage(
      tempDir,
      'target',
      base: 48,
      stripe: 210,
    );
    final distractor = await _writePatternImage(
      tempDir,
      'distractor',
      base: 220,
      stripe: 48,
    );
    final query = await embedding.embedFile(target) as Uint8List;
    final index = LocalProductIndexService(embeddingService: embedding);

    await index.buildIndex([
      _product('target-product', target),
      _product('distractor-product', distractor),
    ]);

    final results = index.search(query, minConfidence: 0.80);

    expect(results, isNotEmpty);
    expect(results.first.productId, 'target-product');
  });

  test('confidence below minimum threshold returns no candidate', () async {
    final target = await _writePatternImage(
      tempDir,
      'target',
      base: 48,
      stripe: 210,
    );
    final queryPath = await _writePatternImage(
      tempDir,
      'query',
      base: 220,
      stripe: 48,
    );
    final query = await embedding.embedFile(queryPath) as Uint8List;
    final index = LocalProductIndexService(embeddingService: embedding);

    await index.buildIndex([_product('target-product', target)]);

    expect(index.search(query, minConfidence: 0.99), isEmpty);
  });
}
