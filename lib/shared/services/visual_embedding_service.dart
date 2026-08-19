import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import 'frame_preprocessor.dart';

abstract class VisualEmbeddingService {
  Future<Uint8List?> embedFile(String path);
  Future<Uint8List?> embedFrame(CameraImage image);
  double similarity(Uint8List a, Uint8List b);
  Future<void> dispose() async {}
  int get embeddingLength;
  String get modelVersion;
  double get recommendedMinConfidence;
}

class MobileClip2ModelContract {
  const MobileClip2ModelContract({
    required this.inputSize,
    required this.mean,
    required this.std,
    required this.embeddingDimensions,
    required this.l2NormalizedRequired,
    required this.onnxOpset,
    this.layout,
  });

  final int inputSize;
  final List<double> mean;
  final List<double> std;
  final int embeddingDimensions;
  final bool l2NormalizedRequired;
  final int onnxOpset;
  final String? layout;

  static const expectedEmbeddingDimensions = 512;
  static const expectedOnnxOpset = 18;
  static const expectedInputSize = 224;
  static const expectedMean = [0.48145466, 0.4578275, 0.40821073];
  static const expectedStd = [0.26862954, 0.26130258, 0.27577711];

  factory MobileClip2ModelContract.fromJson(Map<String, dynamic> json) {
    final inputSizeValue = json['input_size'];
    if (inputSizeValue is! List || inputSizeValue.length != 2) {
      throw StateError('MobileCLIP2 metadata input_size must be [width, height].');
    }
    final width = _positiveInt(inputSizeValue[0], 'input_size[0]');
    final height = _positiveInt(inputSizeValue[1], 'input_size[1]');
    if (width != height) {
      throw StateError('MobileCLIP2 metadata input_size must be square, got [$width, $height].');
    }

    final normalization = json['normalization'];
    if (normalization is! Map<String, dynamic>) {
      throw StateError('MobileCLIP2 metadata normalization object is required.');
    }

    final contract = MobileClip2ModelContract(
      inputSize: width,
      mean: _readDoubleArray(normalization, 'mean', positive: false),
      std: _readDoubleArray(normalization, 'std', positive: true),
      embeddingDimensions: _positiveInt(
        json['embedding_dimension'],
        'embedding_dimension',
      ),
      l2NormalizedRequired: _requiredTrue(
        json['l2_normalized_required'],
        'l2_normalized_required',
      ),
      onnxOpset: _positiveInt(json['onnx_opset'], 'onnx_opset'),
    );
    contract.validateMetadata();
    return contract;
  }

  MobileClip2ModelContract withGraphLayout(String graphLayout) {
    final normalizedLayout = graphLayout.toUpperCase();
    if (normalizedLayout != 'NCHW' && normalizedLayout != 'NHWC') {
      throw StateError('MobileCLIP2 graph layout must be NCHW or NHWC.');
    }
    return MobileClip2ModelContract(
      inputSize: inputSize,
      mean: mean,
      std: std,
      embeddingDimensions: embeddingDimensions,
      l2NormalizedRequired: l2NormalizedRequired,
      onnxOpset: onnxOpset,
      layout: normalizedLayout,
    );
  }

  void validateMetadata() {
    if (inputSize <= 0) {
      throw StateError('MobileCLIP2 metadata input_size must be positive.');
    }
    if (inputSize != expectedInputSize) {
      throw StateError(
        'MobileCLIP2 metadata input_size must be '
        '[$expectedInputSize, $expectedInputSize], got [$inputSize, $inputSize].',
      );
    }
    if (mean.length != 3 || mean.any((value) => !value.isFinite)) {
      throw StateError('MobileCLIP2 metadata normalization.mean must contain 3 finite values.');
    }
    if (std.length != 3 || std.any((value) => !value.isFinite || value <= 0)) {
      throw StateError('MobileCLIP2 metadata normalization.std must contain 3 finite positive values.');
    }
    _validateExactDoubles(mean, expectedMean, 'normalization.mean');
    _validateExactDoubles(std, expectedStd, 'normalization.std');
    if (embeddingDimensions != expectedEmbeddingDimensions) {
      throw StateError(
        'MobileCLIP2 metadata embedding_dimension must be '
        '$expectedEmbeddingDimensions, got $embeddingDimensions.',
      );
    }
    if (!l2NormalizedRequired) {
      throw StateError('MobileCLIP2 metadata l2_normalized_required must be true.');
    }
    if (onnxOpset != expectedOnnxOpset) {
      throw StateError(
        'MobileCLIP2 metadata onnx_opset must be '
        '$expectedOnnxOpset, got $onnxOpset.',
      );
    }
  }

  static String detectGraphLayout(List<int> inputShape, int inputSize) {
    if (inputShape.length != 4) {
      throw StateError('MobileCLIP2 input must be rank 4, got $inputShape.');
    }
    if (inputShape[0] != 1) {
      throw StateError('MobileCLIP2 input batch must be 1, got $inputShape.');
    }
    final nchw = inputShape[1] == 3 &&
        inputShape[2] == inputSize &&
        inputShape[3] == inputSize;
    if (nchw) return 'NCHW';
    final nhwc = inputShape[1] == inputSize &&
        inputShape[2] == inputSize &&
        inputShape[3] == 3;
    if (nhwc) return 'NHWC';
    throw StateError(
      'MobileCLIP2 input shape must be [1,3,$inputSize,$inputSize] '
      'or [1,$inputSize,$inputSize,3], got $inputShape.',
    );
  }

  static bool isSingleEmbeddingShape(List<int> shape, int dimension) {
    if (shape.isEmpty || shape.any((value) => value <= 0)) return false;
    var elementCount = 1;
    for (final value in shape) {
      elementCount *= value;
    }
    return elementCount == dimension && shape.where((value) => value == dimension).length == 1;
  }

  static int _positiveInt(Object? value, String fieldName) {
    if (value is int && value > 0) return value;
    throw StateError('MobileCLIP2 metadata $fieldName must be a positive integer.');
  }

  static bool _requiredTrue(Object? value, String fieldName) {
    if (value == true) return true;
    throw StateError('MobileCLIP2 metadata $fieldName must be true.');
  }

  static List<double> _readDoubleArray(
    Map<String, dynamic> source,
    String key, {
    required bool positive,
  }) {
    final value = source[key];
    if (value is! List || value.length != 3) {
      throw StateError('MobileCLIP2 metadata normalization.$key must contain exactly 3 values.');
    }
    final parsed = value.map((item) {
      if (item is! num) {
        throw StateError('MobileCLIP2 metadata normalization.$key contains a non-numeric value.');
      }
      return item.toDouble();
    }).toList(growable: false);
    final invalid = positive
        ? parsed.any((item) => !item.isFinite || item <= 0)
        : parsed.any((item) => !item.isFinite);
    if (invalid) {
      throw StateError(
        positive
            ? 'MobileCLIP2 metadata normalization.$key must contain finite positive values.'
            : 'MobileCLIP2 metadata normalization.$key must contain finite values.',
      );
    }
    return parsed;
  }

  static void _validateExactDoubles(
    List<double> actual,
    List<double> expected,
    String fieldName,
  ) {
    const epsilon = 1e-8;
    for (var i = 0; i < expected.length; i++) {
      if ((actual[i] - expected[i]).abs() > epsilon) {
        throw StateError(
          'MobileCLIP2 metadata $fieldName must match the verified '
          'model contract, got $actual.',
        );
      }
    }
  }
}

class MobileVisionEmbeddingService implements VisualEmbeddingService {
  static const String assetPath = 'assets/models/mobileclip2/mobileclip2_s0_vision.onnx';
  static const String externalDataAssetPath = 'assets/models/mobileclip2/mobileclip2_s0_vision.onnx.data';
  static const String metadataAssetPath = 'assets/models/mobileclip2/model_metadata.json';

  final OnnxRuntime _runtime = OnnxRuntime();
  OrtSession? _session;
  Object? _initializationError;
  Object? _lastInferenceError;
  Future<void> _inferenceQueue = Future<void>.value();
  MobileClip2ModelContract? _contract;
  String? _inputName;
  String? _outputName;

  bool get isInitialized => _session != null;
  Object? get initializationError => _initializationError;
  Object? get lastInferenceError => _lastInferenceError;
  String get inputName => _inputName ?? '';
  String get outputName => _outputName ?? '';
  MobileClip2ModelContract? get contract => _contract;

  Future<void> initialize() async {
    _initializationError = null;
    try {
      await _loadMetadata();
      await _assertAssetReadable(assetPath);
      await _assertAssetReadable(externalDataAssetPath);
      final session = await _runtime.createSessionFromAsset(assetPath);
      try {
        _contract = await _validateSessionContract(session);
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

  Future<MobileClip2ModelContract> _validateSessionContract(OrtSession session) async {
    final inputNames = session.inputNames;
    final outputNames = session.outputNames;
    if (inputNames.length != 1) {
      throw StateError('MobileCLIP2 ONNX must expose exactly one input, got ${inputNames.length}.');
    }
    if (outputNames.length != 1) {
      throw StateError('MobileCLIP2 ONNX must expose exactly one output, got ${outputNames.length}.');
    }
    _inputName = inputNames.single;
    _outputName = outputNames.single;
    final metadataContract = _requireContract();
    final inputShape = await _readShape(session, isInput: true);
    final layout = MobileClip2ModelContract.detectGraphLayout(
      inputShape,
      metadataContract.inputSize,
    );
    final outputShape = await _readShape(session, isInput: false);
    _validateOutputShape(outputShape, metadataContract.embeddingDimensions);
    return metadataContract.withGraphLayout(layout);
  }

  Future<List<int>> _readShape(OrtSession session, {required bool isInput}) async {
    final infoByName = isInput
        ? await session.getInputInfo()
        : await session.getOutputInfo();
    final name = isInput ? _inputName : _outputName;
    if (name == null) {
      throw StateError('MobileCLIP2 ${isInput ? 'input' : 'output'} name was not discovered.');
    }
    Map<String, dynamic>? tensorInfo;
    for (final info in infoByName) {
      if (info['name'] == name) {
        tensorInfo = info;
        break;
      }
    }
    tensorInfo ??= infoByName.length == 1 ? infoByName.single : null;
    if (tensorInfo == null) {
      throw StateError('MobileCLIP2 ${isInput ? 'input' : 'output'} info missing for $name.');
    }
    final shape = tensorInfo['shape'];
    if (shape is! List || shape.isEmpty) {
      throw StateError('MobileCLIP2 ${isInput ? 'input' : 'output'} shape is empty.');
    }
    return shape.map((value) {
      if (value is! num) {
        throw StateError(
          'MobileCLIP2 ${isInput ? 'input' : 'output'} shape contains a non-numeric dimension: $shape.',
        );
      }
      return value.toInt();
    }).toList(growable: false);
  }

  void _validateOutputShape(List<int> shape, int embeddingDimensions) {
    if (!MobileClip2ModelContract.isSingleEmbeddingShape(shape, embeddingDimensions)) {
      throw StateError(
        'MobileCLIP2 output shape $shape must represent exactly one '
        '$embeddingDimensions-dimensional embedding.',
      );
    }
  }

  MobileClip2ModelContract _requireContract() {
    final contract = _contract;
    if (contract == null) {
      throw StateError('MobileCLIP2 metadata has not been loaded.');
    }
    return contract;
  }

  Future<void> _loadMetadata() async {
    final raw = await rootBundle.loadString(metadataAssetPath);
    _contract = MobileClip2ModelContract.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  static Future<void> _assertAssetReadable(String path) async {
    final data = await rootBundle.load(path);
    if (data.lengthInBytes == 0) throw StateError('Required model asset is empty: $path');
  }

  @override
  String get modelVersion => 'mobileclip2_s0_vision_onnx_v1';
  @override
  double get recommendedMinConfidence => 0.45;
  @override
  int get embeddingLength => isInitialized ? _requireContract().embeddingDimensions * 4 : 0;

  @override
  Future<Uint8List?> embedFile(String path) async {
    if (_session == null) return null;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) return null;
      return await _runInference(_prepareImageTensor(decoded));
    } catch (error) {
      _lastInferenceError = error;
      return null;
    }
  }

  @override
  Future<Uint8List?> embedFrame(CameraImage image) async {
    if (_session == null) return null;
    try {
      final input = _prepareFrameTensor(image);
      if (input == null) return null;
      return await _runInference(input);
    } catch (error) {
      _lastInferenceError = error;
      return null;
    }
  }

  Float32List _prepareImageTensor(img.Image decoded) {
    final size = _requireContract().inputSize;
    final resized = img.copyResize(decoded, width: size, height: size);
    final input = Float32List(size * size * 3);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final p = resized.getPixel(x, y);
        _writePixel(input, y, x, p.r.toDouble(), p.g.toDouble(), p.b.toDouble());
      }
    }
    return input;
  }

  Float32List? _prepareFrameTensor(CameraImage image) {
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        return _fromYuv420(image);
      case ImageFormatGroup.bgra8888:
        return _fromBgra8888(image);
      default:
        final decoded = img.decodeImage(image.planes[0].bytes);
        return decoded == null ? null : _prepareImageTensor(decoded);
    }
  }

  void _writePixel(Float32List input, int row, int col, double r, double g, double b) {
    final contract = _requireContract();
    final size = contract.inputSize;
    final values = [(r / 255.0 - contract.mean[0]) / contract.std[0], (g / 255.0 - contract.mean[1]) / contract.std[1], (b / 255.0 - contract.mean[2]) / contract.std[2]];
    if (contract.layout == 'NHWC') {
      final base = (row * size + col) * 3;
      input[base] = values[0]; input[base + 1] = values[1]; input[base + 2] = values[2];
    } else {
      final plane = size * size;
      final offset = row * size + col;
      input[offset] = values[0]; input[plane + offset] = values[1]; input[2 * plane + offset] = values[2];
    }
  }

  Float32List _fromYuv420(CameraImage image) {
    final size = _requireContract().inputSize, w = image.width, h = image.height;
    final yPlane = image.planes[0], uPlane = image.planes[1], vPlane = image.planes[2];
    final uvStep = uPlane.bytesPerPixel ?? 1;
    final input = Float32List(size * size * 3);
    for (var row = 0; row < size; row++) {
      for (var col = 0; col < size; col++) {
        final sx = (col * w / size).toInt().clamp(0, w - 1), sy = (row * h / size).toInt().clamp(0, h - 1);
        final yIdx = sy * yPlane.bytesPerRow + sx, uvRow = sy >> 1, uvCol = sx >> 1;
        final uIdx = uvRow * uPlane.bytesPerRow + uvCol * uvStep, vIdx = uvRow * vPlane.bytesPerRow + uvCol * uvStep;
        final yv = yIdx < yPlane.bytes.length ? yPlane.bytes[yIdx] : 0;
        final uv = uIdx < uPlane.bytes.length ? uPlane.bytes[uIdx] - 128 : 0;
        final vv = vIdx < vPlane.bytes.length ? vPlane.bytes[vIdx] - 128 : 0;
        _writePixel(input, row, col, (yv + 1.402 * vv).clamp(0, 255).toDouble(), (yv - 0.344136 * uv - 0.714136 * vv).clamp(0, 255).toDouble(), (yv + 1.772 * uv).clamp(0, 255).toDouble());
      }
    }
    return input;
  }

  Float32List _fromBgra8888(CameraImage image) {
    final size = _requireContract().inputSize, w = image.width, h = image.height;
    final bytes = image.planes[0].bytes, stride = image.planes[0].bytesPerRow;
    final input = Float32List(size * size * 3);
    for (var row = 0; row < size; row++) {
      for (var col = 0; col < size; col++) {
        final sx = (col * w / size).toInt().clamp(0, w - 1), sy = (row * h / size).toInt().clamp(0, h - 1);
        final base = sy * stride + sx * 4;
        if (base < 0 || base + 3 >= bytes.length) {
          _writePixel(input, row, col, 0, 0, 0);
          continue;
        }
        final b = bytes[base].toDouble();
        final g = bytes[base + 1].toDouble();
        final r = bytes[base + 2].toDouble();
        _writePixel(input, row, col, r, g, b);
      }
    }
    return input;
  }

  Future<Uint8List?> _runInference(Float32List inputTensor) {
    final completer = Completer<Uint8List?>();
    _inferenceQueue = _inferenceQueue.then((_) async {
      try {
        completer.complete(await _runInferenceLocked(inputTensor));
      } catch (error, stackTrace) {
        _lastInferenceError = error;
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future.catchError((_) => null);
  }

  Future<Uint8List?> _runInferenceLocked(Float32List inputTensor) async {
    final session = _session;
    final inputName = _inputName;
    final outputName = _outputName;
    if (session == null || inputName == null || outputName == null) return null;
    final contract = _requireContract();
    final shape = contract.layout == 'NHWC'
        ? [1, contract.inputSize, contract.inputSize, 3]
        : [1, 3, contract.inputSize, contract.inputSize];
    final input = await OrtValue.fromList(inputTensor, shape);
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({inputName: input});
      final output = outputs[outputName];
      if (output == null) {
        throw StateError('MobileCLIP2 ONNX output $outputName was not returned.');
      }
      final values = (await output.asList())
          .cast<num>()
          .map((value) => value.toDouble())
          .toList(growable: false);
      if (values.length != contract.embeddingDimensions) return null;
      final embedding = Float32List.fromList(values);
      if (embedding.any((value) => value.isNaN || value.isInfinite)) return null;
      _l2Normalize(embedding);
      _lastInferenceError = null;
      return embedding.buffer.asUint8List();
    } finally {
      input.dispose();
      if (outputs != null) {
        for (final tensor in outputs.values) {
          tensor.dispose();
        }
      }
    }
  }

  @override
  double similarity(Uint8List a, Uint8List b) => _cosineSimilarity(a, b);

  @override
  Future<void> dispose() async {
    await _session?.close();
    _session = null;
  }

  static void _l2Normalize(Float32List v) {
    var norm = 0.0;
    for (final x in v) { norm += x * x; }
    norm = sqrt(norm);
    if (norm < 1e-10) throw StateError('Cannot normalize zero embedding.');
    for (var i = 0; i < v.length; i++) { v[i] /= norm; }
  }

  static double _cosineSimilarity(Uint8List a, Uint8List b) {
    if (a.length != b.length || a.lengthInBytes % 4 != 0) return 0.0;
    final fa = a.buffer.asFloat32List(a.offsetInBytes, a.lengthInBytes ~/ 4);
    final fb = b.buffer.asFloat32List(b.offsetInBytes, b.lengthInBytes ~/ 4);
    var dot = 0.0;
    for (var i = 0; i < fa.length; i++) { dot += fa[i] * fb[i]; }
    return dot.clamp(0.0, 1.0);
  }
}

class VisualEmbeddingProvider implements VisualEmbeddingService {
  final MobileVisionEmbeddingService _mobileClip = MobileVisionEmbeddingService();
  final AHashEmbeddingService diagnosticsAHash = AHashEmbeddingService();
  bool _onnxReady = false;

  bool get isOnnxActive => _onnxReady;
  Object? get initializationError => _mobileClip.initializationError;
  Object? get lastInferenceError => _mobileClip.lastInferenceError;

  Future<void> initialize() async {
    try {
      await _mobileClip.initialize();
      _onnxReady = true;
    } catch (error) {
      _onnxReady = false;
    }
  }

  VisualEmbeddingService? get _active => _onnxReady ? _mobileClip : null;

  @override
  String get modelVersion => _active?.modelVersion ?? 'visual_engine_unavailable';
  @override
  double get recommendedMinConfidence => _active?.recommendedMinConfidence ?? 1.0;
  @override
  int get embeddingLength => _active?.embeddingLength ?? 0;
  @override
  Future<Uint8List?> embedFile(String path) => _active?.embedFile(path) ?? Future.value(null);
  @override
  Future<Uint8List?> embedFrame(CameraImage image) => _active?.embedFrame(image) ?? Future.value(null);
  @override
  double similarity(Uint8List a, Uint8List b) => _active?.similarity(a, b) ?? 0.0;

  @override
  Future<void> dispose() async {
    await _mobileClip.dispose();
    _onnxReady = false;
  }
}

class AHashEmbeddingService implements VisualEmbeddingService {
  AHashEmbeddingService({int gridSize = 16}) : _n = gridSize, _preprocessor = FramePreprocessor(gridSize: gridSize);
  final int _n;
  final FramePreprocessor _preprocessor;
  @override
  String get modelVersion => 'ahash_${_n}x$_n';
  @override
  double get recommendedMinConfidence => 0.70;
  @override
  int get embeddingLength => (_n * _n) >> 3;
  @override
  Future<Uint8List?> embedFile(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) return null;
      final gray = img.grayscale(decoded);
      final small = img.copyResize(gray, width: _n, height: _n);
      final pix = List<int>.filled(_n * _n, 0);
      for (var y = 0; y < _n; y++) { for (var x = 0; x < _n; x++) { pix[y * _n + x] = small.getPixel(x, y).r.toInt(); } }
      return _averageHash(pix);
    } catch (_) { return null; }
  }
  @override
  Future<Uint8List?> embedFrame(CameraImage image) async {
    try { final pix = _preprocessor.extractLuminanceGrid(image); return pix == null ? null : _averageHash(pix); } catch (_) { return null; }
  }
  @override
  double similarity(Uint8List a, Uint8List b) {
    if (a.length != b.length) return 0.0;
    return 1.0 - (hammingDistance(a, b) / (_n * _n));
  }
  int hammingDistance(Uint8List a, Uint8List b) {
    if (a.length != b.length) return _n * _n;
    var dist = 0;
    for (var i = 0; i < a.length; i++) { var x = a[i] ^ b[i]; while (x != 0) { dist += x & 1; x >>= 1; } }
    return dist;
  }
  static Uint8List _averageHash(List<int> pix) {
    final mean = pix.fold(0, (s, v) => s + v) ~/ pix.length;
    final hash = Uint8List(pix.length >> 3);
    for (var i = 0; i < pix.length; i++) { if (pix[i] >= mean) hash[i >> 3] |= 1 << (i & 7); }
    return hash;
  }
}
