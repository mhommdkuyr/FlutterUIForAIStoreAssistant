import 'dart:convert';
import 'dart:io';

void main() {
  final required = {
    'ONNX model': File('assets/models/mobileclip2/mobileclip2_s0_vision.onnx'),
    'ONNX external data': File('assets/models/mobileclip2/mobileclip2_s0_vision.onnx.data'),
    'metadata': File('assets/models/mobileclip2/model_metadata.json'),
    'README': File('assets/models/mobileclip2/README.md'),
    'verification report': File('assets/models/mobileclip2/verification_report.json'),
  };
  var ok = true;
  for (final entry in required.entries) {
    if (!entry.value.existsSync()) {
      stderr.writeln('Missing ${entry.key}: ${entry.value.path}');
      ok = false;
    } else if (entry.value.lengthSync() == 0) {
      stderr.writeln('Empty ${entry.key}: ${entry.value.path}');
      ok = false;
    }
  }
  if (!ok) exit(1);
  final metadata = jsonDecode(required['metadata']!.readAsStringSync()) as Map<String, dynamic>;
  final report = jsonDecode(required['verification report']!.readAsStringSync()) as Map<String, dynamic>;
  final text = jsonEncode({...metadata, ...report}).toLowerCase();
  void require(bool condition, String message) { if (!condition) { stderr.writeln(message); ok = false; } }
  require(text.contains('onnx'), 'Model metadata/report must identify ONNX format.');
  require(text.contains('18'), 'Model metadata/report must identify ONNX opset 18.');
  require(text.contains('512'), 'Model metadata/report must identify 512-dimensional embeddings.');
  require(text.contains('l2') || text.contains('normalize'), 'Model metadata/report must identify L2 normalization.');
  require(text.contains('mean') && text.contains('std'), 'Model metadata/report must include normalization mean/std.');
  if (!ok) exit(1);
  stdout.writeln('MobileCLIP2-S0 ONNX assets verified.');
}
