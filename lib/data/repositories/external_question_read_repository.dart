import 'dart:convert';

import '../../application/capabilities/capability.dart';
import '../../application/external/external_authorization.dart';
import '../../application/external/external_question_read.dart';
import '../../application/external/external_read_context.dart';
import '../../application/study_query/study_query_dtos.dart';
import '../../application/study_query/study_query_ports.dart';
import '../../application/study_query/study_question_projection.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../domain/question/question_draft_v2_codec.dart';
import '../../services/backup/sha256.dart';
import '../models/persisted_question.dart';
import 'exact_question_materializer.dart';
import 'external_authorization_repository.dart';

enum ExternalQuestionReadCheckpoint {
  authorized,
  beforeContentRead,
  afterContentRead
}

/// Scope-first, bounded keyset reads through the existing exact materializer.
/// No write, metrics/history query, provider, file access or global content scan.
final class SqliteExternalQuestionReadRepository
    implements ExternalQuestionReadPort {
  SqliteExternalQuestionReadRepository(
      {DatabaseHelper? databaseHelper,
      Future<void> Function(ExternalQuestionReadCheckpoint)? checkpoint})
      : _helper = databaseHelper ?? DatabaseHelper.instance,
        _checkpoint = checkpoint;
  final DatabaseHelper _helper;
  final Future<void> Function(ExternalQuestionReadCheckpoint)? _checkpoint;
  static const maxScan = 128, maxStoredBytes = 256 * 1024;
  static const _projection = StudyQuestionProjection();
  static const _review = StudyQuestionReviewState(
      due: false, lapseCount: 0, difficulty: 0, lastLapseTime: null);

  // Only bounded identities/lengths are selected before exact materialization.
  static const _selection = '''
    SELECT CASE WHEN length(CAST(q.id AS BLOB)) <= 256 THEN q.id END AS id,
      length(CAST(q.id AS BLOB)) AS id_bytes,
      q.rowid AS row_identity,
      CASE WHEN typeof(q.created_at) = 'integer' THEN q.created_at END AS created_at,
      (p.question_id IS NOT NULL) AS has_payload,
      typeof(q.content) AS stem_type, typeof(q.standard_answer) AS answer_type,
      typeof(q.type) AS kind_type,
      coalesce(length(CAST(q.content AS BLOB)),0) +
      coalesce(length(CAST(q.options AS BLOB)),0) +
      coalesce(length(CAST(q.standard_answer AS BLOB)),0) +
      coalesce(length(CAST(q.explanation AS BLOB)),0) +
      coalesce(length(CAST(q.raw_explanation AS BLOB)),0) +
      coalesce(length(CAST(p.payload_json AS BLOB)),0) AS stored_bytes
    FROM questions q LEFT JOIN question_v2_payloads p ON p.question_id=q.id
  ''';

  Future<T> _read<T>(ExternalQuestionReadAccess access, void Function() check,
      Future<T> Function(Transaction) body) async {
    check();
    access.validate();
    try {
      final db = await _helper.database;
      check();
      return await db.transaction((txn) async {
        check();
        await requireExternalGrant(
            txn,
            access.runtime.profileId,
            access.revision,
            CapabilityPermission.read,
            access.target.scope,
            ExternalContentCategory.questionContent,
            access.runtime.profileId);
        check();
        final folders = await txn.query('bank_folders',
            columns: ['folder_name'],
            where: 'bank_name=?',
            whereArgs: [access.target.bankName],
            limit: 1);
        check();
        if ((folders.isEmpty ? null : folders.single['folder_name']) !=
            access.target.folderName) {
          externalReadFail(ExternalReadFailure.stale);
        }
        access.validate();
        await _checkpoint?.call(ExternalQuestionReadCheckpoint.authorized);
        check();
        final result = await body(txn);
        check();
        access.validate();
        return result;
      });
    } on ExternalReadException {
      rethrow;
    } on ExternalAuthException {
      externalReadFail(ExternalReadFailure.denied);
    } on FormatException {
      externalReadFail(ExternalReadFailure.dataCorrupt);
    } catch (_) {
      externalReadFail(ExternalReadFailure.dataCorrupt);
    }
  }

  Future<(ExternalQuestionKey, StudyQuestionRead)> _materialize(
      DatabaseExecutor db,
      ExternalQuestionReadAccess access,
      Map<String, Object?> selection,
      void Function() check) async {
    check();
    if (selection['id_bytes'] is! int ||
        (selection['id_bytes'] as int) > 256 ||
        selection['stored_bytes'] is! int ||
        (selection['stored_bytes'] as int) > maxStoredBytes) {
      externalReadFail(ExternalReadFailure.resourceLimit);
    }
    if (selection['id'] is! String ||
        selection['created_at'] is! int ||
        selection['row_identity'] is! int ||
        (selection['has_payload'] == 0 &&
            (selection['stem_type'] != 'text' ||
                selection['answer_type'] != 'text' ||
                selection['kind_type'] != 'integer'))) {
      externalReadFail(ExternalReadFailure.dataCorrupt);
    }
    await _checkpoint?.call(ExternalQuestionReadCheckpoint.beforeContentRead);
    check();
    final question = (await materializeExactQuestions(
            db, [selection['id'] as String],
            maxIds: 1,
            acceptsRow: (row) => row['bank_name'] == access.target.bankName))
        .single;
    await _checkpoint?.call(ExternalQuestionReadCheckpoint.afterContentRead);
    check();
    access.validate();
    final StudyQuestionRead read;
    final Object content;
    switch (question) {
      case TypedPersistedQuestion(:final draft):
        read = TypedStudyQuestionRead(
            questionId: question.storageId,
            bankName: question.bankName,
            createdAt: question.createdAt,
            draft: draft,
            review: _review);
        content = const QuestionDraftV2Codec().encode(draft);
      case LegacyPersistedQuestion(question: final legacy):
        final rawOptions = jsonDecode(legacy.options ?? '[]');
        if (rawOptions is! List ||
            rawOptions.length > 26 ||
            rawOptions.any((o) => o is! String)) {
          externalReadFail(ExternalReadFailure.dataCorrupt);
        }
        read = LegacyStudyQuestionRead(
            questionId: question.storageId,
            bankName: question.bankName,
            createdAt: question.createdAt,
            stemText: legacy.content,
            optionsText: legacy.options ?? '[]',
            answerText: legacy.answer,
            explanationText: legacy.explanation,
            legacyType: legacy.type,
            review: _review);
        content = legacy.toMap();
    }
    final key = ExternalQuestionKey(
        question.storageId,
        question.createdAt,
        selection['row_identity'] as int,
        sha256Hex(utf8.encode(jsonEncode(content))));
    check();
    return (key, read);
  }

  Future<(ExternalQuestionKey, StudyQuestionRead)> _exact(
      DatabaseExecutor db,
      ExternalQuestionReadAccess access,
      ExternalQuestionKey key,
      void Function() check) async {
    // Bank predicate precedes lookup/materialization even for a known reference.
    final rows = await db.rawQuery(
        '$_selection WHERE q.bank_name=? AND q.id=? LIMIT 1',
        [access.target.bankName, key.storageId]);
    check();
    if (rows.isEmpty) externalReadFail(ExternalReadFailure.stale);
    final result = await _materialize(db, access, rows.single, check);
    if (result.$1 != key) externalReadFail(ExternalReadFailure.stale);
    return result;
  }

  String _text(StudyContentNode node) => switch (node) {
        StudyTextNode(:final text) => text,
        StudyInlineMathNode(:final latex) ||
        StudyBlockMathNode(:final latex) =>
          latex,
        StudyUnsupportedNode() => '',
      };

  /// Same bounded materializer and identity for a statistics-selected question.
  /// The caller owns the transaction; current content authorization is checked
  /// here before selecting or materializing its exact bank-bound storage row.
  Future<ExternalQuestionCandidate> studyCandidate(
      DatabaseExecutor db,
      ExternalQuestionReadAccess access,
      String id,
      void Function() check) async {
    access.validate();
    await requireExternalGrant(
        db,
        access.runtime.profileId,
        access.revision,
        CapabilityPermission.read,
        access.target.scope,
        ExternalContentCategory.questionContent,
        access.runtime.profileId);
    check();
    final rows = await db.rawQuery(
        '$_selection WHERE q.bank_name=? AND q.id=? LIMIT 1',
        [access.target.bankName, id]);
    check();
    if (rows.length != 1) externalReadFail(ExternalReadFailure.stale);
    final value = await _materialize(db, access, rows.single, check);
    return ExternalQuestionCandidate(
        value.$1, _projection.searchItem(value.$2));
  }

  @override
  Future<ExternalQuestionCandidates> search(
          ExternalQuestionReadAccess access,
          String query,
          int limit,
          ExternalQuestionKey? after,
          void Function() check) =>
      _read(access, check, (db) async {
        if (query.isEmpty || query.length > 200 || limit < 1 || limit > 50) {
          externalReadFail(ExternalReadFailure.invalidRequest);
        }
        if (after != null) await _exact(db, access, after, check);
        final rows = await db.rawQuery('''$_selection
          WHERE q.bank_name=? AND (? IS NULL OR q.created_at < ?
            OR (q.created_at = ? AND q.id < ?))
          ORDER BY q.created_at DESC, q.id DESC LIMIT ?
        ''', [
          access.target.bankName,
          after?.createdAt,
          after?.createdAt,
          after?.createdAt,
          after?.storageId,
          maxScan + 1
        ]);
        check();
        final hits = <ExternalQuestionCandidate>[];
        ExternalQuestionKey? last;
        var scanned = 0;
        for (final row in rows.take(maxScan)) {
          final selected = await _materialize(db, access, row, check);
          last = selected.$1;
          scanned++;
          final detail =
              ExternalQuestionDetail.project(_projection.detail(selected.$2));
          final text = [...detail.stem, ...?detail.explanation]
              .map(_text)
              .join(' ')
              .toLowerCase();
          if (text.contains(query)) {
            hits.add(ExternalQuestionCandidate(
                last, _projection.searchItem(selected.$2)));
          }
          check();
          if (hits.length == limit) break;
        }
        return ExternalQuestionCandidates(
            hits, scanned < rows.length ? last : null);
      });

  @override
  Future<ExternalQuestionDetail> detail(ExternalQuestionReadAccess access,
          ExternalQuestionKey key, void Function() check) =>
      _read(access, check, (db) async {
        final selected = await _exact(db, access, key, check);
        return ExternalQuestionDetail.project(_projection.detail(selected.$2));
      });

  @override
  Future<void> release(ExternalQuestionReadAccess access,
          List<ExternalQuestionKey> keys, void Function() check) =>
      _read(access, check, (db) async {
        if (keys.length > 50 || keys.toSet().length != keys.length) {
          externalReadFail(ExternalReadFailure.resourceLimit);
        }
        for (final key in keys) {
          await _exact(db, access, key, check);
        }
      });
}
