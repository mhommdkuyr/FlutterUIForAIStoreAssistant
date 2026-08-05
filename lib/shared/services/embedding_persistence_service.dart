import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';

/// Persists and loads precomputed visual embeddings to/from the
/// [ProductEmbeddings] SQLite table.
///
/// Purpose: avoid recomputing embeddings from disk every time the live-scan
/// session opens. The first `buildIndex` call computes and persists embeddings;
/// every subsequent call loads them from the DB in a single query.
///
/// Invalidation: stored rows are keyed by (productId, imagePath, modelVersion).
/// If the model changes, old rows are ignored and new ones are written.
class EmbeddingPersistenceService {
  EmbeddingPersistenceService({AppDatabase? db})
      : _db = db ?? AppDatabase.instance;

  final AppDatabase _db;
  static const _uuid = Uuid();

  // ── Read ──────────────────────────────────────────────────────────────────

  /// Load all embeddings for [modelVersion] keyed by productId.
  ///
  /// Returns Map<productId, Map<imagePath, embeddingBytes>>.
  Future<Map<String, Map<String, Uint8List>>> loadAll(
      String modelVersion) async {
    final rows = await (_db.select(_db.productEmbeddings)
          ..where((t) => t.modelVersion.equals(modelVersion)))
        .get();

    final result = <String, Map<String, Uint8List>>{};
    for (final row in rows) {
      result
          .putIfAbsent(row.productId, () => {})
          .putIfAbsent(row.imagePath ?? '', () => Uint8List.fromList(row.hashBytes));
    }
    return result;
  }

  // ── Write ─────────────────────────────────────────────────────────────────

  /// Persist a single embedding.
  ///
  /// Uses an upsert: if a row for (productId, imagePath, modelVersion) already
  /// exists it is updated, otherwise a new row is inserted.
  Future<void> save({
    required String productId,
    required String imagePath,
    required Uint8List embedding,
    required String modelVersion,
  }) async {
    final companion = ProductEmbeddingsCompanion(
      id: Value(_uuid.v4()),
      productId: Value(productId),
      imagePath: Value(imagePath),
      hashBytes: Value(embedding),
      modelVersion: Value(modelVersion),
      createdAt: Value(DateTime.now()),
    );
    await _db.into(_db.productEmbeddings).insertOnConflictUpdate(companion);
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  /// Remove all persisted embeddings for [productId] (call after deletion).
  Future<void> deleteProduct(String productId) async {
    await (_db.delete(_db.productEmbeddings)
          ..where((t) => t.productId.equals(productId)))
        .go();
  }

  /// Remove all embeddings for a specific model version (force full re-index).
  Future<void> clearModelVersion(String modelVersion) async {
    await (_db.delete(_db.productEmbeddings)
          ..where((t) => t.modelVersion.equals(modelVersion)))
        .go();
  }
}
