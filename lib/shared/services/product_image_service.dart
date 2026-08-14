import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Manages local product image storage.
///
/// Phase 1: [savePickedImage] — saves a single image and returns its path.
///
/// Phase 2 additions:
///   • [saveAdditionalImage] — saves an extra reference image for a specific
///     product into its own sub-directory; supports multiple images per
///     product for the visual recognition index.
///   • [getAdditionalImagePaths] — returns all extra reference image paths
///     previously saved for a product.
///   • [deleteProductImages] — removes all stored images for a product
///     (call after product deletion to reclaim disk space).
class ProductImageService {
  // ── Phase 1 API (unchanged) ──────────────────────────────────────────────

  /// Save [file] into the shared `product_images/` directory.
  ///
  /// Returns the absolute local path of the saved file.
  /// This path is stored in [ProductModel.imageUrl].
  Future<String> savePickedImage(XFile file) async {
    final imagesDir = await _sharedImagesDir();
    final ext = path.extension(file.path);
    final fileName = '${DateTime.now().microsecondsSinceEpoch}$ext';
    final targetPath = path.join(imagesDir.path, fileName);
    final source = File(file.path);
    if (await source.exists()) {
      await source.copy(targetPath);
    }
    return targetPath;
  }

  // ── Phase 2 API ───────────────────────────────────────────────────────────

  /// Save [file] as an additional reference image for [productId].
  ///
  /// Images are stored under `product_images/{productId}/`.
  /// Returns the absolute local path of the saved file.
  Future<String> saveAdditionalImage(String productId, XFile file) async {
    final dir = await _productDir(productId);
    final ext = path.extension(file.path);
    final fileName = '${DateTime.now().microsecondsSinceEpoch}$ext';
    final targetPath = path.join(dir.path, fileName);
    final source = File(file.path);
    if (await source.exists()) {
      await source.copy(targetPath);
    }
    return targetPath;
  }

  /// Returns paths of all additional reference images stored for [productId].
  ///
  /// Does NOT include the primary [ProductModel.imageUrl] — that is stored
  /// separately in the database.
  Future<List<String>> getAdditionalImagePaths(String productId) async {
    final dir = await _productDir(productId, create: false);
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .toList()
      ..sort(); // deterministic order
  }

  /// Delete all additional reference images stored for [productId].
  ///
  /// Call after a product is deleted to reclaim disk space.
  Future<void> deleteProductImages(String productId) async {
    final dir = await _productDir(productId, create: false);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  // ── Directory helpers ─────────────────────────────────────────────────────

  Future<Directory> _sharedImagesDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(path.join(appDir.path, 'product_images'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> _productDir(
    String productId, {
    bool create = true,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(
      path.join(appDir.path, 'product_images', productId),
    );
    if (create && !dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
