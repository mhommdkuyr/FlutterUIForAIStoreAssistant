import 'dart:typed_data';

import 'package:ai_store_assistant/shared/services/visual_embedding_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _validMetadata() => {
      'model_format': 'ONNX',
      'onnx_opset': 18,
      'input_shape': [1, 3, 224, 224],
      'input_layout': 'NCHW',
      'embedding_dimension': 512,
      'preprocessing': {
        'mean': [0.48145466, 0.4578275, 0.40821073],
        'std': [0.26862954, 0.26130258, 0.27577711],
      },
    };

void main() {
  group('MobileClip2ModelContract', () {
    test('valid metadata parses without mutating metadata layout from graph', () {
      final contract = MobileClip2ModelContract.fromJson(_validMetadata());

      expect(contract.inputSize, 224);
      expect(contract.layout, 'NCHW');
      expect(contract.embeddingDimensions, 512);
      expect(contract.mean, hasLength(3));
      expect(contract.std, hasLength(3));
    });

    test('invalid metadata fails closed', () {
      final metadata = _validMetadata()..['embedding_dimension'] = 384;

      expect(
        () => MobileClip2ModelContract.fromJson(metadata),
        throwsStateError,
      );
    });

    test('invalid mean/std fail closed', () {
      final metadata = _validMetadata();
      metadata['preprocessing'] = {
        'mean': [0.1, double.nan, 0.3],
        'std': [0.2, 0.2, 0.2],
      };

      expect(
        () => MobileClip2ModelContract.fromJson(metadata),
        throwsStateError,
      );
    });

    test('output shape must represent exactly one 512-dimensional embedding', () {
      expect(
        MobileClip2ModelContract.isSingleEmbeddingShape([1, 512], 512),
        isTrue,
      );
      expect(
        MobileClip2ModelContract.isSingleEmbeddingShape([512], 512),
        isTrue,
      );
      expect(
        MobileClip2ModelContract.isSingleEmbeddingShape([2, 512], 512),
        isFalse,
      );
      expect(
        MobileClip2ModelContract.isSingleEmbeddingShape([1, 7, 512], 512),
        isFalse,
      );
    });
  });

  group('VisualEmbeddingProvider fail-closed diagnostics', () {
    test('unavailable backend exposes safe embedding length', () {
      final provider = VisualEmbeddingProvider();

      expect(provider.isOnnxActive, isFalse);
      expect(provider.embeddingLength, 0);
      expect(provider.similarity(Uint8List(0), Uint8List(0)), 0.0);
    });
  });
}
