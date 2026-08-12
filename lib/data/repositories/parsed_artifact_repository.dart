import '../../application/parsed_artifacts/parsed_artifact_ports.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../domain/assets/parsed_artifact.dart';

final _fileIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// SQLite repository for the frozen v20 parsed-artifact metadata primitives.
///
/// Publish/remove are single-transaction compare-and-set operations. CAS
/// losers mutate nothing and return typed results; unexpected database
/// failures surface as safe [ParsedArtifactRepositoryException] values
/// without raw SQL or DatabaseException leakage.
class ParsedArtifactRepository implements ParsedArtifactRepositoryPort {
  ParsedArtifactRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _databaseHelper;

  static const String _headsTable = 'parsed_artifact_heads';
  static const String _artifactsTable = 'parsed_artifacts';
  static const String _libraryFilesTable = 'library_files';

  @override
  Future<ParsedArtifactMetadata?> findCurrentByFileId(String fileId) async {
    try {
      _validateFileId(fileId);
      final db = await _databaseHelper.database;
      final rows = await db.query(
        _artifactsTable,
        where: 'file_id = ?',
        whereArgs: <Object?>[fileId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return _metadataFromRow(rows.single);
    } on ParsedArtifactRepositoryException {
      rethrow;
    } catch (_) {
      throw const ParsedArtifactRepositoryException(
        ParsedArtifactRepositoryFailure.unavailable,
      );
    }
  }

  @override
  Future<int> readRevisionHead(String fileId) async {
    try {
      _validateFileId(fileId);
      final db = await _databaseHelper.database;
      final rows = await db.query(
        _headsTable,
        columns: const <String>['last_revision'],
        where: 'file_id = ?',
        whereArgs: <Object?>[fileId],
        limit: 1,
      );
      if (rows.isEmpty) return 0;
      return rows.single['last_revision']! as int;
    } on ParsedArtifactRepositoryException {
      rethrow;
    } catch (_) {
      throw const ParsedArtifactRepositoryException(
        ParsedArtifactRepositoryFailure.unavailable,
      );
    }
  }

  @override
  Future<ParsedArtifactPublishResult> publishCurrent({
    required String fileId,
    required ParsedArtifactMetadata candidate,
    required int expectedRevision,
  }) async {
    try {
      _validateFileId(fileId);
      if (candidate.fileId != fileId || expectedRevision < 0) {
        throw const ParsedArtifactRepositoryException(
          ParsedArtifactRepositoryFailure.invalidRequest,
        );
      }
      final db = await _databaseHelper.database;
      try {
        return await db.transaction((txn) async {
          final parent = await txn.query(
            _libraryFilesTable,
            columns: const <String>['file_id'],
            where: 'file_id = ?',
            whereArgs: <Object?>[fileId],
            limit: 1,
          );
          if (parent.isEmpty) {
            return const ParsedArtifactPublishResult.parentMissing();
          }

          final headRows = await txn.query(
            _headsTable,
            columns: const <String>['last_revision'],
            where: 'file_id = ?',
            whereArgs: <Object?>[fileId],
            limit: 1,
          );
          final headRevision =
              headRows.isEmpty ? 0 : headRows.single['last_revision']! as int;
          if (expectedRevision != headRevision ||
              candidate.revision != expectedRevision + 1) {
            return ParsedArtifactPublishResult.revisionConflict(headRevision);
          }

          if (headRows.isEmpty) {
            await txn.insert(_headsTable, <String, Object?>{
              'file_id': fileId,
              'last_revision': candidate.revision,
            });
          } else {
            await txn.update(
              _headsTable,
              <String, Object?>{'last_revision': candidate.revision},
              where: 'file_id = ?',
              whereArgs: <Object?>[fileId],
            );
          }
          await txn.delete(
            _artifactsTable,
            where: 'file_id = ?',
            whereArgs: <Object?>[fileId],
          );
          await txn.insert(_artifactsTable, _metadataToRow(candidate));
          return ParsedArtifactPublishResult.published(candidate);
        });
      } on DatabaseException catch (error) {
        if (error.isUniqueConstraintError()) {
          throw const ParsedArtifactRepositoryException(
            ParsedArtifactRepositoryFailure.duplicateIdentity,
          );
        }
        throw const ParsedArtifactRepositoryException(
          ParsedArtifactRepositoryFailure.unavailable,
        );
      }
    } on ParsedArtifactRepositoryException {
      rethrow;
    } catch (_) {
      throw const ParsedArtifactRepositoryException(
        ParsedArtifactRepositoryFailure.unavailable,
      );
    }
  }

  @override
  Future<ParsedArtifactRemoveResult> removeCurrent({
    required String fileId,
    required int expectedRevision,
  }) async {
    try {
      _validateFileId(fileId);
      if (expectedRevision < 0) {
        throw const ParsedArtifactRepositoryException(
          ParsedArtifactRepositoryFailure.invalidRequest,
        );
      }
      final db = await _databaseHelper.database;
      try {
        return await db.transaction((txn) async {
          final headRows = await txn.query(
            _headsTable,
            columns: const <String>['last_revision'],
            where: 'file_id = ?',
            whereArgs: <Object?>[fileId],
            limit: 1,
          );
          if (headRows.isEmpty) {
            return const ParsedArtifactRemoveResult.notFound();
          }
          final headRevision = headRows.single['last_revision']! as int;
          if (expectedRevision != headRevision) {
            return ParsedArtifactRemoveResult.revisionConflict(headRevision);
          }
          final currentRows = await txn.query(
            _artifactsTable,
            columns: const <String>['file_id'],
            where: 'file_id = ?',
            whereArgs: <Object?>[fileId],
            limit: 1,
          );
          if (currentRows.isEmpty) {
            return const ParsedArtifactRemoveResult.notFound();
          }
          await txn.delete(
            _artifactsTable,
            where: 'file_id = ?',
            whereArgs: <Object?>[fileId],
          );
          return const ParsedArtifactRemoveResult.removed();
        });
      } on DatabaseException {
        throw const ParsedArtifactRepositoryException(
          ParsedArtifactRepositoryFailure.unavailable,
        );
      }
    } on ParsedArtifactRepositoryException {
      rethrow;
    } catch (_) {
      throw const ParsedArtifactRepositoryException(
        ParsedArtifactRepositoryFailure.unavailable,
      );
    }
  }

  Map<String, Object?> _metadataToRow(ParsedArtifactMetadata metadata) {
    return <String, Object?>{
      'file_id': metadata.fileId,
      'artifact_id': metadata.artifactId,
      'revision': metadata.revision,
      'source_sha256': metadata.sourceSha256,
      'cache_key_version': metadata.cacheKeyVersion,
      'cache_fingerprint': metadata.cacheFingerprint,
      'parser_route': metadata.parserRoute,
      'parser_version': metadata.parserVersion,
      'options_schema_version': metadata.optionsSchemaVersion,
      'payload_schema_version': metadata.payloadSchemaVersion,
      'storage_key': metadata.storageKey,
      'payload_sha256': metadata.payloadSha256,
      'size_bytes': metadata.sizeBytes,
      'published_at': metadata.publishedAt,
    };
  }

  ParsedArtifactMetadata _metadataFromRow(Map<String, Object?> row) {
    return ParsedArtifactMetadata(
      artifact: ParsedArtifact(
        fileId: row['file_id']! as String,
        artifactId: row['artifact_id']! as String,
        revision: row['revision']! as int,
        payloadSchemaVersion: row['payload_schema_version']! as int,
      ),
      sourceSha256: row['source_sha256']! as String,
      cacheKeyVersion: row['cache_key_version']! as int,
      cacheFingerprint: row['cache_fingerprint']! as String,
      parserRoute: row['parser_route']! as String,
      parserVersion: row['parser_version']! as String,
      optionsSchemaVersion: row['options_schema_version']! as int,
      storageKey: row['storage_key']! as String,
      payloadSha256: row['payload_sha256']! as String,
      sizeBytes: row['size_bytes']! as int,
      publishedAt: row['published_at']! as int,
    );
  }
}

void _validateFileId(String fileId) {
  if (!_fileIdPattern.hasMatch(fileId)) {
    throw const ParsedArtifactRepositoryException(
      ParsedArtifactRepositoryFailure.invalidRequest,
    );
  }
}
