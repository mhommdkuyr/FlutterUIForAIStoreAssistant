import 'dart:io';

void main() {
  const path = 'assets/models/mobileclip2/mobileclip2_s0_image_encoder.tflite';
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Missing required MobileCLIP2-S0 runtime model: $path');
    exit(2);
  }
  final size = file.lengthSync();
  if (size < 30 * 1024 * 1024) {
    stderr.writeln('Model file is too small to be the real MobileCLIP2-S0 image encoder: $size bytes');
    exit(3);
  }
  stdout.writeln('MobileCLIP2-S0 asset present: $size bytes');
}
