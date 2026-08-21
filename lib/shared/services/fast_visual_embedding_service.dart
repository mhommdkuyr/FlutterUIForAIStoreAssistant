import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'visual_embedding_service.dart';

/// MobileCLIP2 runtime specialized for continuous Android live scanning.
class FastMobileVisionEmbeddingService implements VisualEmbeddingService {
  static const assetPath =
      'assets/models/mobileclip2/mobileclip2_s0_vision.onnx';
  static const externalDataAssetPath =
      'assets/models/mobileclip2/mobileclip2_s0_vision.onnx.data';
  static const metadataAssetPath =
      'assets/models/mobileclip2/model_metadata.json';
  static const modelContractVersion =
      'mobileclip2_s0_vision_onnx_v3_fastscan_official_preprocess';

  final OnnxRuntime _runtime = OnnxRuntime();
  OrtSession? _session;
  MobileClip2ModelContract? _contract;
  String? _inputName;
  String? _outputName;
  String? _runtimeModelPath;
  String? _runtimeExternalDataPath;
  Object? _initializationError;
  Object? _lastInferenceError;
  Future<void> _inferenceQueue = Future<void>.value();
  bool _disposed = false;

  bool get isInitialized => _session != null;
  Object? get initializationError => _initializationError;
  Object? get lastInferenceError => _lastInferenceError;
  MobileClip2ModelContract? get contract => _contract;

  @override
  int get embeddingLength => isInitialized ? 512 * 4 : 0;

  @override
  String get modelVersion => modelContractVersion;

  @override
  double get recommendedMinConfidence => 0.45;

  Future<void> initialize() async {
    _initializationError = null;
    _disposed = false;
    try {
      final raw = await rootBundle.loadString(metadataAssetPath);
      final metadata = jsonDecode(raw) as Map<String, dynamic>;
      final inputSize = metadata['input_size'];
      final normalization = metadata['normalization'];
      if (inputSize is! List || inputSize.length != 2 ||
          inputSize[0] != 224 || inputSize[1] != 224 ||
          normalization is! Map<String, dynamic>) {
        throw StateError('MobileCLIP2-S0 runtime metadata is invalid.');
      }
      final mean = (normalization['mean'] as List?)?.map((v) => (v as num).toDouble()).toList();
      final std = (normalization['std'] as List?)?.map((v) => (v as num).toDouble()).toList();
      if (mean == null || std == null || mean.length != 3 || std.length != 3 ||
          mean.any((v) => v != 0.0) || std.any((v) => v != 1.0) ||
          metadata['embedding_dimension'] != 512 ||
          metadata['l2_normalized_required'] != true ||
          metadata['onnx_opset'] != 18) {
        throw StateError(
          'MobileCLIP2-S0 runtime metadata must use 224x224, RGB [0,1], '
          'mean=(0,0,0), std=(1,1,1), 512-D output and opset 18.',
        );
      }
      _contract = MobileClip2ModelContract(
        inputSize: 224,
        mean: const [0.0, 0.0, 0.0],
        std: const [1.0, 1.0, 1.0],
        embeddingDimensions: 512,
        l2NormalizedRequired: true,
        onnxOpset: 18,
      );

      final modelAsset = await rootBundle.load(assetPath);
      final dataAsset = await rootBundle.load(externalDataAssetPath);
      if (modelAsset.lengthInBytes == 0 || dataAsset.lengthInBytes == 0) {
        throw StateError('MobileCLIP2 model or external data is empty.');
      }

      final runtimeRoot = Directory(
        '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}mobileclip2_fast',
      );
      await runtimeRoot.create(recursive: true);
      final modelFile = File(
        '${runtimeRoot.path}${Platform.pathSeparator}mobileclip2_s0_vision.onnx',
      );
      final dataFile = File(
        '${runtimeRoot.path}${Platform.pathSeparator}mobileclip2_s0_vision.onnx.data',
      );

      await modelFile.writeAsBytes(
        modelAsset.buffer.asUint8List(
          modelAsset.offsetInBytes,
          modelAsset.lengthInBytes,
        ),
        flush: true,
      );
      await dataFile.writeAsBytes(
        dataAsset.buffer.asUint8List(
          dataAsset.offsetInBytes,
          dataAsset.lengthInBytes,
        ),
        flush: true,
      );
      _runtimeModelPath = modelFile.path;
      _runtimeExternalDataPath = dataFile.path;

      final availableProviders = await _runtime.getAvailableProviders();
      final providers = <OrtProvider>[
        if (availableProviders.contains(OrtProvider.XNNPACK))
          OrtProvider.XNNPACK,
        OrtProvider.CPU,
      ];
      final options = OrtSessionOptions(
        intraOpNumThreads: 4,
        interOpNumThreads: 1,
        useArena: true,
        providers: providers,
      );

      final session = await _runtime.createSession(
        modelFile.path,
        options: options,
      );
      try {
        final inputNames = session.inputNames;
        final outputNames = session.outputNames;
        if (inputNames.length != 1 || outputNames.length != 1) {
          throw StateError(
            'MobileCLIP2 fast runtime must expose exactly one input and one output.',
          );
        }
        _inputName = inputNames.single;
        _outputName = outputNames.single;

        final inputInfo = await session.getInputInfo();
        final outputInfo = await session.getOutputInfo();
        final inputShape = _readShape(inputInfo, _inputName!, 'input');
        final outputShape = _readShape(outputInfo, _outputName!, 'output');
        final layout = MobileClip2ModelContract.detectGraphLayout(
          inputShape,
          224,
        );
        if (!MobileClip2ModelContract.isSingleEmbeddingShape(
          outputShape,
          512,
        )) {
          throw StateError(
            'MobileCLIP2 output shape $outputShape must be [1,512].',
          );
        }
        _contract = _contract!.withGraphLayout(layout);

        await _smokeTest(session);
        _session = session;
      } catch (_) {
        await session.close();
        rethrow;
      }
    } catch (error) {
      _initializationError = error;
      _session = null;
      rethrow;
    }
  }

  List<int> _readShape(
    List<Map<String, dynamic>> infos,
    String name,
    String label,
  ) {
    Map<String, dynamic>? info;
    for (final item in infos) {
      if (item['name'] == name) {
        info = item;
        break;
      }
    }
    info ??= infos.length == 1 ? infos.single : null;
    if (info == null) {
      throw StateError('MobileCLIP2 $label info missing for $name.');
    }
    final shape = info['shape'];
    if (shape is! List || shape.isEmpty) {
      throw StateError('MobileCLIP2 $label shape is unavailable.');
    }
    return shape.map((value) {
      if (value is! num) {
        throw StateError(
          'MobileCLIP2 $label shape contains a non-numeric dimension: $shape',
        );
      }
      return value.toInt();
    }).toList(growable: false);
  }

  Future<void> _smokeTest(OrtSession session) async {
    final contract = _requireContract();
    final shape = contract.layout == 'NHWC'
        ? [1, 224, 224, 3]
        : [1, 3, 224, 224];
    final input = await OrtValue.fromList(
      Float32List(224 * 224 * 3),
      shape,
    );
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({_inputName!: input});
      final output = outputs[_outputName!];
      if (output == null) {
        throw StateError('MobileCLIP2 smoke test returned no output.');
      }
      final values = (await output.asFlattenedList()).cast<num>();
      if (values.length != 512 || values.any((value) => !value.toDouble().isFinite)) {
        throw StateError('MobileCLIP2 smoke test returned invalid output.');
      }
    } finally {
      await input.dispose();
      if (outputs != null) {
        for (final output in outputs.values) {
          await output.dispose();
        }
      }
    }
  }

  @override
  Future<Uint8List?> embedFile(String path) async {
    final session = _session;
    if (session == null) {
      _lastInferenceError =
          StateError('MobileCLIP2 fast ONNX session is unavailable.');
      return null;
    }
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) return null;
      final oriented = img.bakeOrientation(decoded);
      final cropSize = min(oriented.width, oriented.height);
      final cropped = img.copyCrop(
        oriented,
        x: (oriented.width - cropSize) ~/ 2,
        y: (oriented.height - cropSize) ~/ 2,
        width: cropSize,
        height: cropSize,
      );
      final resized = img.copyResize(
        cropped,
        width: 224,
        height: 224,
        interpolation: img.Interpolation.linear,
      );
      return _run(_imageTensor(resized));
    } catch (error) {
      _lastInferenceError = error;
      return null;
    }
  }

  Future<Uint8List?> embedFrameWithRotation(
    CameraImage image, {
    int rotationDegrees = 0,
  }) async {
    if (_session == null) {
      _lastInferenceError =
          StateError('MobileCLIP2 fast ONNX session is unavailable.');
      return null;
    }
    try {
      final tensor = switch (image.format.group) {
        ImageFormatGroup.yuv420 => _yuvTensor(image, rotationDegrees),
        ImageFormatGroup.bgra8888 => _bgraTensor(image, rotationDegrees),
        _ => throw StateError(
            'Unsupported camera image format: ${image.format.group}',
          ),
      };
      return _run(tensor);
    } catch (error) {
      _lastInferenceError = error;
      return null;
    }
  }

  @override
  Future<Uint8List?> embedFrame(CameraImage image) =>
      embedFrameWithRotation(image);

  Float32List _imageTensor(img.Image image) {
    final tensor = Float32List(224 * 224 * 3);
    for (var y = 0; y < 224; y++) {
      for (var x = 0; x < 224; x++) {
        final pixel = image.getPixel(x, y);
        _writePixel(
          tensor,
          y,
          x,
          pixel.r.toDouble(),
          pixel.g.toDouble(),
          pixel.b.toDouble(),
        );
      }
    }
    return tensor;
  }

  Float32List _yuvTensor(CameraImage image, int rotationDegrees) {
    final size = 224;
    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0 || image.planes.length < 3) {
      throw StateError('Invalid YUV420 camera frame dimensions/planes.');
    }
    final cropSize = min(width, height);
    final left = (width - cropSize) ~/ 2;
    final top = (height - cropSize) ~/ 2;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final uvStep = uPlane.bytesPerPixel ?? 1;
    final rotation = ((rotationDegrees % 360) + 360) % 360;
    final tensor = Float32List(size * size * 3);

    for (var outY = 0; outY < size; outY++) {
      for (var outX = 0; outX < size; outX++) {
        final p = outX * cropSize ~/ size;
        final q = outY * cropSize ~/ size;
        late final int sx;
        late final int sy;
        switch (rotation) {
          case 90:
            sx = left + q;
            sy = top + cropSize - 1 - p;
            break;
          case 180:
            sx = left + cropSize - 1 - p;
            sy = top + cropSize - 1 - q;
            break;
          case 270:
            sx = left + cropSize - 1 - q;
            sy = top + p;
            break;
          default:
            sx = left + p;
            sy = top + q;
        }
        final x = sx.clamp(0, width - 1);
        final y = sy.clamp(0, height - 1);
        final yIndex = y * yPlane.bytesPerRow + x;
        final uvRow = y >> 1;
        final uvCol = x >> 1;
        final uIndex = uvRow * uPlane.bytesPerRow + uvCol * uvStep;
        final vIndex = uvRow * vPlane.bytesPerRow + uvCol * uvStep;
        final yValue = yIndex < yPlane.bytes.length ? yPlane.bytes[yIndex] : 0;
        final uValue = uIndex < uPlane.bytes.length ? uPlane.bytes[uIndex] - 128 : 0;
        final vValue = vIndex < vPlane.bytes.length ? vPlane.bytes[vIndex] - 128 : 0;
        _writePixel(
          tensor,
          outY,
          outX,
          (yValue + 1.402 * vValue).clamp(0, 255).toDouble(),
          (yValue - 0.344136 * uValue - 0.714136 * vValue)
              .clamp(0, 255)
              .toDouble(),
          (yValue + 1.772 * uValue).clamp(0, 255).toDouble(),
        );
      }
    }
    return tensor;
  }

  Float32List _bgraTensor(CameraImage image, int rotationDegrees) {
    final size = 224;
    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0 || image.planes.isEmpty) {
      throw StateError('Invalid BGRA camera frame dimensions/planes.');
    }
    final cropSize = min(width, height);
    final left = (width - cropSize) ~/ 2;
    final top = (height - cropSize) ~/ 2;
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final rotation = ((rotationDegrees % 360) + 360) % 360;
    final tensor = Float32List(size * size * 3);

    for (var outY = 0; outY < size; outY++) {
      for (var outX = 0; outX < size; outX++) {
        final p = outX * cropSize ~/ size;
        final q = outY * cropSize ~/ size;
        late final int sx;
        late final int sy;
        switch (rotation) {
          case 90:
            sx = left + q;
            sy = top + cropSize - 1 - p;
            break;
          case 180:
            sx = left + cropSize - 1 - p;
            sy = top + cropSize - 1 - q;
            break;
          case 270:
            sx = left + cropSize - 1 - q;
            sy = top + p;
            break;
          default:
            sx = left + p;
            sy = top + q;
        }
        final x = sx.clamp(0, width - 1);
        final y = sy.clamp(0, height - 1);
        final base = y * plane.bytesPerRow + x * 4;
        if (base < 0 || base + 3 >= bytes.length) {
          _writePixel(tensor, outY, outX, 0, 0, 0);
          continue;
        }
        _writePixel(
          tensor,
          outY,
          outX,
          bytes[base + 2].toDouble(),
          bytes[base + 1].toDouble(),
          bytes[base].toDouble(),
        );
      }
    }
    return tensor;
  }

  void _writePixel(
    Float32List tensor,
    int row,
    int column,
    double r,
    double g,
    double b,
  ) {
    final rv = r / 255.0;
    final gv = g / 255.0;
    final bv = b / 255.0;
    final base = row * 224 + column;
    if (_contract?.layout == 'NHWC') {
      final offset = base * 3;
      tensor[offset] = rv;
      tensor[offset + 1] = gv;
      tensor[offset + 2] = bv;
    } else {
      final planeSize = 224 * 224;
      tensor[base] = rv;
      tensor[planeSize + base] = gv;
      tensor[(planeSize * 2) + base] = bv;
    }
  }

  Future<Uint8List?> _run(Float32List tensor) {
    if (_disposed) return Future.value(null);
    final completer = Completer<Uint8List?>();
    _inferenceQueue = _inferenceQueue.then((_) async {
      try {
        completer.complete(await _runLocked(tensor));
      } catch (error, stackTrace) {
        _lastInferenceError = error;
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future.catchError((_) => null);
  }

  Future<Uint8List?> _runLocked(Float32List tensor) async {
    final session = _session;
    final inputName = _inputName;
    final outputName = _outputName;
    final contract = _contract;
    if (session == null || inputName == null || outputName == null || contract == null) {
      _lastInferenceError =
          StateError('MobileCLIP2 fast ONNX session is unavailable.');
      return null;
    }

    final shape = contract.layout == 'NHWC'
        ? [1, 224, 224, 3]
        : [1, 3, 224, 224];
    final input = await OrtValue.fromList(tensor, shape);
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({inputName: input});
      final output = outputs[outputName];
      if (output == null) {
        throw StateError('MobileCLIP2 fast ONNX output is missing.');
      }
      final values = (await output.asFlattenedList())
          .cast<num>()
          .map((value) => value.toDouble())
          .toList(growable: false);
      if (values.length != 512 || values.any((value) => !value.isFinite)) {
        throw StateError(
          'MobileCLIP2 fast inference returned an invalid 512-D embedding.',
        );
      }

      final embedding = Float32List.fromList(values);
      var norm = 0.0;
      for (final value in embedding) {
        norm += value * value;
      }
      norm = sqrt(norm);
      if (norm < 1e-10) {
        throw StateError('MobileCLIP2 fast inference returned a zero vector.');
      }
      for (var i = 0; i < embedding.length; i++) {
        embedding[i] /= norm;
      }
      _lastInferenceError = null;
      return embedding.buffer.asUint8List();
    } finally {
      await input.dispose();
      if (outputs != null) {
        for (final output in outputs.values) {
          await output.dispose();
        }
      }
    }
  }

  MobileClip2ModelContract _requireContract() {
    final contract = _contract;
    if (contract == null) {
      throw StateError('MobileCLIP2 fast model contract is unavailable.');
    }
    return contract;
  }

  @override
  double similarity(Uint8List a, Uint8List b) {
    if (a.length != 2048 || b.length != 2048) return 0.0;
    final fa = a.buffer.asFloat32List(a.offsetInBytes, 512);
    final fb = b.buffer.asFloat32List(b.offsetInBytes, 512);
    var dot = 0.0;
    for (var i = 0; i < 512; i++) {
      dot += fa[i] * fb[i];
    }
    return dot.clamp(0.0, 1.0);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _inferenceQueue = _inferenceQueue.then((_) async {
      await _session?.close();
      _session = null;
    });
    await _inferenceQueue;

    for (final path in <String>[
      if (_runtimeModelPath != null) _runtimeModelPath!,
      if (_runtimeExternalDataPath != null) _runtimeExternalDataPath!,
    ]) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
    _runtimeModelPath = null;
    _runtimeExternalDataPath = null;
  }
}

class FastVisualEmbeddingProvider extends VisualEmbeddingProvider {
  final FastMobileVisionEmbeddingService _fast =
      FastMobileVisionEmbeddingService();
  bool _ready = false;

  @override
  bool get isOnnxActive => _ready;

  @override
  Object? get initializationError => _fast.initializationError;

  @override
  Object? get lastInferenceError => _fast.lastInferenceError;

  @override
  String get modelVersion => _fast.modelVersion;

  @override
  double get recommendedMinConfidence => _fast.recommendedMinConfidence;

  @override
  int get embeddingLength => _fast.embeddingLength;

  @override
  Future<void> initialize() async {
    try {
      await _fast.initialize();
      _ready = true;
    } catch (_) {
      _ready = false;
      rethrow;
    }
  }

  @override
  Future<Uint8List?> embedFile(String path) =>
      _ready ? _fast.embedFile(path) : Future.value(null);

  @override
  Future<Uint8List?> embedFrame(CameraImage image) =>
      _ready ? _fast.embedFrame(image) : Future.value(null);

  Future<Uint8List?> embedFrameWithRotation(
    CameraImage image, {
    required int rotationDegrees,
  }) =>
      _ready
          ? _fast.embedFrameWithRotation(
              image,
              rotationDegrees: rotationDegrees,
            )
          : Future.value(null);

  @override
  double similarity(Uint8List a, Uint8List b) =>
      _ready ? _fast.similarity(a, b) : 0.0;

  @override
  Future<void> dispose() async {
    _ready = false;
    await _fast.dispose();
  }
}
