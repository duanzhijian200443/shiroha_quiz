import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/answer_attempt_v23_schema.dart';
import 'package:shiroha_quiz/core/database/answer_attempt_v26_schema.dart';
import 'package:shiroha_quiz/core/database/content_asset_reclamation_v27_schema.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/attempt/answer_attempt.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test('v25 staged backup rebuild preserves every old field; v26 accepts image',
      () async {
    final dir = await Directory.systemTemp.createTemp('attempt26_');
    final path = '${dir.path}/staged.db';
    await DatabaseHelper.resetRuntimeProfileForTesting();
    try {
      final seed = await DatabaseHelper.instance.openPathForTesting(path);
      expect(await seed.getVersion(), contentAssetReclamationSchemaVersion);
      await validateAnswerAttemptV26Schema(seed);
      await seed.execute('DROP TABLE answer_attempts');
      await createAnswerAttemptV23Schema(seed);
      for (var i = 0; i < 3; i++) {
        await seed.insert('answer_attempts', {
          'attempt_id': 'old-$i',
          'question_id': 'q',
          'session_kind': ['normal', 'focused', 'exam'][i],
          'modality': i == 0 ? 'choice' : 'text',
          'answer_payload_json': i == 0
              ? AnswerAttemptPayload.choice(optionIds: ['a'])
              : AnswerAttemptPayload.text(text: '旧答案'),
          'correctness': [null, 0, 1][i],
          'answered_at': 100 + i,
          'duration_ms': i == 0 ? null : i * 10,
        });
      }
      final before = await seed.query('answer_attempts', orderBy: 'attempt_id');
      await seed.execute('PRAGMA user_version = 25');
      await seed.close();
      await BackupSnapshotRepository(databaseHelper: DatabaseHelper.instance)
          .openStagedAndValidate(path);
      final db = await DatabaseHelper.instance.openPathForTesting(path);
      try {
        expect(await db.getVersion(), contentAssetReclamationSchemaVersion);
        expect(
            await db.query('answer_attempts', orderBy: 'attempt_id'), before);
        await validateAnswerAttemptV26Schema(db);
        await db.insert(
            'answer_attempts',
            AnswerAttempt(
              attemptId: 'image',
              questionId: 'q',
              sessionKind: AnswerAttemptSessionKind.focused,
              modality: AnswerAttemptModality.image,
              answerPayloadJson:
                  AnswerAttemptPayload.image(sourceFileId: 'missing-file'),
              correctness: null,
              answeredAt: 200,
            ).toMap());
        final image = AnswerAttempt.fromMap((await db.query('answer_attempts',
                where: 'attempt_id = ?', whereArgs: ['image']))
            .single);
        expect(image.correctness, isNull);
        expect(image.modality, AnswerAttemptModality.image);
        expect(await db.rawQuery('PRAGMA foreign_key_list(answer_attempts)'),
            isEmpty);
        await DatabaseHelper.validateStagedBackupSchema(db);
      } finally {
        await db.close();
      }
    } finally {
      await DatabaseHelper.resetRuntimeProfileForTesting();
      await dir.delete(recursive: true);
    }
  });
  test(
      'image payload allows absent/empty transcription, rejects paths and second correctness',
      () {
    for (final transcription in [null, '']) {
      AnswerAttemptPayload.validateForModality(
          AnswerAttemptModality.image,
          AnswerAttemptPayload.image(
              sourceFileId: 'file-1', transcription: transcription));
    }
    expect(() => AnswerAttemptPayload.image(sourceFileId: '/tmp/a.jpg'),
        throwsFormatException);
    expect(
        () => AnswerAttemptPayload.validatePayloadJson(
            '{"version":1,"kind":"image","source_file_id":"f","correctness":true}'),
        throwsFormatException);
  });
}
