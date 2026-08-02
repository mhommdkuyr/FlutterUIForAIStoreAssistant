/// On-device vision provider backed by ONNX Runtime mobile.
///
/// ## Status — Step 1 stub
/// This file contains a compile-safe stub. The full ONNX Runtime implementation
/// is planned for Step 2 (AI integration milestone).
///
/// When Step 2 is ready:
/// 1. Add `onnxruntime: ^1.1.1` to pubspec.yaml.
/// 2. Drop-replace this file with the full implementation (see git history).
/// 3. Drop the ONNX model + labels into `<app-docs>/models/vision/`.
///
/// [VisionCommandRouter] will automatically route to [ManualFallbackVisionProvider]
/// while [isAvailable] returns `false`.
library;

import 'vision_provider.dart';

class OnnxVisionProvider implements VisionProvider {
  const OnnxVisionProvider();

  @override
  String get name => 'OnnxVision';

  /// Always `false` in the Step 1 stub — routes to [ManualFallbackVisionProvider].
  @override
  bool get isAvailable => false;

  @override
  Future<VisionResult> analyzeImage(List<int> imageBytes) async {
    return const VisionResult.unrecognised(
      'ONNX vision is not enabled in this build. '
      'Please enter product details manually.',
    );
  }
}
