import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// Extracts a normalised luminance grid from a raw [CameraImage].
///
/// Handles the two formats seen in practice:
///   • **YUV420** (Android default) — planes[0] is the full-resolution Y plane.
///   • **BGRA8888** (iOS default) — planes[0] is 4-byte BGRA interleaved data.
///
/// Falls back to full image decode via the `image` package for any other
/// format group reported by the camera driver.
///
/// The output is a flat [List<int>] of [gridSize × gridSize] (default 16×16)
/// luminance values in row-major order, suitable for average-hash computation.
/// Returns `null` only when the image cannot be decoded at all.
class FramePreprocessor {
  const FramePreprocessor({this.gridSize = 16});

  /// Side length of the output luminance grid (both dimensions).
  final int gridSize;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Extract a [gridSize × gridSize] luminance grid from [image].
  ///
  /// Safe to call on the camera's background isolate — performs no UI work.
  List<int>? extractLuminanceGrid(CameraImage image) {
    try {
      switch (image.format.group) {
        case ImageFormatGroup.yuv420:
          return _fromYuv420(image);
        case ImageFormatGroup.bgra8888:
          return _fromBgra8888(image);
        default:
          return _fromDecoded(image);
      }
    } catch (_) {
      return null;
    }
  }

  // ── YUV420 ─────────────────────────────────────────────────────────────────

  /// Android: planes[0] is the Y (luminance) plane at full resolution.
  /// Each pixel occupies exactly 1 byte; stride may be wider than width.
  List<int> _fromYuv420(CameraImage image) {
    final plane = image.planes[0];
    return _sampleGrid(
      bytes: plane.bytes,
      w: image.width,
      h: image.height,
      stride: plane.bytesPerRow,
      pixelStep: 1,
      lumaOffset: 0,
    );
  }

  // ── BGRA8888 ───────────────────────────────────────────────────────────────

  /// iOS: planes[0] is 4-byte-per-pixel BGRA interleaved data.
  /// Luminance is computed as Y = 0.299 R + 0.587 G + 0.114 B.
  List<int> _fromBgra8888(CameraImage image) {
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final w = image.width;
    final h = image.height;
    final stride = plane.bytesPerRow;
    final n = gridSize;

    final pix = List<int>.filled(n * n, 0);
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        final sx = ((c + 0.5) * w / n).toInt().clamp(0, w - 1);
        final sy = ((r + 0.5) * h / n).toInt().clamp(0, h - 1);
        final base = sy * stride + sx * 4;
        if (base + 2 >= bytes.length) continue;
        final b = bytes[base];
        final g = bytes[base + 1];
        final rv = bytes[base + 2];
        // Standard BT.601 luma weights:
        pix[r * n + c] = (0.299 * rv + 0.587 * g + 0.114 * b).round();
      }
    }
    return pix;
  }

  // ── Fallback: full decode ──────────────────────────────────────────────────

  List<int>? _fromDecoded(CameraImage image) {
    // Last resort: flatten plane 0 bytes and let the `image` package decode.
    final decoded = img.decodeImage(image.planes[0].bytes);
    if (decoded == null) return null;
    final gray = img.grayscale(decoded);
    final small = img.copyResize(gray, width: gridSize, height: gridSize);
    final n = gridSize;
    final pix = List<int>.filled(n * n, 0);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        pix[y * n + x] = small.getPixel(x, y).r.toInt();
      }
    }
    return pix;
  }

  // ── Shared grid sampler ────────────────────────────────────────────────────

  /// Sample [gridSize × gridSize] cell centres from a single-channel plane.
  List<int> _sampleGrid({
    required Uint8List bytes,
    required int w,
    required int h,
    required int stride,
    required int pixelStep,
    required int lumaOffset,
  }) {
    final n = gridSize;
    final pix = List<int>.filled(n * n, 0);
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        final sx = ((c + 0.5) * w / n).toInt().clamp(0, w - 1);
        final sy = ((r + 0.5) * h / n).toInt().clamp(0, h - 1);
        final idx = sy * stride + sx * pixelStep + lumaOffset;
        pix[r * n + c] = idx < bytes.length ? bytes[idx] : 0;
      }
    }
    return pix;
  }
}
