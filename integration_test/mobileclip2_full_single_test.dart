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

  testWidgets('FULL Android visual engine end-to-end validation', (tester) async {
    final provider = FastVisualEmbeddingProvider();
    CameraController? camera;
    final directory = await getTemporaryDirectory();
    final files = <String>[];

    try {
      // 1. Real ONNX initialization and contract.
      final initWatch = Stopwatch()..start();
      await provider.initialize().timeout(const Duration(seconds: 30));
      final initMs = initWatch.elapsedMilliseconds;
      expect(provider.isOnnxActive, isTrue);
      expect(provider.embeddingLength, 2048);
      expect(provider.modelVersion, contains('mobileclip2'));

      // 2. One deterministic image: finite 512-D L2-normalized embedding and repeatability.
      final probePath = '${directory.path}/full_probe.png';
      files.add(probePath);
      await File(probePath).writeAsBytes(img.encodePng(_makeProductImage(0, 7)));
      final first = await provider.embedFile(probePath).timeout(
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

      final second = await provider.embedFile(probePath).timeout(
        const Duration(seconds: 20),
      );
      expect(second, isNotNull);
      expect(provider.similarity(first, second!), greaterThan(0.999));

      // 3. Multiple products in one local in-memory index.
      const productCount = 6;
      final products = <ProductModel>[];
      final referenceEmbeddings = <String, List<int>>{};
      final referencePaths = <String>[];
      for (var i = 0; i < productCount; i++) {
        final path = '${directory.path}/full_product_$i.png';
        files.add(path);
        await File(path).writeAsBytes(img.encodePng(_makeProductImage(i, 50 + i)));
        referencePaths.add(path);
        products.add(ProductModel(
          id: 'full-product-$i',
          name: 'Full Product $i',
          category: 'Android engine test',
          purchasePrice: 1,
          sellingPrice: 2,
          quantity: 10,
          imageUrl: path,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ));
      }

      final index = LocalProductIndexService(embeddingService: provider);
      final buildWatch = Stopwatch()..start();
      await index.buildIndex(products).timeout(const Duration(minutes: 2));
      buildWatch.stop();
      expect(index.isBuilt, isTrue);
      expect(index.indexedProductCount, productCount);
      expect(index.indexedEmbeddingCount, productCount);

      final recognitionWatch = Stopwatch()..start();
      for (var i = 0; i < productCount; i++) {
        final embedding = await provider.embedFile(referencePaths[i]).timeout(
          const Duration(seconds: 20),
        );
        expect(embedding, isNotNull);
        referenceEmbeddings[products[i].id] = embedding!.toList();

        final result = index.evaluate(
          embedding,
          topK: 3,
          minConfidence: 0.45,
          minMargin: 0,
        );
        expect(result.isAccepted, isTrue);
        expect(result.best?.productId, products[i].id);
        expect(result.bestScore, greaterThan(0.99));
      }
      recognitionWatch.stop();

      // 4. Background / exposure / JPEG / resize robustness for one product.
      final robustnessReference = img.decodeImage(
        await File(referencePaths.first).readAsBytes(),
      )!;
      final referenceEmbedding = Float32ListAdapter.fromBytes(
        referenceEmbeddings[products.first.id]!,
      );
      for (var variant = 0; variant < 4; variant++) {
        final path = '${directory.path}/full_variant_$variant.jpg';
        files.add(path);
        final transformed = _makeVariant(
          robustnessReference,
          seed: 300 + variant,
          exposure: variant.isEven ? 12 : -12,
        );
        await File(path).writeAsBytes(
          img.encodeJpg(transformed, quality: 40 + variant * 8),
        );
        final embedding = await provider.embedFile(path).timeout(
          const Duration(seconds: 20),
        );
        expect(embedding, isNotNull);
        final similarity = provider.similarity(
          referenceEmbedding.bytes,
          embedding!,
        );
        expect(similarity, greaterThan(0.45));
      }

      // 5. Real Android camera capture through CameraController.
      final cameras = await availableCameras().timeout(
        const Duration(seconds: 15),
      );
      expect(cameras, isNotEmpty);
      final description = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      camera = CameraController(
        description,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await camera.initialize().timeout(const Duration(seconds: 15));
      final capture = await camera.takePicture().timeout(
        const Duration(seconds: 15),
      );
      final cameraEmbedding = await provider.embedFile(capture.path).timeout(
        const Duration(seconds: 20),
      );
      expect(cameraEmbedding, isNotNull);
      final cameraProduct = ProductModel(
        id: 'real-camera-product',
        name: 'Real Camera Product',
        category: 'Camera',
        purchasePrice: 1,
        sellingPrice: 2,
        quantity: 1,
        imageUrl: capture.path,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      final cameraIndex = LocalProductIndexService(embeddingService: provider);
      await cameraIndex.buildIndex([cameraProduct]);
      final cameraResult = cameraIndex.evaluate(
        cameraEmbedding!,
        minConfidence: 0.45,
        minMargin: 0,
      );
      expect(cameraResult.isAccepted, isTrue);
      expect(cameraResult.best?.productId, cameraProduct.id);
      expect(cameraResult.bestScore, greaterThan(0.99));

      // 6. The complete path has now run: ONNX -> image -> embeddings -> index ->
      // search -> transformed image recognition -> real Android camera recognition.
      // ignore: avoid_print
      print(
        'FULL Android visual validation PASS: init=${initMs}ms '
        'indexBuild=${buildWatch.elapsedMilliseconds}ms '
        'multiProductRecognition=${recognitionWatch.elapsedMilliseconds}ms '
        'cameraScore=${cameraResult.bestScore.toStringAsFixed(4)}',
      );
    } finally {
      await camera?.dispose();
      await provider.dispose();
      for (final path in files) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  });
}

img.Image _makeProductImage(int id, int seed) {
  final image = img.Image(width: 256, height: 256);
  final bgR = (30 + id * 37) % 180 + 35;
  final bgG = (40 + id * 53) % 160 + 45;
  final bgB = (60 + id * 71) % 140 + 60;
  for (var y = 0; y < 256; y++) {
    for (var x = 0; x < 256; x++) {
      final n = ((x * 7 + y * 11 + seed * 13) % 13) - 6;
      image.setPixelRgb(
        x,
        y,
        (bgR + n).clamp(0, 255),
        (bgG + n).clamp(0, 255),
        (bgB + n).clamp(0, 255),
      );
    }
  }

  final left = 55 + (id % 3) * 5;
  final top = 42 + (id % 4) * 4;
  final right = 205 - (id % 4) * 4;
  final bottom = 215 - (id % 3) * 5;
  final r = (80 + id * 23) % 150 + 70;
  final g = (55 + id * 31) % 150 + 60;
  final b = (70 + id * 41) % 150 + 70;

  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      final edge = x == left || x == right - 1 || y == top || y == bottom - 1;
      image.setPixelRgb(x, y, edge ? 248 : r, edge ? 248 : g, edge ? 248 : b);
    }
  }
  for (var row = 0; row < 5; row++) {
    for (var col = 0; col < 5; col++) {
      if (((id + 1) * 19 + row * 7 + col * 11) % 4 == 0) continue;
      final x0 = left + 18 + col * 25;
      final y0 = top + 16 + row * 25;
      for (var y = y0; y < y0 + 12; y++) {
        for (var x = x0; x < x0 + 12; x++) {
          image.setPixelRgb(x, y, 252, 252, 252);
        }
      }
    }
  }
  return image;
}

img.Image _makeVariant(
  img.Image source, {
  required int seed,
  required int exposure,
}) {
  final result = source.clone();
  for (var y = 0; y < result.height; y++) {
    for (var x = 0; x < result.width; x++) {
      final p = result.getPixel(x, y);
      final n = ((x * 3 + y * 5 + seed) % 17) - 8;
      result.setPixelRgb(
        x,
        y,
        (p.r + exposure + n).clamp(0, 255).toInt(),
        (p.g + exposure + n).clamp(0, 255).toInt(),
        (p.b + exposure + n).clamp(0, 255).toInt(),
      );
    }
  }
  final reduced = img.copyResize(result, width: 128, height: 128);
  return img.copyResize(reduced, width: 256, height: 256);
}

class Float32ListAdapter {
  const Float32ListAdapter(this.bytes);

  final List<int> bytes;

  static Float32ListAdapter fromBytes(List<int> bytes) =>
      Float32ListAdapter(bytes);
}
