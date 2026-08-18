import 'dart:convert';
import 'dart:io';

const _modelPath = 'assets/models/mobileclip2/mobileclip2_s0_vision.onnx';
const _externalDataPath = 'assets/models/mobileclip2/mobileclip2_s0_vision.onnx.data';
const _metadataPath = 'assets/models/mobileclip2/model_metadata.json';
const _reportPath = 'assets/models/mobileclip2/verification_report.json';
const _readmePath = 'assets/models/mobileclip2/README.md';
const _manifestPath = 'assets/models/mobileclip2/MANIFEST.md';

void main() {
  final files = <String>[
    _modelPath,
    _externalDataPath,
    _metadataPath,
    _reportPath,
    _readmePath,
    _manifestPath,
  ];
  for (final path in files) {
    final file = File(path);
    if (!file.existsSync()) fail('Missing required MobileCLIP2 asset: $path');
    if (file.lengthSync() == 0) fail('Required MobileCLIP2 asset is empty: $path');
  }

  final metadata = readJson(_metadataPath);
  final report = readJson(_reportPath);
  validateContract(metadata, report);
  stdout.writeln('MobileCLIP2-S0 ONNX assets verified.');
}

Map<String, dynamic> readJson(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map<String, dynamic>) fail('$path must contain a JSON object.');
  return decoded;
}

void validateContract(Map<String, dynamic> metadata, Map<String, dynamic> report) {
  final source = mergedPreprocessing(metadata);
  final format = readString(source, const ['format', 'model_format', 'modelFormat'], fallback: readString(report, const ['format', 'model_format', 'modelFormat'], required: false));
  if (format?.toUpperCase() != 'ONNX') fail('Model format must be ONNX, got $format.');

  final opset = readInt(source, const ['opset', 'onnx_opset', 'opset_version'], fallback: readInt(report, const ['opset', 'onnx_opset', 'opset_version'], required: false));
  if (opset != 18) fail('ONNX opset must be 18, got $opset.');

  final inputShape = readShape(source, const ['input_shape', 'inputShape']);
  final inputSize = readInt(source, const ['input_resolution', 'input_size', 'image_size', 'resolution'], fallback: inferInputSize(inputShape));
  if (inputSize == null || inputSize <= 0) fail('Input resolution must be a positive integer.');

  final layout = readLayout(source, inputShape);
  if (layout != 'NCHW' && layout != 'NHWC') fail('Input layout must be NCHW or NHWC, got $layout.');

  final mean = readNumArray(source, const ['mean', 'normalization_mean']);
  final std = readNumArray(source, const ['std', 'normalization_std']);
  if (mean.length != 3 || mean.any((value) => !value.isFinite)) fail('mean must contain exactly 3 finite values.');
  if (std.length != 3 || std.any((value) => !value.isFinite || value <= 0)) fail('std must contain exactly 3 finite positive values.');

  final embeddingDimension = readInt(source, const ['embedding_dimension', 'embedding_dimensions', 'output_dimension'], fallback: inferOutputDim(readShape(source, const ['output_shape', 'outputShape'])));
  if (embeddingDimension != 512) fail('Embedding dimension must be 512, got $embeddingDimension.');

  final l2 = readBool(source, const ['l2_normalized', 'l2_normalization'], fallback: readBool(report, const ['l2_normalized', 'l2_normalization'], required: false));
  if (l2 != true) fail('Metadata/report must declare L2 normalization.');
}

Map<String, dynamic> mergedPreprocessing(Map<String, dynamic> metadata) {
  final preprocessing = metadata['preprocessing'];
  return preprocessing is Map<String, dynamic> ? <String, dynamic>{...metadata, ...preprocessing} : metadata;
}

String? readString(Map<String, dynamic> source, List<String> keys, {String? fallback, bool required = true}) {
  for (final key in keys) {
    final value = source[key];
    if (value is String) return value;
  }
  if (fallback != null || !required) return fallback;
  fail('Missing string field ${keys.join('/')}');
}

int? readInt(Map<String, dynamic> source, List<String> keys, {int? fallback, bool required = true}) {
  for (final key in keys) {
    final value = source[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
  }
  if (fallback != null || !required) return fallback;
  fail('Missing integer field ${keys.join('/')}');
}

bool? readBool(Map<String, dynamic> source, List<String> keys, {bool? fallback, bool required = true}) {
  for (final key in keys) {
    final value = source[key];
    if (value is bool) return value;
    if (value is String) {
      final normalized = value.toLowerCase();
      if (normalized == 'true' || normalized == 'l2' || normalized == 'l2_normalized') return true;
      if (normalized == 'false') return false;
    }
  }
  if (fallback != null || !required) return fallback;
  fail('Missing boolean field ${keys.join('/')}');
}

List<int>? readShape(Map<String, dynamic> source, List<String> keys) {
  for (final key in keys) {
    final value = source[key];
    if (value is List) return value.map((item) => item is num ? item.toInt() : -1).toList(growable: false);
  }
  return null;
}

List<double> readNumArray(Map<String, dynamic> source, List<String> keys) {
  for (final key in keys) {
    final value = source[key];
    if (value is List) {
      return value.map((item) {
        if (item is! num) fail('$key contains a non-numeric value.');
        return item.toDouble();
      }).toList(growable: false);
    }
  }
  fail('Missing numeric array ${keys.join('/')}');
}

String readLayout(Map<String, dynamic> source, List<int>? shape) {
  final explicit = readString(source, const ['layout', 'input_layout', 'inputLayout'], required: false);
  if (explicit != null) return explicit.toUpperCase();
  if (shape != null && shape.length == 4) {
    if (shape[1] == 3) return 'NCHW';
    if (shape[3] == 3) return 'NHWC';
  }
  fail('Missing input layout.');
}

int? inferInputSize(List<int>? shape) {
  if (shape == null || shape.length != 4) return null;
  if (shape[1] == 3 && shape[2] > 0 && shape[2] == shape[3]) return shape[2];
  if (shape[3] == 3 && shape[1] > 0 && shape[1] == shape[2]) return shape[1];
  return null;
}

int? inferOutputDim(List<int>? shape) {
  if (shape == null) return null;
  final concrete = shape.where((value) => value > 0).toList(growable: false);
  final nonBatch = concrete.where((value) => value != 1).toList(growable: false);
  return nonBatch.length == 1 ? nonBatch.single : null;
}

Never fail(String message) => throw StateError(message);
