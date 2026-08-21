import 'dart:async';
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
import 'package:ai_store_assistant/shared/services/recognition_pipeline.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MobileCLIP2 real Android camera + recognition validation', (tester) async {
    final provider = FastVisualEmbeddingProvider();
    final directory = await getTemporaryDirectory();
    final files = <String>[];
    CameraController? camera;

    try {
      final initWatch = Stopwatch()..start();
      await provider.initialize().timeout(const Duration(seconds: 45));
      initWatch.stop();
      expect(provider.isOnnxActive, isTrue);
      expect(provider.embeddingLength, 2048);
      expect(provider.modelVersion, contains('mobileclip2_s0'));

      const productCount = 12;
      final products = <ProductModel>[];
      final referencePaths = <String>[];
      for (var id = 0; id < productCount; id++) {
        final path = '${directory.path}/product_$id.png';
        files.add(path);
        await File(path).writeAsBytes(img.encodePng(_makeProductImage(id)));
        referencePaths.add(path);
        products.add(ProductModel(
          id: 'product-$id',
          name: 'Validation Product $id',
          category: 'MobileCLIP2 validation',
          purchasePrice: 1,
          sellingPrice: 2,
          quantity: 10,
          imageUrl: path,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ));
      }

      final index = LocalProductIndexService(embeddingService: provider);
      final indexWatch = Stopwatch()..start();
      await index.buildIndex(products).timeout(const Duration(minutes: 3));
      indexWatch.stop();
      expect(index.isBuilt, isTrue);
      expect(index.indexedProductCount, productCount);
      expect(index.indexedEmbeddingCount, productCount);

      var correct = 0;
      var totalQueries = 0;
      final recognitionTimes = <int>[];
      for (var id = 0; id < productCount; id++) {
        for (var variant = 0; variant < 3; variant++) {
          final queryPath = '${directory.path}/query_${id}_$variant.jpg';
          files.add(queryPath);
          final source = img.decodeImage(await File(referencePaths[id]).readAsBytes())!;
          final transformed = _makeQueryVariant(source, variant);
          await File(queryPath).writeAsBytes(img.encodeJpg(transformed, quality: 45 + variant * 20));

          final watch = Stopwatch()..start();
          final embedding = await provider.embedFile(queryPath).timeout(const Duration(seconds: 15));
          watch.stop();
          recognitionTimes.add(watch.elapsedMilliseconds);
          expect(embedding, isNotNull);
          expect(embedding!.length, 2048);

          final result = index.evaluate(
            embedding,
            topK: 3,
            minConfidence: 0.45,
            minMargin: 0.08,
          );
          totalQueries++;
          if (result.isAccepted && result.best?.productId == products[id].id) correct++;
          // ignore: avoid_print
          if (result.best?.productId != products[id].id || !result.isAccepted) {
            print('RECOGNITION FAILURE id=$id variant=$variant best=${result.best?.productId} score=${result.bestScore} second=${result.secondBestScore} margin=${result.margin} reason=${result.rejectionReason}');
          }
          expect(result.best?.productId, products[id].id);
          expect(result.isAccepted, isTrue);
        }
      }
      expect(correct, totalQueries);

      final pairScores = <double>[];
      for (var i = 0; i < productCount; i++) {
        final a = await provider.embedFile(referencePaths[i]);
        expect(a, isNotNull);
        for (var j = i + 1; j < productCount; j++) {
          final b = await provider.embedFile(referencePaths[j]);
          expect(b, isNotNull);
          pairScores.add(provider.similarity(a!, b!));
        }
      }
      final maxDifferentProductSimilarity = pairScores.reduce(max);
      expect(maxDifferentProductSimilarity, lessThan(0.97));

      final cameras = await availableCameras().timeout(const Duration(seconds: 20));
      expect(cameras, isNotEmpty);
      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      camera = CameraController(
        description,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await camera.initialize().timeout(const Duration(seconds: 20));
      expect(camera.value.isInitialized, isTrue);

      CameraImage? liveFrame;
      final frameReady = Completer<void>();
      await camera.startImageStream((frame) {
        liveFrame ??= frame;
        if (!frameReady.isCompleted) frameReady.complete();
      });
      await frameReady.future.timeout(const Duration(seconds: 15));
      expect(liveFrame, isNotNull);

      final frameWatch = Stopwatch()..start();
      final liveEmbedding = await provider.embedFrameWithRotation(
        liveFrame!,
        rotationDegrees: _rotationForCamera(camera, description),
      ).timeout(const Duration(seconds: 15));
      frameWatch.stop();
      expect(liveEmbedding, isNotNull);
      expect(liveEmbedding!.length, 2048);

      await camera.stopImageStream();
      final captured = await camera.takePicture().timeout(const Duration(seconds: 15));
      files.add(captured.path);
      final capturedEmbedding = await provider.embedFile(captured.path).timeout(const Duration(seconds: 15));
      expect(capturedEmbedding, isNotNull);
      expect(provider.similarity(liveEmbedding, capturedEmbedding!), greaterThan(0.70));

      final pipeline = RecognitionPipeline(
        embeddingService: provider,
        config: const RecognitionConfig(minConfidence: 0.45, minMargin: 0.08),
      );
      await pipeline.initialize();
      await pipeline.buildIndex(products);
      final report = await pipeline.processFrame(
        liveFrame!,
        rotationDegrees: _rotationForCamera(camera, description),
      );
      expect(report.processed, isTrue);
      await pipeline.dispose();

      final sortedTimes = [...recognitionTimes]..sort();
      final p95 = sortedTimes[(sortedTimes.length * 0.95).ceil().clamp(1, sortedTimes.length) - 1];
      expect(p95, lessThan(1500));

      // ignore: avoid_print
      print('MOBILECLIP2 REAL VALIDATION PASS: init=${initWatch.elapsedMilliseconds}ms index=${indexWatch.elapsedMilliseconds}ms queries=$totalQueries accuracy=${correct / totalQueries} p95FileInference=${p95}ms liveCameraInference=${frameWatch.elapsedMilliseconds}ms maxDifferentSimilarity=${maxDifferentProductSimilarity.toStringAsFixed(4)}');
    } finally {
      try { await camera?.stopImageStream(); } catch (_) {}
      await camera?.dispose();
      await provider.dispose();
      for (final path in files) { try { await File(path).delete(); } catch (_) {} }
    }
  });
}

int _rotationForCamera(CameraController controller, CameraDescription description) {
  final device = switch (controller.value.deviceOrientation) {
    DeviceOrientation.portraitUp => 0,
    DeviceOrientation.landscapeLeft => 90,
    DeviceOrientation.portraitDown => 180,
    DeviceOrientation.landscapeRight => 270,
  };
  return (description.sensorOrientation - device + 360) % 360;
}

img.Image _makeProductImage(int id) {
  final image = img.Image(width: 320, height: 320);
  final bg = [24 + (id * 31) % 190, 32 + (id * 47) % 170, 42 + (id * 61) % 160];
  final fg = [220 - (id * 17) % 130, 210 - (id * 23) % 120, 230 - (id * 29) % 140];
  for (var y = 0; y < 320; y++) {
    for (var x = 0; x < 320; x++) {
      final noise = ((x * 17 + y * 13 + id * 29) % 11) - 5;
      image.setPixelRgb(x, y, (bg[0] + noise).clamp(0, 255), (bg[1] + noise).clamp(0, 255), (bg[2] + noise).clamp(0, 255));
    }
  }
  final left = 55 + (id % 4) * 8;
  final top = 45 + (id % 3) * 9;
  final right = 265 - (id % 5) * 7;
  final bottom = 275 - (id % 4) * 8;
  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      final stripe = ((x + y + id * 19) ~/ (7 + id % 5)) % 2;
      image.setPixelRgb(x, y, stripe == 0 ? fg[0] : fg[0] ~/ 2, stripe == 0 ? fg[1] : fg[1] ~/ 2, stripe == 0 ? fg[2] : fg[2] ~/ 2);
    }
  }
  for (var row = 0; row < 7; row++) {
    for (var col = 0; col < 7; col++) {
      if (((id + 3) * 17 + row * 13 + col * 7) % 5 == 0) continue;
      final x0 = left + 16 + col * 25;
      final y0 = top + 18 + row * 25;
      for (var y = y0; y < y0 + 10; y++) {
        for (var x = x0; x < x0 + 10; x++) image.setPixelRgb(x, y, 248, 248, 248);
      }
    }
  }
  return image;
}

img.Image _makeQueryVariant(img.Image source, int variant) {
  var result = source.clone();
  if (variant == 0) {
    result = img.copyCrop(result, x: 22, y: 16, width: 276, height: 286);
    result = img.copyResize(result, width: 320, height: 320, interpolation: img.Interpolation.linear);
  } else if (variant == 1) {
    for (var y = 0; y < result.height; y++) {
      for (var x = 0; x < result.width; x++) {
        final p = result.getPixel(x, y);
        final delta = ((x * 5 + y * 3) % 17) - 8;
        result.setPixelRgb(x, y, (p.r + delta + 10).clamp(0, 255).toInt(), (p.g + delta + 10).clamp(0, 255).toInt(), (p.b + delta + 10).clamp(0, 255).toInt());
      }
    }
  } else {
    result = img.copyCrop(result, x: 40, y: 35, width: 240, height: 245);
    result = img.copyResize(result, width: 320, height: 320, interpolation: img.Interpolation.linear);
  }
  return result;
}
