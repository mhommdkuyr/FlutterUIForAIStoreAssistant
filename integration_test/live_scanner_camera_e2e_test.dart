import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:ai_store_assistant/core/database/app_database.dart';
import 'package:ai_store_assistant/features/product_scanner/screens/live_scanner_screen.dart';
import 'package:ai_store_assistant/shared/repositories/product_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'REAL APP: live scanner opens camera, streams frames and confirms a product',
    (tester) async {
      CameraController? referenceController;
      ProductRepository? repository;
      String? productId;
      String? referencePath;
      var passed = false;

      try {
        await AppDatabase.instance.ensureSeeded();
        final directory = await getTemporaryDirectory();

        final cameras = await availableCameras().timeout(
          const Duration(seconds: 20),
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
          const Duration(seconds: 20),
        );
        final reference = await referenceController!.takePicture().timeout(
          const Duration(seconds: 20),
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
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.byType(CameraPreview), findsOneWidget);

        final deadline = DateTime.now().add(const Duration(seconds: 90));
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
              'The real LiveScannerScreen never confirmed the product from the emulator camera stream.',
        );

        // Explicitly unmount the real scanner so its camera stream, pipeline,
        // timers, animation controllers and native ONNX resources are disposed
        // before the integration-test harness tries to shut down.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();

        passed = true;
        stdout.writeln(
          '✅ REAL APP CAMERA E2E PASS: camera stream -> MobileCLIP2 -> product confirmation',
        );
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

      expect(passed, isTrue);
    },
  );
}
