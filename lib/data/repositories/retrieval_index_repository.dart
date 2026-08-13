library;

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../application/retrieval/retrieval.dart';
import '../../application/retrieval/retrieval_ports.dart';
import '../../application/retrieval/retrieval_service.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../domain/retrieval/retrieval_chunk.dart';
import '../../domain/source/source_ref.dart';

final class SqliteRetrievalIndexRepository implements RetrievalIndexPort {
  SqliteRetrievalIndexRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;
  final DatabaseHelper _databaseHelper;
  final Map<String, Future<void>> _ensureChains = <String, Future<void>>{};

  @override
  Future<void> ensureBuild(
      {required RetrievalArtifactSnapshot snapshot,
      required String chunkerVersion,
      required String lexicalProjectionVersion,
      required List<RetrievalChunk> chunks}) {
    final previous = _ensureChains[snapshot.fileId] ?? Future<void>.value();
    final result = previous.then((_) =>
        _ensure(snapshot, chunkerVersion, lexicalProjectionVersion, chunks));
    final tail = result.then<void>((_) {}, onError: (_) {});
    _ensureChains[snapshot.fileId] = tail;
    tail.whenComplete(() {
      if (identical(_ensureChains[snapshot.fileId], tail)) {
        _ensureChains.remove(snapshot.fileId);
      }
    });
    return result;
  }

  Future<void> _ensure(
      RetrievalArtifactSnapshot snapshot,
      String chunkerVersion,
      String lexicalProjectionVersion,
      List<RetrievalChunk> chunks) async {
    final db = await _databaseHelper.database;
    if (chunks.asMap().entries.any((entry) =>
        entry.key != entry.value.ordinal ||
        entry.value.fileId != snapshot.fileId ||
        entry.value.artifactId != snapshot.artifactId ||
        entry.value.revision != snapshot.revision)) {
      throw const RetrievalException(RetrievalFailure.internalError);
    }
    final chunkDigest = sha256
        .convert(utf8.encode(chunks.map((chunk) => chunk.chunkId).join('\n')))
        .toString();
    final buildId = sha256
        .convert(utf8.encode(<String>[
          snapshot.fileId,
          snapshot.artifactId,
          '${snapshot.revision}',
          snapshot.payloadDigest,
          chunkerVersion,
          lexicalProjectionVersion,
          chunkDigest
        ].join('\n')))
        .toString();
    await db.transaction((txn) async {
      final hit = await txn.rawQuery('''
        SELECT b.build_id, b.chunk_count, b.chunk_digest FROM retrieval_index_heads h
        JOIN retrieval_index_builds b ON b.build_id = h.build_id
        WHERE h.file_id = ? AND b.artifact_id = ? AND b.revision = ?
          AND b.payload_digest = ? AND b.chunker_version = ? AND b.lexical_projection_version = ?
      ''', <Object?>[
        snapshot.fileId,
        snapshot.artifactId,
        snapshot.revision,
        snapshot.payloadDigest,
        chunkerVersion,
        lexicalProjectionVersion
      ]);
      if (hit.isNotEmpty) {
        final storedChunks = await txn.query('retrieval_chunks',
            columns: <String>[
              'chunk_id',
              'ordinal',
              'safe_content',
              'content_hash',
              'safe_heading',
              'kind',
              'locator'
            ],
            where: 'build_id = ?',
            whereArgs: <Object?>[hit.single['build_id']],
            orderBy: 'ordinal ASC');
        final storedDigest = sha256
            .convert(utf8
                .encode(storedChunks.map((row) => row['chunk_id']).join('\n')))
            .toString();
        final ftsRows = await txn.rawQuery('''
          SELECT count(*) AS count FROM retrieval_chunks_fts f
          JOIN retrieval_chunks c ON c.rowid = f.rowid
          WHERE c.build_id = ?
        ''', <Object?>[hit.single['build_id']]);
        final rowsMatch = storedChunks.length == chunks.length &&
            storedChunks.asMap().entries.every((entry) {
              final expected = chunks[entry.key];
              final row = entry.value;
              return row['chunk_id'] == expected.chunkId &&
                  row['ordinal'] == expected.ordinal &&
                  row['safe_content'] == expected.content &&
                  row['content_hash'] == expected.contentHash &&
                  row['safe_heading'] == expected.heading &&
                  row['kind'] == expected.kind.name &&
                  row['locator'] == expected.locator;
            });
        if (hit.single['chunk_count'] == chunks.length &&
            hit.single['chunk_digest'] == chunkDigest &&
            rowsMatch &&
            storedDigest == chunkDigest &&
            ftsRows.single['count'] == chunks.length) {
          return;
        }
        await txn.delete('retrieval_index_builds',
            where: 'build_id = ?',
            whereArgs: <Object?>[hit.single['build_id']]);
      }
      final current = await txn.query('parsed_artifacts',
          columns: <String>['artifact_id', 'revision', 'payload_sha256'],
          where: 'file_id = ?',
          whereArgs: <Object?>[snapshot.fileId],
          limit: 1);
      if (current.isEmpty ||
          current.single['artifact_id'] != snapshot.artifactId ||
          current.single['revision'] != snapshot.revision ||
          current.single['payload_sha256'] != snapshot.payloadDigest) {
        throw const RetrievalException(RetrievalFailure.sourceChanged);
      }
      await txn.delete('retrieval_index_builds',
          where: 'build_id = ?', whereArgs: <Object?>[buildId]);
      await txn.insert(
          'retrieval_index_builds',
          <String, Object?>{
            'build_id': buildId,
            'file_id': snapshot.fileId,
            'artifact_id': snapshot.artifactId,
            'revision': snapshot.revision,
            'payload_digest': snapshot.payloadDigest,
            'chunker_version': chunkerVersion,
            'lexical_projection_version': lexicalProjectionVersion,
            'chunk_count': chunks.length,
            'chunk_digest': chunkDigest,
          },
          conflictAlgorithm: ConflictAlgorithm.abort);
      for (final chunk in chunks) {
        final start = chunk.sourceRef.start;
        final end = chunk.sourceRef.end;
        await txn.insert(
            'retrieval_chunks',
            <String, Object?>{
              'chunk_id': chunk.chunkId,
              'build_id': buildId,
              'ordinal': chunk.ordinal,
              'kind': chunk.kind.name,
              'locator': chunk.locator,
              'safe_heading': chunk.heading,
              'heading': lexicalProjection(chunk.heading ?? ''),
              'body': lexicalProjection(chunk.content),
              'safe_content': chunk.content,
              'content_hash': chunk.contentHash,
              'part_ordinal': chunk.partOrdinal,
              'window_ordinal': chunk.windowOrdinal,
              'page_number': start?.pageNumber,
              'block_id': start?.blockId,
              'reading_order': start?.readingOrder,
              'end_page_number': end?.pageNumber,
              'end_block_id': end?.blockId,
              'end_reading_order': end?.readingOrder,
            },
            conflictAlgorithm: ConflictAlgorithm.abort);
      }
      await txn.insert('retrieval_index_heads',
          <String, Object?>{'file_id': snapshot.fileId, 'build_id': buildId},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete('retrieval_index_builds',
          where: 'file_id = ? AND build_id <> ?',
          whereArgs: <Object?>[snapshot.fileId, buildId]);
    });
  }

  @override
  Future<RetrievalIndexSearchResult> search(
      {required List<RetrievalArtifactSnapshot> snapshots,
      required String matchExpression,
      required int limit,
      required int maxHitBytes,
      required int maxResultBytes}) async {
    if (snapshots.isEmpty) {
      return RetrievalIndexSearchResult(
          hits: const <RetrievalHit>[], sourceChangedFileIds: const <String>[]);
    }
    final db = await _databaseHelper.database;
    return db.transaction((txn) async {
      final validSnapshots = <RetrievalArtifactSnapshot>[];
      final changedFileIds = <String>[];
      for (final snapshot in snapshots) {
        final current = await txn.query('parsed_artifacts',
            columns: <String>['artifact_id', 'revision', 'payload_sha256'],
            where: 'file_id = ?',
            whereArgs: <Object?>[snapshot.fileId],
            limit: 1);
        if (current.isEmpty ||
            current.single['artifact_id'] != snapshot.artifactId ||
            current.single['revision'] != snapshot.revision ||
            current.single['payload_sha256'] != snapshot.payloadDigest) {
          changedFileIds.add(snapshot.fileId);
        } else {
          validSnapshots.add(snapshot);
        }
      }
      if (validSnapshots.isEmpty) {
        return RetrievalIndexSearchResult(
            hits: const <RetrievalHit>[], sourceChangedFileIds: changedFileIds);
      }
      final tupleClauses = List<String>.filled(validSnapshots.length,
              '(b.file_id = ? AND b.artifact_id = ? AND b.revision = ? AND b.payload_digest = ?)')
          .join(' OR ');
      final args = <Object?>[
        matchExpression,
        ...validSnapshots.expand((s) =>
            <Object?>[s.fileId, s.artifactId, s.revision, s.payloadDigest]),
        limit
      ];
      final rows = await txn.rawQuery('''
        SELECT b.file_id, b.artifact_id, b.revision, c.chunk_id, c.ordinal, c.kind, c.locator,
          c.safe_content, c.safe_heading, c.part_ordinal, c.window_ordinal, c.page_number, c.block_id, c.reading_order,
          c.end_page_number, c.end_block_id, c.end_reading_order,
          bm25(retrieval_chunks_fts, 4.0, 1.0) AS raw_rank
        FROM retrieval_chunks_fts
        JOIN retrieval_chunks c ON c.rowid = retrieval_chunks_fts.rowid
        JOIN retrieval_index_builds b ON b.build_id = c.build_id
        JOIN retrieval_index_heads h ON h.file_id = b.file_id AND h.build_id = b.build_id
        JOIN parsed_artifacts a ON a.file_id = b.file_id AND a.artifact_id = b.artifact_id AND a.revision = b.revision AND a.payload_sha256 = b.payload_digest
        WHERE retrieval_chunks_fts MATCH ? AND ($tupleClauses)
        ORDER BY raw_rank ASC, b.file_id ASC, c.ordinal ASC, c.chunk_id ASC LIMIT ?
      ''', args);
      final hits = <RetrievalHit>[];
      final snapshotByFile = <String, RetrievalArtifactSnapshot>{
        for (final snapshot in validSnapshots) snapshot.fileId: snapshot
      };
      var bytes = 0;
      for (final row in rows) {
        final content = row['safe_content']! as String;
        final contentBytes = utf8.encode(content);
        final bounded = contentBytes.length <= maxHitBytes
            ? content
            : utf8.decode(contentBytes.take(maxHitBytes).toList(),
                allowMalformed: true);
        if (bytes + utf8.encode(bounded).length > maxResultBytes) break;
        bytes += utf8.encode(bounded).length;
        final start = row['page_number'] == null
            ? null
            : (row['block_id'] == null
                ? SourcePoint.page(pageNumber: row['page_number']! as int)
                : SourcePoint.block(
                    pageNumber: row['page_number']! as int,
                    blockId: row['block_id']! as String,
                    readingOrder: row['reading_order']! as int));
        final end = row['end_page_number'] == null
            ? null
            : (row['end_block_id'] == null
                ? SourcePoint.page(pageNumber: row['end_page_number']! as int)
                : SourcePoint.block(
                    pageNumber: row['end_page_number']! as int,
                    blockId: row['end_block_id']! as String,
                    readingOrder: row['end_reading_order']! as int));
        final sourceId = row['artifact_id']! as String;
        final displayLabel =
            snapshotByFile[row['file_id']! as String]?.displayLabel;
        final ref = start == null
            ? SourceRef.document(sourceId: sourceId, displayLabel: displayLabel)
            : end != null && start != end && start.isBlock && end.isBlock
                ? SourceRef.range(
                    sourceId: sourceId,
                    displayLabel: displayLabel,
                    start: start,
                    end: end)
                : SourceRef.at(
                    sourceId: sourceId,
                    displayLabel: displayLabel,
                    point: start);
        final lexicalScore = -(row['raw_rank']! as num).toDouble();
        hits.add(RetrievalHit(
            fileId: row['file_id']! as String,
            artifactId: sourceId,
            revision: row['revision']! as int,
            sourceId: sourceId,
            chunkId: row['chunk_id']! as String,
            content: bounded,
            contentKind:
                RetrievalContentKind.values.byName(row['kind']! as String),
            score: lexicalScore,
            lexicalScore: lexicalScore,
            locator: row['locator']! as String,
            partOrdinal: row['part_ordinal']! as int,
            windowOrdinal: row['window_ordinal']! as int,
            nearestHeading: row['safe_heading'] as String?,
            displayLabel: displayLabel,
            sourceRef: ref));
      }
      return RetrievalIndexSearchResult(
          hits: hits, sourceChangedFileIds: changedFileIds);
    });
  }

  @override
  Future<void> removeIndex(String fileId) async {
    final db = await _databaseHelper.database;
    await db.delete('retrieval_index_builds',
        where: 'file_id = ?', whereArgs: <Object?>[fileId]);
  }
}
