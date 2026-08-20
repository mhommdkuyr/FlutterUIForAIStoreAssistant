import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';

/// Persists precomputed visual embeddings keyed by product, image path, and
/// model version. The live scanner only loads rows matching the active model.
class EmbeddingPersistenceService {
  EmbeddingPersistenceService({AppDatabase? db})
      : _db = db ?? AppDatabase.instance;

  final AppDatabase _db;
  static const _uuid = Uuid();

  Future<Map<String, Map<String, Uint8List>>> loadAll(
    String modelVersion,
  ) async {
    final rows = await (_db.select(_db.productEmbeddings)
          ..where((table) => table.modelVersion.equals(modelVersion))
          ..orderBy([(table) => OrderingTerm.desc(table.createdAt)]))
        .get();

    final result = <String, Map<String, Uint8List>>{};
    for (final row in rows) {
      final path = row.imagePath ?? '';
      if (path.isEmpty) continue;
      final product = result.putIfAbsent(row.productId, () => {});
      // Newest row wins. Older duplicate rows can exist because historical
      // schemas use a random UUID primary key instead of a composite key.
      product.putIfAbsent(path, () => row.hashBytes as Uint8List);
    }
    return result;
  }

  Future<void> save({
    required String productId,
    required String imagePath,
    required Uint8List embedding,
    required String modelVersion,
  }) async {
    // The current DB schema has no composite UNIQUE(productId,imagePath,model),
    // so insertOnConflictUpdate cannot actually upsert this logical key.
    // Remove prior copies first, then insert exactly one current row.
    await (_db.delete(_db.productEmbeddings)
          ..where(
            (table) =>
                table.productId.equals(productId) &
                table.imagePath.equals(imagePath) &
                table.modelVersion.equals(modelVersion),
          ))
        .go();

    final companion = ProductEmbeddingsCompanion(
      id: Value(_uuid.v4()),
      productId: Value(productId),
      imagePath: Value(imagePath),
      hashBytes: Value(embedding),
      modelVersion: Value(modelVersion),
      createdAt: Value(DateTime.now()),
    );
    await _db.into(_db.productEmbeddings).insert(companion);
  }

  Future<void> deleteProduct(String productId) async {
    await (_db.delete(_db.productEmbeddings)
          ..where((table) => table.productId.equals(productId)))
        .go();
  }

  Future<void> clearModelVersion(String modelVersion) async {
    await (_db.delete(_db.productEmbeddings)
          ..where((table) => table.modelVersion.equals(modelVersion)))
        .go();
  }
}
