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

  testWidgets('MobileCLIP2 Android runtime loads external data and infers',
      (tester) async {
    final provider = FastVisualEmbeddingProvider();
    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/mobileclip2_runtime_probe.png';
    final image = img.Image(width: 224, height: 224);
    for (var y = 0; y < 224; y++) {
      for (var x = 0; x < 224; x++) {
        final r = ((x / 223) * 255).round();
        final g = ((y / 223) * 255).round();
        final b = (((x + y) / 446) * 255).round();
        image.setPixelRgb(x, y, r, g, b);
      }
    }
    await File(path).writeAsBytes(img.encodePng(image));

    final stopwatch = Stopwatch()..start();
    await provider.initialize();
    final initializationMs = stopwatch.elapsedMilliseconds;
    expect(provider.isOnnxActive, isTrue);
    expect(provider.embeddingLength, 2048);

    final first = await provider.embedFile(path);
    final firstMs = stopwatch.elapsedMilliseconds - initializationMs;
    expect(first, isNotNull);
    expect(first!.length, 2048);

    final values = first.buffer.asFloat32List();
    expect(values.every((value) => value.isFinite), isTrue);
    var norm = 0.0;
    for (final value in values) norm += value * value;
    expect(sqrt(norm), closeTo(1.0, 0.01));

    final second = await provider.embedFile(path);
    expect(second, isNotNull);
    expect(provider.similarity(first, second!), greaterThan(0.999));

    final totalMs = stopwatch.elapsedMilliseconds;
    expect(totalMs, lessThan(30000));

    // ignore: avoid_print
    print('MobileCLIP2 initialization=${initializationMs}ms firstInference=${firstMs}ms total=${totalMs}ms');

    await provider.dispose();
    await File(path).delete();
  });

  testWidgets('real Android camera capture feeds the visual engine and recognizes it',
      (tester) async {
    final provider = FastVisualEmbeddingProvider();
    await provider.initialize();
    expect(provider.isOnnxActive, isTrue);

    final cameras = await availableCameras();
    expect(cameras, isNotEmpty);
    final description = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      description,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await controller.initialize().timeout(const Duration(seconds: 15));
      final capture = await controller.takePicture().timeout(
            const Duration(seconds: 15),
          );
      expect(await File(capture.path).exists(), isTrue);

      final embedding = await provider.embedFile(capture.path);
      expect(embedding, isNotNull);
      expect(embedding!.length, 2048);

      final product = ProductModel(
        id: 'camera-captured-product',
        name: 'Camera Captured Product',
        category: 'Camera Test',
        purchasePrice: 1,
        sellingPrice: 2,
        quantity: 1,
        imageUrl: capture.path,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      final index = LocalProductIndexService(embeddingService: provider);
      await index.buildIndex([product]);
      expect(index.indexedProductCount, 1);
      expect(index.indexedEmbeddingCount, 1);

      final match = index.evaluate(
        embedding,
        minConfidence: 0.45,
        minMargin: 0,
      );
      expect(match.isAccepted, isTrue);
      expect(match.best?.productId, product.id);
    } finally {
      await controller.dispose();
      await provider.dispose();
    }
  });

  testWidgets('20-product continuous recognition benchmark with hostile backgrounds and degraded quality',
      (tester) async {
    final provider = FastVisualEmbeddingProvider();
    await provider.initialize();
    expect(provider.isOnnxActive, isTrue);

    final directory = await getTemporaryDirectory();
    final products = <ProductModel>[];
    final references = <String>[];
    final queries = <String>[];

    try {
      for (var id = 0; id < 20; id++) {
        final productId = 'bench-$id';
        final reference = _makeProductImage(id, backgroundSeed: id);
        final query = _makeProductImage(id, backgroundSeed: 1000 + id);

        final referencePath = '${directory.path}/bench_ref_$id.png';
        final queryJpg = '${directory.path}/bench_query_$id.jpg';
        await File(referencePath).writeAsBytes(img.encodePng(reference));

        // Deliberately degrade every query: low-resolution intermediate,
        // JPEG compression, and a small exposure shift.
        final small = img.copyResize(query, width: 96, height: 96);
        final degraded = img.copyResize(small, width: 320, height: 320);
        _exposureShift(degraded, id.isEven ? 12 : -12);
        await File(queryJpg).writeAsBytes(img.encodeJpg(degraded, quality: 28));

        products.add(ProductModel(
          id: productId,
          name: 'Benchmark Product $id',
          category: 'Benchmark',
          purchasePrice: 1,
          sellingPrice: 2,
          quantity: 10,
          imageUrl: referencePath,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ));
        references.add(referencePath);
        queries.add(queryJpg);
      }

      final index = LocalProductIndexService(embeddingService: provider);
      final buildWatch = Stopwatch()..start();
      await index.buildIndex(products);
      buildWatch.stop();
      expect(index.indexedProductCount, 20);
      expect(index.indexedEmbeddingCount, 20);

      final latencies = <int>[];
      final failures = <String>[];
      final scanWatch = Stopwatch()..start();

      for (var i = 0; i < 20; i++) {
        final embedding = await provider.embedFile(queries[i]);
        if (embedding == null) {
          failures.add('$i: embedding failed');
          continue;
        }
        final resultWatch = Stopwatch()..start();
        final result = index.evaluate(
          embedding,
          topK: 3,
          minConfidence: 0.45,
          minMargin: 0.02,
        );
        resultWatch.stop();
        latencies.add(resultWatch.elapsedMicroseconds);

        final expectedId = 'bench-$i';
        if (!result.isAccepted || result.best?.productId != expectedId) {
          failures.add(
            '$i: expected=$expectedId best=${result.best?.productId} '
            'score=${result.bestScore.toStringAsFixed(4)} '
            'margin=${result.margin.toStringAsFixed(4)}',
          );
        }
      }
      scanWatch.stop();

      expect(failures, isEmpty, reason: failures.join('\n'));
      expect(latencies.length, 20);

      final sortedSearchMicros = [...latencies]..sort();
      final p95Index = (sortedSearchMicros.length * 95 ~/ 100)
          .clamp(0, sortedSearchMicros.length - 1);
      final p95SearchMicros = sortedSearchMicros[p95Index];
      final continuousScanMs = scanWatch.elapsedMilliseconds;

      expect(continuousScanMs, lessThan(5000));
      expect(p95SearchMicros, lessThan(10000));

      // ignore: avoid_print
      print(
        '20-product benchmark: indexBuild=${buildWatch.elapsedMilliseconds}ms '
        'continuousScan=${continuousScanMs}ms '
        'searchP95=${p95SearchMicros / 1000.0}ms',
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

img.Image _makeProductImage(int id, {required int backgroundSeed}) {
  final image = img.Image(width: 320, height: 320);
  for (var y = 0; y < 320; y++) {
    for (var x = 0; x < 320; x++) {
      final noise = ((x * 13 + y * 7 + backgroundSeed * 17) % 31) - 15;
      final r = (28 + backgroundSeed * 19 + noise).clamp(0, 255).toInt();
      final g = (34 + backgroundSeed * 11 + noise).clamp(0, 255).toInt();
      final b = (42 + backgroundSeed * 23 + noise).clamp(0, 255).toInt();
      image.setPixelRgb(x, y, r, g, b);
    }
  }

  const left = 78;
  const top = 62;
  const right = 242;
  const bottom = 258;
  final baseR = (30 + id * 17) % 220 + 20;
  final baseG = (60 + id * 29) % 180 + 30;
  final baseB = (100 + id * 37) % 140 + 50;

  for (var y = top; y <= bottom; y++) {
    for (var x = left; x <= right; x++) {
      final border = x == left || x == right || y == top || y == bottom;
      if (border) {
        image.setPixelRgb(x, y, 245, 245, 245);
      } else {
        image.setPixelRgb(x, y, baseR, baseG, baseB);
      }
    }
  }

  for (var gy = 0; gy < 8; gy++) {
    for (var gx = 0; gx < 8; gx++) {
      final bit = ((id + 1) * 31 + gx * 17 + gy * 13 + (id % 5) * gx * gy) & 1;
      if (bit == 0) continue;
      final cellLeft = 92 + gx * 18;
      final cellTop = 76 + gy * 18;
      for (var y = cellTop; y < cellTop + 12; y++) {
        for (var x = cellLeft; x < cellLeft + 12; x++) {
          image.setPixelRgb(x, y, 245, 245, 245);
        }
      }
    }
  }
  return image;
}

void _exposureShift(img.Image image, int delta) {
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      image.setPixelRgb(
        x,
        y,
        (p.r + delta).clamp(0, 255).toInt(),
        (p.g + delta).clamp(0, 255).toInt(),
        (p.b + delta).clamp(0, 255).toInt(),
      );
    }
  }
}
