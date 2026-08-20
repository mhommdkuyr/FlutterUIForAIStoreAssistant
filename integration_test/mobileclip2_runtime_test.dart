import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:ai_store_assistant/shared/services/fast_visual_embedding_service.dart';

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

    // Keep these visible in the integration logs for physical-device
    // benchmarking and future regression comparisons.
    // ignore: avoid_print
    print('MobileCLIP2 initialization=${initializationMs}ms firstInference=${firstMs}ms total=${totalMs}ms');

    await provider.dispose();
    await File(path).delete();
  });
}
