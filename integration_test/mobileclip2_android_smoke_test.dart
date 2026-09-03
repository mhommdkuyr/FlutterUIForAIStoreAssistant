import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:ai_store_assistant/shared/services/fast_visual_embedding_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('REAL MobileCLIP2 Android smoke: ONNX init + 512D embedding',
      (tester) async {
    final provider = FastMobileVisionEmbeddingService();
    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/mobileclip2_smoke.png';
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
      await provider.initialize().timeout(const Duration(seconds: 45));
      final initMs = initWatch.elapsedMilliseconds;

      expect(provider.isOnnxActive, isTrue);
      expect(provider.embeddingLength, 2048);
      expect(provider.modelVersion, contains('mobileclip2'));

      final inferenceWatch = Stopwatch()..start();
      final first = await provider.embedFile(path).timeout(
        const Duration(seconds: 30),
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
      expect(sqrt(normSquared), closeTo(1.0, 0.01));

      final second = await provider.embedFile(path).timeout(
        const Duration(seconds: 30),
      );
      expect(second, isNotNull);
      final similarity = provider.similarity(first, second!);
      expect(similarity, greaterThan(0.999));

      // ignore: avoid_print
      print(
        'REAL MobileCLIP2 SMOKE PASS: init=${initMs}ms '
        'firstInference=${inferenceWatch.elapsedMilliseconds}ms '
        'dim=512 norm=${sqrt(normSquared).toStringAsFixed(5)} '
        'determinism=${similarity.toStringAsFixed(5)}',
      );
    } finally {
      await provider.dispose();
      try {
        await File(path).delete();
      } catch (_) {}
    }
  });
}
