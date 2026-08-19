import 'dart:convert';
import 'dart:io';

const _modelPath = 'assets/models/mobileclip2/mobileclip2_s0_vision.onnx';
const _externalDataPath = 'assets/models/mobileclip2/mobileclip2_s0_vision.onnx.data';
const _metadataPath = 'assets/models/mobileclip2/model_metadata.json';
const _reportPath = 'assets/models/mobileclip2/verification_report.json';
const _readmePath = 'assets/models/mobileclip2/README.md';
const _manifestPath = 'assets/models/mobileclip2/MANIFEST.md';

void main() {
  for (final path in const [
    _modelPath,
    _externalDataPath,
    _metadataPath,
    _reportPath,
    _readmePath,
    _manifestPath,
  ]) {
    final file = File(path);
    if (!file.existsSync()) fail('Missing required MobileCLIP2 asset: $path');
    if (file.lengthSync() == 0) fail('Required MobileCLIP2 asset is empty: $path');
  }

  final metadata = readJson(_metadataPath);
  validateMetadata(metadata);
  readJson(_reportPath);
  stdout.writeln('MobileCLIP2-S0 ONNX assets verified.');
}

Map<String, dynamic> readJson(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map<String, dynamic>) fail('$path must contain a JSON object.');
  return decoded;
}

void validateMetadata(Map<String, dynamic> metadata) {
  final inputSize = metadata['input_size'];
  if (inputSize is! List || inputSize.length != 2) {
    fail('model_metadata.json input_size must be [width, height].');
  }
  final width = positiveInt(inputSize[0], 'input_size[0]');
  final height = positiveInt(inputSize[1], 'input_size[1]');
  if (width != height) fail('model_metadata.json input_size must be square.');
  if (width != 224 || height != 224) {
    fail('model_metadata.json input_size must be [224, 224], got [$width, $height].');
  }

  final normalization = metadata['normalization'];
  if (normalization is! Map<String, dynamic>) {
    fail('model_metadata.json normalization object is required.');
  }
  final mean = doubleArray(normalization, 'mean', positive: false);
  final std = doubleArray(normalization, 'std', positive: true);
  if (mean.length != 3) fail('normalization.mean must contain exactly 3 values.');
  if (std.length != 3) fail('normalization.std must contain exactly 3 values.');
  const expectedMean = [0.48145466, 0.4578275, 0.40821073];
  const expectedStd = [0.26862954, 0.26130258, 0.27577711];
  for (var i = 0; i < 3; i++) {
    if (mean[i] != expectedMean[i]) {
      fail('normalization.mean[$i] must be ${expectedMean[i]}, got ${mean[i]}.');
    }
    if (std[i] != expectedStd[i]) {
      fail('normalization.std[$i] must be ${expectedStd[i]}, got ${std[i]}.');
    }
  }

  final embeddingDimension = positiveInt(
    metadata['embedding_dimension'],
    'embedding_dimension',
  );
  if (embeddingDimension != 512) {
    fail('embedding_dimension must be 512, got $embeddingDimension.');
  }

  if (metadata['l2_normalized_required'] != true) {
    fail('l2_normalized_required must be true.');
  }

  final opset = positiveInt(metadata['onnx_opset'], 'onnx_opset');
  if (opset != 18) fail('onnx_opset must be 18, got $opset.');
}

int positiveInt(Object? value, String fieldName) {
  if (value is int && value > 0) return value;
  fail('$fieldName must be a positive integer.');
}

List<double> doubleArray(
  Map<String, dynamic> source,
  String key, {
  required bool positive,
}) {
  final value = source[key];
  if (value is! List || value.length != 3) {
    fail('normalization.$key must contain exactly 3 values.');
  }
  final parsed = value.map((item) {
    if (item is! num) fail('normalization.$key contains a non-numeric value.');
    return item.toDouble();
  }).toList(growable: false);
  final invalid = positive
      ? parsed.any((item) => !item.isFinite || item <= 0)
      : parsed.any((item) => !item.isFinite);
  if (invalid) {
    fail(
      positive
          ? 'normalization.$key must contain finite positive values.'
          : 'normalization.$key must contain finite values.',
    );
  }
  return parsed;
}

Never fail(String message) => throw StateError(message);
