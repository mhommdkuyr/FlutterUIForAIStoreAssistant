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
    required this.layout,
  });

  final int inputSize;
  final List<double> mean;
  final List<double> std;
  final int embeddingDimensions;
  final String layout;

  static const expectedEmbeddingDimensions = 512;

  factory MobileClip2ModelContract.fromJson(Map<String, dynamic> json) {
    final preprocessing = json['preprocessing'];
    final source = preprocessing is Map<String, dynamic>
        ? <String, dynamic>{...json, ...preprocessing}
        : json;

    final inputShape = readShape(source, const ['input_shape', 'inputShape']);
    final inputSize = readPositiveInt(
      source,
      const ['input_resolution', 'input_size', 'image_size', 'resolution'],
      fallback: inputShape == null ? null : inferInputSize(inputShape),
    );
    final layout = readLayout(source, inputShape);
    final mean = readDoubleArray(source, const ['mean', 'normalization_mean']);
    final std = readDoubleArray(source, const ['std', 'normalization_std']);
    final embeddingDimensions = readPositiveInt(
      source,
      const ['embedding_dimension', 'embedding_dimensions', 'output_dimension'],
      fallback: inferEmbeddingDimension(
        readShape(source, const ['output_shape', 'outputShape']),
      ),
    );

    final contract = MobileClip2ModelContract(
      inputSize: inputSize,
      mean: mean,
      std: std,
      embeddingDimensions: embeddingDimensions,
      layout: layout,
    );
    contract.validate();
    return contract;
  }

  void validate() {
    if (inputSize <= 0) {
      throw StateError('MobileCLIP2 metadata inputSize must be > 0.');
    }
    if (layout != 'NCHW' && layout != 'NHWC') {
      throw StateError('MobileCLIP2 metadata layout must be NCHW or NHWC.');
    }
    if (mean.length != 3 || mean.any((value) => !value.isFinite)) {
      throw StateError('MobileCLIP2 metadata mean must contain 3 finite values.');
    }
    if (std.length != 3 || std.any((value) => !value.isFinite || value <= 0)) {
      throw StateError('MobileCLIP2 metadata std must contain 3 finite positive values.');
    }
    if (embeddingDimensions != expectedEmbeddingDimensions) {
      throw StateError(
        'MobileCLIP2 metadata embedding dimension must be '
        '$expectedEmbeddingDimensions, got $embeddingDimensions.',
      );
    }
  }

  static int readPositiveInt(
    Map<String, dynamic> source,
    List<String> keys, {
    int? fallback,
  }) {
    for (final key in keys) {
      final value = source[key];
      if (value is int && value > 0) return value;
      if (value is num && value > 0) return value.toInt();
    }
    if (fallback != null && fallback > 0) return fallback;
    throw StateError('MobileCLIP2 metadata is missing positive integer ${keys.join('/')}');
  }

  static List<double> readDoubleArray(
    Map<String, dynamic> source,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = source[key];
      if (value is List) {
        if (value.length != 3) {
          throw StateError('MobileCLIP2 metadata $key must contain exactly 3 values.');
        }
        return value.map((item) {
          if (item is! num) {
            throw StateError('MobileCLIP2 metadata $key contains a non-numeric value.');
          }
          return item.toDouble();
        }).toList(growable: false);
      }
    }
    throw StateError('MobileCLIP2 metadata is missing ${keys.join('/')}');
  }

  static List<int>? readShape(Map<String, dynamic> source, List<String> keys) {
    for (final key in keys) {
      final value = source[key];
      if (value is List) {
        return value.map((item) {
          if (item is! num) return -1;
          return item.toInt();
        }).toList(growable: false);
      }
    }
    return null;
  }

  static int? inferInputSize(List<int>? shape) {
    if (shape == null || shape.length != 4) return null;
    if (shape[1] == 3 && shape[2] > 0 && shape[2] == shape[3]) return shape[2];
    if (shape[3] == 3 && shape[1] > 0 && shape[1] == shape[2]) return shape[1];
    return null;
  }

  static String readLayout(Map<String, dynamic> source, List<int>? inputShape) {
    final explicit = source['layout'] ?? source['input_layout'] ?? source['inputLayout'];
    if (explicit != null) {
      final layout = explicit.toString().toUpperCase();
      if (layout == 'NCHW' || layout == 'NHWC') return layout;
      throw StateError('MobileCLIP2 metadata layout must be NCHW or NHWC.');
    }
    if (inputShape != null && inputShape.length == 4) {
      if (inputShape[1] == 3) return 'NCHW';
      if (inputShape[3] == 3) return 'NHWC';
    }
    throw StateError('MobileCLIP2 metadata is missing input layout.');
  }

  static int? inferEmbeddingDimension(List<int>? shape) {
    if (shape == null) return null;
    if (isSingleEmbeddingShape(shape, expectedEmbeddingDimensions)) {
      return expectedEmbeddingDimensions;
    }
    return null;
  }

  static bool isSingleEmbeddingShape(List<int> shape, int dimension) {
    if (shape.isEmpty) return false;
    final concrete = shape.where((value) => value > 0).toList(growable: false);
    if (concrete.isEmpty) return false;
    final nonBatch = concrete.where((value) => value != 1).toList(growable: false);
    return nonBatch.length == 1 && nonBatch.single == dimension;
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
  MobileClip2ModelContract _contract = MobileClip2ModelContract.fallback;
  String? _inputName;
  String? _outputName;

  bool get isInitialized => _session != null;
  Object? get initializationError => _initializationError;
  Object? get lastInferenceError => _lastInferenceError;
  String get inputName => _inputName ?? '';
  String get outputName => _outputName ?? '';
  MobileClip2ModelContract get contract => _contract;

  Future<void> initialize() async {
    _initializationError = null;
    try {
      await _loadMetadata();
      await _assertAssetReadable(assetPath);
      await _assertAssetReadable(externalDataAssetPath);
      final session = await _runtime.createSessionFromAsset(assetPath);
      try {
        _validateSessionContract(session);
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

  void _validateSessionContract(OrtSession session) {
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
    _validateGraphShape(_readShape(session, isInput: true), isInput: true);
    _validateGraphShape(_readShape(session, isInput: false), isInput: false);
  }

  List<int> _readShape(OrtSession session, {required bool isInput}) {
    final infoByName = isInput ? session.inputInfo : session.outputInfo;
    final name = isInput ? _inputName : _outputName;
    if (name == null) {
      throw StateError('MobileCLIP2 ${isInput ? 'input' : 'output'} name was not discovered.');
    }
    final tensorInfo = infoByName[name];
    if (tensorInfo == null) {
      throw StateError('MobileCLIP2 ${isInput ? 'input' : 'output'} info missing for $name.');
    }
    final shape = tensorInfo.shape;
    if (shape.isEmpty) {
      throw StateError('MobileCLIP2 ${isInput ? 'input' : 'output'} shape is empty.');
    }
    return shape.map((value) => value.toInt()).toList(growable: false);
  }

  void _validateGraphShape(List<int> shape, {required bool isInput}) {
    if (isInput) {
      if (shape.length != 4) throw StateError('MobileCLIP2 input must be rank 4, got $shape.');
      final nchw = shape[1] == 3 && shape[2] == _contract.inputSize && shape[3] == _contract.inputSize;
      final nhwc = shape[3] == 3 && shape[1] == _contract.inputSize && shape[2] == _contract.inputSize;
      final graphLayout = nchw ? 'NCHW' : (nhwc ? 'NHWC' : null);
      if (graphLayout == null) {
        throw StateError('MobileCLIP2 input shape $shape disagrees with metadata input size ${_contract.inputSize}.');
      }
      if (graphLayout != _contract.layout) {
        throw StateError('MobileCLIP2 input layout $graphLayout disagrees with metadata ${_contract.layout}.');
      }
    } else if (!MobileClip2ModelContract.isSingleEmbeddingShape(
      shape,
      _contract.embeddingDimensions,
    )) {
      throw StateError(
        'MobileCLIP2 output shape $shape must represent exactly one '
        '${_contract.embeddingDimensions}-dimensional embedding.',
      );
    }
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
  int get embeddingLength => isInitialized ? _contract.embeddingDimensions * 4 : 0;

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
    final size = _contract.inputSize;
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
    final size = _contract.inputSize;
    final values = [(r / 255.0 - _contract.mean[0]) / _contract.std[0], (g / 255.0 - _contract.mean[1]) / _contract.std[1], (b / 255.0 - _contract.mean[2]) / _contract.std[2]];
    if (_contract.layout == 'NHWC') {
      final base = (row * size + col) * 3;
      input[base] = values[0]; input[base + 1] = values[1]; input[base + 2] = values[2];
    } else {
      final plane = size * size;
      final offset = row * size + col;
      input[offset] = values[0]; input[plane + offset] = values[1]; input[2 * plane + offset] = values[2];
    }
  }

  Float32List _fromYuv420(CameraImage image) {
    final size = _contract.inputSize, w = image.width, h = image.height;
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
    final size = _contract.inputSize, w = image.width, h = image.height;
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
    final shape = _contract.layout == 'NHWC'
        ? [1, _contract.inputSize, _contract.inputSize, 3]
        : [1, 3, _contract.inputSize, _contract.inputSize];
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
      if (values.length != _contract.embeddingDimensions) return null;
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
    try {
      final dynamic runtime = _runtime;
      final dispose = runtime.dispose;
      if (dispose is Function) dispose();
    } on NoSuchMethodError {
      // flutter_onnxruntime 1.8.3 does not require runtime disposal.
    }
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
