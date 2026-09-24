import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/content_asset_reclamation_v27_schema.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/domain/attempt/answer_attempt.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
      'v26 to v27 preserves user and current derived rows; ledger starts empty',
      () async {
    final dir = await Directory.systemTemp.createTemp('reclamation27_');
    final path = '${dir.path}/user.db';
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final helper = DatabaseHelper.instance;
    Database? seed;
    Database? migrated;
    try {
      seed = await helper.openPathForTesting(path);
      final draft = QuestionDraftV2(
        questionId: 'typed-1',
        kind: QuestionKind.shortAnswer,
        stem: RichContent(nodes: <ContentNode>[TextNode('Synthetic question')]),
      );
      final frozen = const QuestionV2PersistenceMapper().freezeForWrite(
        storageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
        bankName: 'synthetic',
        createdAt: 10,
        draft: draft,
      );
      await seed.insert('questions', frozen.questionRow);
      await seed.insert('question_v2_payloads', frozen.payloadRow);
      await seed.insert('review_states', <String, Object?>{
        'question_id': 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
        'state': 1,
      });
      await seed.insert('review_logs', <String, Object?>{
        'id': 'log-1',
        'question_id': 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
        'grade': 3,
        'review_time': 10,
        'duration_ms': 20,
      });
      await seed.insert(
          'answer_attempts',
          AnswerAttempt(
            attemptId: 'attempt-1',
            questionId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
            sessionKind: AnswerAttemptSessionKind.normal,
            modality: AnswerAttemptModality.text,
            answerPayloadJson:
                AnswerAttemptPayload.text(text: 'Synthetic answer'),
            correctness: null,
            answeredAt: 11,
          ).toMap());
      await seed.insert('library_files', <String, Object?>{
        'file_id': 'file-1',
        'display_name': 'Synthetic file',
        'mime_type': 'text/plain',
        'size_bytes': 1,
        'sha256': 'a' * 64,
        'storage_key': 'files/file-1',
        'created_at': 10,
      });
      await seed.insert('parsed_artifact_heads', <String, Object?>{
        'file_id': 'file-1',
        'last_revision': 1,
      });
      await seed.insert('parsed_artifacts', <String, Object?>{
        'file_id': 'file-1',
        'artifact_id': 'artifact-1',
        'revision': 1,
        'source_sha256': 'a' * 64,
        'cache_key_version': 1,
        'cache_fingerprint': 'fingerprint',
        'parser_route': 'synthetic',
        'parser_version': '1',
        'options_schema_version': 1,
        'payload_schema_version': 1,
        'storage_key': 'parsed_artifacts/artifact-1',
        'payload_sha256': 'b' * 64,
        'size_bytes': 1,
        'published_at': 10,
      });
      await seed.insert('import_tasks', <String, Object?>{
        'id': 'task-1',
        'title': 'Synthetic import',
        'status': 1,
        'progress_text': 'review',
        'percent': 1.0,
        'created_at': 10,
      });
      await seed.execute('''
        CREATE TABLE exam_papers (
          id TEXT PRIMARY KEY, title TEXT NOT NULL, source_type INTEGER NOT NULL,
          status INTEGER NOT NULL DEFAULT 0, score REAL DEFAULT 0.0,
          total_score REAL DEFAULT 0.0, created_at INTEGER NOT NULL
        )
      ''');
      await seed.execute('''
        CREATE TABLE paper_questions (
          paper_id TEXT NOT NULL, question_id TEXT NOT NULL,
          user_answer TEXT, is_correct INTEGER DEFAULT 0,
          order_index INTEGER NOT NULL, PRIMARY KEY(paper_id, question_id)
        )
      ''');
      await seed.insert('exam_papers', <String, Object?>{
        'id': 'exam-1',
        'title': 'Synthetic exam',
        'source_type': 0,
        'created_at': 10,
      });
      await seed.insert('paper_questions', <String, Object?>{
        'paper_id': 'exam-1',
        'question_id': 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
        'order_index': 0,
      });

      const preserved = <String>[
        'questions',
        'question_v2_payloads',
        'review_states',
        'review_logs',
        'answer_attempts',
        'exam_papers',
        'paper_questions',
        'library_files',
        'parsed_artifact_heads',
        'parsed_artifacts',
        'import_tasks',
      ];
      final before = <String, List<Map<String, Object?>>>{
        for (final table in preserved) table: await seed.query(table),
      };
      await seed.execute('DROP TABLE $contentAssetReclamationTable');
      await seed.execute('PRAGMA user_version = 26');
      await seed.close();
      await helper.close();

      migrated = await helper.openPathForTesting(path);
      expect(await migrated.getVersion(), 27);
      await validateContentAssetReclamationV27Schema(migrated);
      expect(await migrated.query(contentAssetReclamationTable), isEmpty);
      for (final table in preserved) {
        expect(await migrated.query(table), before[table], reason: table);
      }
      await migrated.close();
      await helper.close();
    } finally {
      if (seed?.isOpen ?? false) await seed!.close();
      if (migrated?.isOpen ?? false) await migrated!.close();
      await helper.close();
      await DatabaseHelper.resetRuntimeProfileForTesting();
      await dir.delete(recursive: true);
    }
  });
}
