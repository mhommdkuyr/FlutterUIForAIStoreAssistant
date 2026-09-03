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

  testWidgets(
    'REAL Android vision E2E: MobileCLIP2 + camera stream + product confirmation',
    (tester) async {
      CameraController? referenceController;
      ProductRepository? repository;
      String? productId;
      String? referencePath;
      final provider = FastMobileVisionEmbeddingService();

      try {
        stdout.writeln('E2E STEP 1: initialize real MobileCLIP2');
        final initWatch = Stopwatch()..start();
        await provider.initialize().timeout(const Duration(seconds: 60));
        initWatch.stop();
        expect(provider.isInitialized, isTrue);
        expect(provider.isOnnxActive, isTrue);
        expect(provider.embeddingLength, 2048);
        expect(provider.modelVersion, contains('mobileclip2'));
        stdout.writeln(
          'E2E MobileCLIP2 INIT PASS: ${initWatch.elapsedMilliseconds}ms',
        );

        stdout.writeln('E2E STEP 2: verify one real ONNX inference');
        final directory = await getTemporaryDirectory();
        final smokePath = '${directory.path}/mobileclip2_e2e_smoke.png';
        final image = img.Image(width: 224, height: 224);
        for (var y = 0; y < 224; y++) {
          for (var x = 0; x < 224; x++) {
            final r = (40 + (x * 3) + (y % 17)) % 220;
            final g = (70 + (y * 2) + (x % 23)) % 210;
            final b = (110 + x + y) % 190;
            image.setPixelRgb(x, y, r, g, b);
          }
        }
        await File(smokePath).writeAsBytes(img.encodePng(image));
        final inferenceWatch = Stopwatch()..start();
        final embedding = await provider.embedFile(smokePath).timeout(
          const Duration(seconds: 60),
        );
        inferenceWatch.stop();
        expect(embedding, isNotNull);
        expect(embedding!.length, 2048);
        final vector = embedding.buffer.asFloat32List();
        expect(vector.length, 512);
        expect(vector.every((v) => v.isFinite), isTrue);
        var normSquared = 0.0;
        for (final value in vector) {
          normSquared += value * value;
        }
        expect(sqrt(normSquared), closeTo(1.0, 0.01));
        await File(smokePath).delete();
        stdout.writeln(
          'E2E MobileCLIP2 INFERENCE PASS: ${inferenceWatch.elapsedMilliseconds}ms dim=512',
        );

        stdout.writeln('E2E STEP 3: obtain real emulator camera reference frame');
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
        stdout.writeln('E2E CAMERA REFERENCE PASS: $referencePath');

        stdout.writeln('E2E STEP 4: enroll reference image into local product DB');
        await AppDatabase.instance.ensureSeeded();
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
        stdout.writeln('E2E ENROLL PASS: productId=$productId');

        stdout.writeln('E2E STEP 5: launch actual LiveScannerScreen and camera stream');
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(useMaterial3: true),
            home: const LiveScannerScreen(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(CameraPreview), findsOneWidget);
        stdout.writeln('E2E UI CAMERA PREVIEW PASS');

        final deadline = DateTime.now().add(const Duration(seconds: 150));
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 500));
          if (find.text('CI Camera Product').evaluate().isNotEmpty) break;
        }

        expect(
          find.text('CI Camera Product'),
          findsWidgets,
          reason:
              'LiveScannerScreen did not confirm the enrolled product from the real emulator camera stream.',
        );
        stdout.writeln(
          '✅ REAL APP CAMERA E2E PASS: camera stream -> MobileCLIP2 -> product confirmation',
        );

        stdout.writeln('E2E STEP 6: explicitly unmount scanner and dispose native resources');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        stdout.writeln('✅ REAL ANDROID VISION E2E PASS');
      } finally {
        await referenceController?.dispose();
        await provider.dispose();
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
    },
  );
}
