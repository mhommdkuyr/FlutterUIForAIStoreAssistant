import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_store_assistant/shared/services/fast_visual_embedding_service.dart';
import 'package:ai_store_assistant/shared/services/visual_embedding_service.dart';

void main() {
  test('dynamic MobileCLIP2 batch is accepted', () {
    expect(MobileClip2ModelContract.detectGraphLayout([-1, 3, 224, 224], 224), 'NCHW');
  });

  test('fast provider starts unavailable and exposes the current version', () {
    final provider = FastVisualEmbeddingProvider();
    expect(provider.isOnnxActive, isFalse);
    expect(provider.embeddingLength, 0);
    expect(provider.modelVersion, 'mobileclip2_s0_vision_onnx_v4_fastscan_s0_preprocess');
    expect(provider.similarity(Uint8List(0), Uint8List(0)), 0.0);
  });
}
