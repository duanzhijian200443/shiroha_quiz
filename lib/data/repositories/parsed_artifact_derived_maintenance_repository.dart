import '../../application/parsed_artifacts/parsed_artifact_derived_maintenance.dart';
import '../../core/database/database_helper.dart';

final class SqliteParsedArtifactDerivedMaintenanceRepository
    implements ParsedArtifactDerivedMaintenancePort {
  SqliteParsedArtifactDerivedMaintenanceRepository({
    DatabaseHelper? databaseHelper,
  }) : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _databaseHelper;

  @override
  Future<List<CurrentArtifactStorageRow>> currentPage({
    required int offset,
    required int limit,
  }) async {
    final db = await _databaseHelper.database;
    final rows = await db.query('parsed_artifacts',
        columns: const <String>['file_id', 'storage_key'],
        orderBy: 'file_id',
        limit: limit,
        offset: offset);
    return List<
        CurrentArtifactStorageRow>.unmodifiable(<CurrentArtifactStorageRow>[
      for (final row in rows)
        CurrentArtifactStorageRow(
          fileId: row['file_id'] as String,
          storageKey: row['storage_key'] as String,
        ),
    ]);
  }

  @override
  Future<int> deleteStaleRetrievalBuilds({required int maxRows}) async {
    final db = await _databaseHelper.database;
    return db.transaction((txn) async {
      final rows = await txn.rawQuery('''
        SELECT b.build_id FROM retrieval_index_builds b
        WHERE NOT EXISTS (
          SELECT 1 FROM parsed_artifacts a
          WHERE a.file_id = b.file_id
            AND a.artifact_id = b.artifact_id
            AND a.revision = b.revision
            AND a.payload_sha256 = b.payload_digest
        )
        LIMIT ?
      ''', <Object?>[maxRows + 1]);
      if (rows.length > maxRows) {
        throw const ParsedArtifactDerivedMaintenanceLimitException();
      }
      for (final row in rows) {
        await txn.delete('retrieval_index_builds',
            where: 'build_id = ?', whereArgs: <Object?>[row['build_id']]);
      }
      return rows.length;
    });
  }
}

final class ParsedArtifactDerivedMaintenanceLimitException
    implements Exception {
  const ParsedArtifactDerivedMaintenanceLimitException();

  @override
  String toString() => 'ParsedArtifactDerivedMaintenanceLimitException';
}
