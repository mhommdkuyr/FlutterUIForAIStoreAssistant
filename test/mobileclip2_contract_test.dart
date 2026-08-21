import 'dart:typed_data';

import 'package:ai_store_assistant/shared/services/visual_embedding_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _actualMetadata() => {
      'model_name': 'MobileCLIP2-S0-Vision',
      'embedding_dimension': 512,
      'input_size': [224, 224],
      'normalization': {
        'mean': [0.0, 0.0, 0.0],
        'std': [1.0, 1.0, 1.0],
      },
      'l2_normalized_required': true,
      'onnx_opset': 18,
    };

void main() {
  group('MobileClip2ModelContract actual metadata schema', () {
    test('parses [224,224] input_size and official S0 normalization', () {
      final contract = MobileClip2ModelContract.fromJson(_actualMetadata());
      expect(contract.inputSize, 224);
      expect(contract.layout, isNull);
      expect(contract.mean, [0.0, 0.0, 0.0]);
      expect(contract.std, [1.0, 1.0, 1.0]);
    });

    test('requires 512 dimension, l2_normalized_required=true, and opset=18', () {
      final contract = MobileClip2ModelContract.fromJson(_actualMetadata());
      expect(contract.embeddingDimensions, 512);
      expect(contract.l2NormalizedRequired, isTrue);
      expect(contract.onnxOpset, 18);
    });

    test('verified metadata passes', () {
      expect(() => MobileClip2ModelContract.fromJson(_actualMetadata()), returnsNormally);
    });

    test('[256,256] input_size fails closed', () {
      expect(() => MobileClip2ModelContract.fromJson(_actualMetadata()..['input_size'] = [256, 256]), throwsStateError);
    });

    test('modified mean fails closed', () {
      final invalid = _actualMetadata();
      invalid['normalization'] = {
        'mean': [0.000001, 0.0, 0.0],
        'std': [1.0, 1.0, 1.0],
      };
      expect(() => MobileClip2ModelContract.fromJson(invalid), throwsStateError);
    });

    test('modified std fails closed', () {
      final invalid = _actualMetadata();
      invalid['normalization'] = {
        'mean': [0.0, 0.0, 0.0],
        'std': [1.000001, 1.0, 1.0],
      };
      expect(() => MobileClip2ModelContract.fromJson(invalid), throwsStateError);
    });

    test('invalid input_size fails closed', () {
      expect(() => MobileClip2ModelContract.fromJson(_actualMetadata()..['input_size'] = [224, 256]), throwsStateError);
      expect(() => MobileClip2ModelContract.fromJson(_actualMetadata()..['input_size'] = [224]), throwsStateError);
    });

    test('invalid mean/std fails closed', () {
      final invalidMean = _actualMetadata();
      invalidMean['normalization'] = {
        'mean': [0.1, double.nan, 0.3],
        'std': [0.2, 0.2, 0.2],
      };
      expect(() => MobileClip2ModelContract.fromJson(invalidMean), throwsStateError);

      final invalidStd = _actualMetadata();
      invalidStd['normalization'] = {
        'mean': [0.1, 0.2, 0.3],
        'std': [1.0, 0.0, 1.0],
      };
      expect(() => MobileClip2ModelContract.fromJson(invalidStd), throwsStateError);
    });

    test('invalid dimension fails closed', () {
      expect(() => MobileClip2ModelContract.fromJson(_actualMetadata()..['embedding_dimension'] = 384), throwsStateError);
    });

    test('invalid l2 flag fails closed', () {
      expect(() => MobileClip2ModelContract.fromJson(_actualMetadata()..['l2_normalized_required'] = false), throwsStateError);
    });

    test('invalid opset fails closed', () {
      expect(() => MobileClip2ModelContract.fromJson(_actualMetadata()..['onnx_opset'] = 17), throwsStateError);
    });
  });

  group('MobileCLIP2 graph shape helpers', () {
    test('[1,3,224,224] is NCHW', () {
      expect(MobileClip2ModelContract.detectGraphLayout([1, 3, 224, 224], 224), 'NCHW');
    });

    test('[1,224,224,3] is NHWC', () {
      expect(MobileClip2ModelContract.detectGraphLayout([1, 224, 224, 3], 224), 'NHWC');
    });

    test('dynamic batch [-1,3,224,224] is valid NCHW', () {
      expect(MobileClip2ModelContract.detectGraphLayout([-1, 3, 224, 224], 224), 'NCHW');
    });

    test('invalid input graph shape fails closed', () {
      expect(() => MobileClip2ModelContract.detectGraphLayout([1, 3, 256, 256], 224), throwsStateError);
    });

    test('static output shape [1,512] is valid', () {
      expect(MobileClip2ModelContract.isSingleEmbeddingShape([1, 512], 512), isTrue);
    });

    test('dynamic output shape [-1,512] is valid', () {
      expect(MobileClip2ModelContract.isSingleEmbeddingShape([-1, 512], 512), isTrue);
    });

    test('invalid output shape fails closed', () {
      expect(MobileClip2ModelContract.isSingleEmbeddingShape([512], 512), isFalse);
      expect(MobileClip2ModelContract.isSingleEmbeddingShape([2, 512], 512), isFalse);
      expect(MobileClip2ModelContract.isSingleEmbeddingShape([1, 1, 512], 512), isFalse);
      expect(MobileClip2ModelContract.isSingleEmbeddingShape([1, 256, 2], 512), isFalse);
      expect(MobileClip2ModelContract.isSingleEmbeddingShape([1, 7, 512], 512), isFalse);
    });
  });

  group('VisualEmbeddingProvider fail-closed diagnostics', () {
    test('unavailable backend exposes safe embedding length', () {
      final provider = VisualEmbeddingProvider();
      expect(provider.isOnnxActive, isFalse);
      expect(provider.embeddingLength, 0);
      expect(provider.similarity(Uint8List(0), Uint8List(0)), 0.0);
    });

    test('unavailable backend fails closed instead of using diagnostics ahash', () async {
      final provider = VisualEmbeddingProvider();
      expect(await provider.embedFile('does-not-exist.jpg'), isNull);
      expect(provider.modelVersion, 'visual_engine_unavailable');
      expect(provider.diagnosticsAHash.modelVersion, startsWith('ahash_'));
    });
  });
}
