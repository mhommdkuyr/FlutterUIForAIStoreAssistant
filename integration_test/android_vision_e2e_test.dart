import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:ai_store_assistant/core/database/app_database.dart';
import 'package:ai_store_assistant/features/product_scanner/screens/live_scanner_screen.dart';
import 'package:ai_store_assistant/shared/repositories/product_repository.dart';
import 'package:ai_store_assistant/shared/services/fast_visual_embedding_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('REAL Android vision: MobileCLIP2 init/inference contract',
      (tester) async {
    final provider = FastMobileVisionEmbeddingService();
    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/mobileclip2_android_smoke.png';
    final image = img.Image(width: 224, height: 224);

    for (var y = 0; y < 224; y++) {
      for (var x = 0; x < 224; x++) {
        final r = (40 + (x * 3) + (y % 17)) % 220;
        final g = (70 + (y * 2) + (x % 23)) % 210;
        final b = (110 + x + y) % 190;
        image.setPixelRgb(x, y, r, g, b);
      }
    }
    await File(path).writeAsBytes(img.encodePng(image));

    try {
      final initWatch = Stopwatch()..start();
      await provider.initialize().timeout(const Duration(seconds: 60));
      final initMs = initWatch.elapsedMilliseconds;

      expect(provider.isInitialized, isTrue);
      expect(provider.embeddingLength, 2048);
      expect(provider.modelVersion, contains('mobileclip2'));

      final inferenceWatch = Stopwatch()..start();
      final first = await provider.embedFile(path).timeout(
        const Duration(seconds: 60),
      );
      inferenceWatch.stop();

      expect(first, isNotNull);
      expect(first!.length, 2048);
      final vector = first.buffer.asFloat32List();
      expect(vector.length, 512);
      expect(vector.every((value) => value.isFinite), isTrue);

      var normSquared = 0.0;
      for (final value in vector) {
        normSquared += value * value;
      }
      final norm = sqrt(normSquared);
      expect(norm, closeTo(1.0, 0.01));

      final second = await provider.embedFile(path).timeout(
        const Duration(seconds: 60),
      );
      expect(second, isNotNull);
      final similarity = provider.similarity(first, second!);
      expect(similarity, greaterThan(0.999));

      // ignore: avoid_print
      print(
        'REAL MobileCLIP2 ANDROID PASS: init=${initMs}ms '
        'firstInference=${inferenceWatch.elapsedMilliseconds}ms '
        'dim=512 norm=${norm.toStringAsFixed(5)} '
        'determinism=${similarity.toStringAsFixed(5)}',
      );
    } finally {
      await provider.dispose();
      try {
        await File(path).delete();
      } catch (_) {}
    }
  });

  testWidgets('REAL Android app: camera stream -> MobileCLIP2 -> product',
      (tester) async {
    CameraController? referenceController;
    ProductRepository? repository;
    String? productId;
    String? referencePath;

    try {
      await AppDatabase.instance.ensureSeeded();
      final directory = await getTemporaryDirectory();

      final cameras = await availableCameras().timeout(
        const Duration(seconds: 30),
      );
      expect(cameras, isNotEmpty, reason: 'Android emulator exposes no camera');

      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      referenceController = CameraController(
        description,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await referenceController!.initialize().timeout(
        const Duration(seconds: 30),
      );
      final reference = await referenceController!.takePicture().timeout(
        const Duration(seconds: 30),
      );
      referencePath = '${directory.path}/ci_live_scanner_reference.jpg';
      await File(reference.path).copy(referencePath);
      await referenceController!.dispose();
      referenceController = null;

      repository = ProductRepository();
      final product = await repository!.createProduct(
        name: 'CI Camera Product',
        category: 'Integration Test',
        purchasePrice: 1,
        sellingPrice: 2,
        quantity: 1,
        imageUrl: referencePath,
      );
      productId = product.id;

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true),
          home: const LiveScannerScreen(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(CameraPreview), findsOneWidget);

      final deadline = DateTime.now().add(const Duration(seconds: 120));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.text('CI Camera Product').evaluate().isNotEmpty) {
          break;
        }
      }

      expect(
        find.text('CI Camera Product'),
        findsWidgets,
        reason:
            'LiveScannerScreen did not confirm the enrolled product from the real emulator camera stream.',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // ignore: avoid_print
      print('REAL APP CAMERA E2E PASS: camera -> MobileCLIP2 -> product confirmation');
    } finally {
      await referenceController?.dispose();
      if (productId != null) {
        try {
          await repository?.deleteProduct(productId!);
        } catch (_) {}
      }
      if (referencePath != null) {
        try {
          await File(referencePath!).delete();
        } catch (_) {}
      }
    }
  });
}
