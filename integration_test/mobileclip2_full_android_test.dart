import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:ai_store_assistant/shared/models/product_model.dart';
import 'package:ai_store_assistant/shared/services/fast_visual_embedding_service.dart';
import 'package:ai_store_assistant/shared/services/local_product_index_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('FULL: MobileCLIP2 runtime contract, inference and determinism',
      (tester) async {
    final provider = FastVisualEmbeddingProvider();
    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/full_runtime_probe.png';
    await File(path).writeAsBytes(img.encodePng(_makeProductImage(0, 11)));

    try {
      final watch = Stopwatch()..start();
      await provider.initialize().timeout(const Duration(seconds: 30));
      final initializationMs = watch.elapsedMilliseconds;
      expect(provider.isOnnxActive, isTrue);
      expect(provider.embeddingLength, 2048);
      expect(provider.modelVersion, contains('mobileclip2'));

      final first = await provider.embedFile(path).timeout(
        const Duration(seconds: 20),
      );
      expect(first, isNotNull);
      expect(first!.length, 2048);
      final values = first.buffer.asFloat32List();
      expect(values.length, 512);
      expect(values.every((v) => v.isFinite), isTrue);

      var norm = 0.0;
      for (final value in values) norm += value * value;
      expect(sqrt(norm), closeTo(1.0, 0.01));

      final second = await provider.embedFile(path).timeout(
        const Duration(seconds: 20),
      );
      expect(second, isNotNull);
      expect(provider.similarity(first, second!), greaterThan(0.999));

      // ignore: avoid_print
      print(
        'FULL runtime PASS: init=${initializationMs}ms '
        'embedding=${watch.elapsedMilliseconds - initializationMs}ms',
      );
    } finally {
      await provider.dispose();
      try {
        await File(path).delete();
      } catch (_) {}
    }
  });

  testWidgets('FULL: real Android camera capture -> embedding -> recognition',
      (tester) async {
    final provider = FastVisualEmbeddingProvider();
    CameraController? controller;

    try {
      await provider.initialize().timeout(const Duration(seconds: 30));
      expect(provider.isOnnxActive, isTrue);

      final cameras = await availableCameras().timeout(
        const Duration(seconds: 15),
      );
      expect(cameras, isNotEmpty);
      final description = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      controller = CameraController(
        description,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize().timeout(const Duration(seconds: 15));
      final capture = await controller.takePicture().timeout(
        const Duration(seconds: 15),
      );

      final embedding = await provider.embedFile(capture.path).timeout(
        const Duration(seconds: 20),
      );
      expect(embedding, isNotNull);
      expect(embedding!.length, 2048);

      final product = ProductModel(
        id: 'real-camera-product',
        name: 'Real Camera Product',
        category: 'Android camera',
        purchasePrice: 1,
        sellingPrice: 2,
        quantity: 1,
        imageUrl: capture.path,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      final index = LocalProductIndexService(embeddingService: provider);
      await index.buildIndex([product]);
      final result = index.evaluate(
        embedding,
        minConfidence: 0.45,
        minMargin: 0,
      );
      expect(result.isAccepted, isTrue);
      expect(result.best?.productId, product.id);
      expect(result.bestScore, greaterThanOrEqualTo(0.99));

      // ignore: avoid_print
      print('FULL camera recognition PASS: score=${result.bestScore}');
    } finally {
      await controller?.dispose();
      await provider.dispose();
    }
  });

  testWidgets('FULL: background/quality robustness on one real product family',
      (tester) async {
    final provider = FastVisualEmbeddingProvider();
    final directory = await getTemporaryDirectory();
    final paths = <String>[];

    try {
      await provider.initialize().timeout(const Duration(seconds: 30));
      expect(provider.isOnnxActive, isTrue);

      final reference = _makeProductImage(3, 7);
      final referencePath = '${directory.path}/robust_reference.png';
      await File(referencePath).writeAsBytes(img.encodePng(reference));
      paths.add(referencePath);
      final referenceEmbedding = await provider.embedFile(referencePath).timeout(
        const Duration(seconds: 20),
      );
      expect(referenceEmbedding, isNotNull);

      final similarities = <double>[];
      for (var variant = 0; variant < 6; variant++) {
        final transformed = _makeProductVariant(
          reference,
          backgroundSeed: 100 + variant,
          exposure: variant.isEven ? 18 : -18,
          jpegQuality: 24 + variant * 5,
        );
        final path = '${directory.path}/robust_variant_$variant.jpg';
        await File(path).writeAsBytes(img.encodeJpg(transformed, quality: 24 + variant * 5));
        paths.add(path);

        final embedding = await provider.embedFile(path).timeout(
          const Duration(seconds: 20),
        );
        expect(embedding, isNotNull);
        final similarity = provider.similarity(referenceEmbedding!, embedding!);
        similarities.add(similarity);
        expect(similarity, greaterThan(0.45));
      }

      final minimum = similarities.reduce(min);
      final average = similarities.reduce((a, b) => a + b) / similarities.length;
      // ignore: avoid_print
      print(
        'FULL robustness PASS: minSimilarity=${minimum.toStringAsFixed(4)} '
        'avgSimilarity=${average.toStringAsFixed(4)}',
      );
    } finally {
      await provider.dispose();
      for (final path in paths) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  });

  testWidgets('FULL: multi-product local index recognition and search latency',
      (tester) async {
    final provider = FastVisualEmbeddingProvider();
    final directory = await getTemporaryDirectory();
    final references = <String>[];
    final queries = <String>[];

    try {
      await provider.initialize().timeout(const Duration(seconds: 30));
      expect(provider.isOnnxActive, isTrue);

      const productCount = 8;
      final products = <ProductModel>[];
      for (var i = 0; i < productCount; i++) {
        final referencePath = '${directory.path}/multi_ref_$i.png';
        final queryPath = '${directory.path}/multi_query_$i.jpg';
        final reference = _makeProductImage(i, i + 20);
        final query = _makeProductVariant(
          reference,
          backgroundSeed: i + 200,
          exposure: i.isEven ? 10 : -10,
          jpegQuality: 48,
        );
        await File(referencePath).writeAsBytes(img.encodePng(reference));
        await File(queryPath).writeAsBytes(img.encodeJpg(query, quality: 48));
        references.add(referencePath);
        queries.add(queryPath);
        products.add(ProductModel(
          id: 'multi-$i',
          name: 'Multi Product $i',
          category: 'Full test',
          purchasePrice: 1,
          sellingPrice: 2,
          quantity: 10,
          imageUrl: referencePath,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ));
      }

      final index = LocalProductIndexService(embeddingService: provider);
      final buildWatch = Stopwatch()..start();
      await index.buildIndex(products).timeout(const Duration(minutes: 2));
      buildWatch.stop();
      expect(index.indexedProductCount, productCount);
      expect(index.indexedEmbeddingCount, productCount);

      final failures = <String>[];
      final recognitionWatch = Stopwatch()..start();
      for (var i = 0; i < productCount; i++) {
        final embedding = await provider.embedFile(queries[i]).timeout(
          const Duration(seconds: 20),
        );
        expect(embedding, isNotNull);
        final result = index.evaluate(
          embedding!,
          topK: 3,
          minConfidence: 0.45,
          minMargin: 0,
        );
        if (!result.isAccepted || result.best?.productId != 'multi-$i') {
          failures.add(
            'i=$i expected=multi-$i actual=${result.best?.productId} '
            'score=${result.bestScore.toStringAsFixed(4)}',
          );
        }
      }
      recognitionWatch.stop();

      expect(failures, isEmpty, reason: failures.join('\n'));
      expect(recognitionWatch.elapsedMilliseconds, lessThan(180000));

      // ignore: avoid_print
      print(
        'FULL multi-product PASS: products=$productCount '
        'indexBuild=${buildWatch.elapsedMilliseconds}ms '
        'recognition=${recognitionWatch.elapsedMilliseconds}ms',
      );
    } finally {
      await provider.dispose();
      for (final path in [...references, ...queries]) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  });
}

img.Image _makeProductImage(int id, int backgroundSeed) {
  final image = img.Image(width: 320, height: 320);
  final baseR = (35 + id * 29) % 190 + 30;
  final baseG = (50 + id * 41) % 170 + 40;
  final baseB = (70 + id * 53) % 150 + 60;
  for (var y = 0; y < 320; y++) {
    for (var x = 0; x < 320; x++) {
      final noise = ((x * 7 + y * 11 + backgroundSeed * 13) % 17) - 8;
      image.setPixelRgb(
        x,
        y,
        (baseR + noise).clamp(0, 255),
        (baseG + noise).clamp(0, 255),
        (baseB + noise).clamp(0, 255),
      );
    }
  }

  final left = 64 + (id * 7) % 24;
  final top = 52 + (id * 5) % 20;
  final right = 256 - (id * 3) % 24;
  final bottom = 270 - (id * 4) % 20;
  final objectR = (220 - id * 11) % 120 + 100;
  final objectG = (70 + id * 17) % 150 + 70;
  final objectB = (50 + id * 23) % 160 + 60;

  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      final edge = x == left || x == right - 1 || y == top || y == bottom - 1;
      image.setPixelRgb(
        x,
        y,
        edge ? 245 : objectR,
        edge ? 245 : objectG,
        edge ? 245 : objectB,
      );
    }
  }

  for (var row = 0; row < 5; row++) {
    for (var col = 0; col < 5; col++) {
      if (((id + 3) * 17 + row * 11 + col * 7) % 3 == 0) continue;
      final cx = left + 22 + col * 30;
      final cy = top + 28 + row * 30;
      for (var y = cy; y < cy + 16; y++) {
        for (var x = cx; x < cx + 16; x++) {
          image.setPixelRgb(x, y, 250, 250, 250);
        }
      }
    }
  }
  return image;
}

img.Image _makeProductVariant(
  img.Image source, {
  required int backgroundSeed,
  required int exposure,
  required int jpegQuality,
}) {
  final variant = source.clone();
  for (var y = 0; y < variant.height; y++) {
    for (var x = 0; x < variant.width; x++) {
      final p = variant.getPixel(x, y);
      final backgroundNoise = ((x * 5 + y * 3 + backgroundSeed) % 19) - 9;
      variant.setPixelRgb(
        x,
        y,
        (p.r + exposure + backgroundNoise).clamp(0, 255).toInt(),
        (p.g + exposure + backgroundNoise).clamp(0, 255).toInt(),
        (p.b + exposure + backgroundNoise).clamp(0, 255).toInt(),
      );
    }
  }
  final resized = img.copyResize(variant, width: 192, height: 192);
  return img.copyResize(resized, width: 320, height: 320);
}
