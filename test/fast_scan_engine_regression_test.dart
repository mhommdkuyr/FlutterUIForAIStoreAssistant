import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_store_assistant/shared/services/fast_visual_embedding_service.dart';
import 'package:ai_store_assistant/shared/services/visual_embedding_service.dart';

void main() {
  test('dynamic batch graph contract is accepted but concrete inference stays batch one', () {
    expect(
      MobileClip2ModelContract.detectGraphLayout([-1, 3, 224, 224], 224),
      'NCHW',
    );
    expect(
      MobileClip2ModelContract.detectGraphLayout([-1, 224, 224, 3], 224),
      'NHWC',
    );
  });

  test('only exact 512-dimensional batched embeddings are accepted', () {
    expect(MobileClip2ModelContract.isSingleEmbeddingShape([1, 512], 512), isTrue);
    expect(MobileClip2ModelContract.isSingleEmbeddingShape([-1, 512], 512), isTrue);
    expect(MobileClip2ModelContract.isSingleEmbeddingShape([2, 512], 512), isFalse);
    expect(MobileClip2ModelContract.isSingleEmbeddingShape([1, 256, 2], 512), isFalse);
  });

  test('fast provider is fail-closed before initialization and rejects malformed embeddings', () {
    final provider = FastVisualEmbeddingProvider();
    expect(provider.isOnnxActive, isFalse);
    expect(provider.embeddingLength, 0);
    expect(provider.similarity(Uint8List(2048), Uint8List(1024)), 0.0);
  });
}
