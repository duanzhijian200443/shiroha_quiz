import '../../core/database/content_asset_reclamation_v27_schema.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../application/content/content_asset_reclamation_reset.dart';

typedef ContentAssetIdentity = (String sourceId, String localAssetId);

final class ContentAssetReclamationObservation {
  const ContentAssetReclamationObservation({
    required this.firstUnreachableAt,
    required this.lastVerifiedUnreachableAt,
    required this.newlyObserved,
  });

  final int firstUnreachableAt;
  final int lastVerifiedUnreachableAt;
  final bool newlyObserved;
}

/// Derived grace evidence. Rows never decide whether an asset is live.
final class ContentAssetReclamationObservationRepository
    implements ContentAssetReclamationResetPort {
  ContentAssetReclamationObservationRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _databaseHelper;
  static const int maxObservedRows = 5000;

  @override
  Future<void> resetBeforeOwnership({
    required String sourceId,
    required Iterable<String> localAssetIds,
  }) =>
      reset(<ContentAssetIdentity>{
        for (final localAssetId in localAssetIds) (sourceId, localAssetId),
      });

  static Future<void> resetInTransaction(
    DatabaseExecutor txn,
    Iterable<ContentAssetIdentity> identities,
  ) async {
    for (final (sourceId, localAssetId) in identities.toSet()) {
      await txn.delete(
        contentAssetReclamationTable,
        where: 'source_id = ? AND local_asset_id = ?',
        whereArgs: <Object?>[sourceId, localAssetId],
      );
    }
  }

  Future<void> reset(Iterable<ContentAssetIdentity> identities) async {
    final distinct = identities.toSet();
    if (distinct.isEmpty) return;
    final db = await _databaseHelper.database;
    await db.transaction((txn) => resetInTransaction(txn, distinct));
  }

  /// Called only after an exclusive, complete root and physical scan. A query
  /// or schema failure propagates, so callers cannot authorize deletion.
  Future<Map<ContentAssetIdentity, ContentAssetReclamationObservation>>
      recordCompleteObservation({
    required Set<ContentAssetIdentity> physical,
    required Set<ContentAssetIdentity> live,
    required int nowUtcSeconds,
  }) async {
    final db = await _databaseHelper.database;
    return db.transaction((txn) async {
      await validateContentAssetReclamationV27Schema(txn);
      final rows = await txn.query(contentAssetReclamationTable,
          limit: maxObservedRows + 1);
      if (rows.length > maxObservedRows) {
        throw const ContentAssetReclamationObservationLimitException();
      }
      final prior =
          <ContentAssetIdentity, ContentAssetReclamationObservation>{};
      for (final row in rows) {
        final key =
            (row['source_id'] as String, row['local_asset_id'] as String);
        prior[key] = ContentAssetReclamationObservation(
          firstUnreachableAt: row['first_unreachable_at'] as int,
          lastVerifiedUnreachableAt: row['last_verified_unreachable_at'] as int,
          newlyObserved: false,
        );
      }
      final unreachable = physical.difference(live);
      final current =
          <ContentAssetIdentity, ContentAssetReclamationObservation>{};
      for (final key in prior.keys) {
        if (!unreachable.contains(key)) {
          await resetInTransaction(txn, <ContentAssetIdentity>[key]);
        }
      }
      for (final (sourceId, localAssetId) in unreachable) {
        final key = (sourceId, localAssetId);
        final existing = prior[key];
        final clockRolledBack = existing != null &&
            (nowUtcSeconds < existing.firstUnreachableAt ||
                nowUtcSeconds < existing.lastVerifiedUnreachableAt);
        final first = existing == null || clockRolledBack
            ? nowUtcSeconds
            : existing.firstUnreachableAt;
        if (existing == null) {
          await txn.insert(contentAssetReclamationTable, <String, Object?>{
            'source_id': sourceId,
            'local_asset_id': localAssetId,
            'first_unreachable_at': first,
            'last_verified_unreachable_at': nowUtcSeconds,
          });
        } else {
          await txn.update(
            contentAssetReclamationTable,
            <String, Object?>{
              'first_unreachable_at': first,
              'last_verified_unreachable_at': nowUtcSeconds,
            },
            where: 'source_id = ? AND local_asset_id = ?',
            whereArgs: <Object?>[sourceId, localAssetId],
          );
        }
        current[key] = ContentAssetReclamationObservation(
          firstUnreachableAt: first,
          lastVerifiedUnreachableAt: nowUtcSeconds,
          newlyObserved: existing == null || clockRolledBack,
        );
      }
      return current;
    });
  }
}

final class ContentAssetReclamationObservationLimitException
    implements Exception {
  const ContentAssetReclamationObservationLimitException();

  @override
  String toString() => 'ContentAssetReclamationObservationLimitException';
}
