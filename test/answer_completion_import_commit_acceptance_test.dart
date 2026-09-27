import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answer_completion/document_question_set_seed.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/import/import_target_selection.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/models/typed_import_commit_guard.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _codec = DocumentQuestionSetSeedCodec();
final _seed = DocumentQuestionSetSeed(
    displayName: 'fixture.pdf', sourceFileId: 'missing-soft-source');
const _questions = <Map<String, dynamic>>[
  {
    'q_num': '1',
    'type': 3,
    'content': 'Synthetic first',
    'standard_answer': 'first answer',
    'explanation': ''
  },
  {
    'q_num': '2',
    'type': 3,
    'content': 'Synthetic second',
    'standard_answer': 'second answer',
    'explanation': ''
  },
];

QuestionDraftV2 _typedDraft(int index) => QuestionDraftV2(
      questionId: '22222222-2222-4222-8222-00000000000$index',
      kind: QuestionKind.shortAnswer,
      stem: RichContent(nodes: [TextNode('Synthetic $index')]),
    );

List<Map<String, dynamic>> _typedQuestions() => [
      for (var i = 0; i < 2; i++)
        {
          'type': 3,
          'content': 'Synthetic $i',
          'options': <String>[],
          'standard_answer': '',
          'explanation': '',
          TaskManager.keyReviewItemId: '44444444-4444-4444-8444-00000000000$i',
          TypedReviewSnapshotCodec.mapKey:
              const TypedReviewSnapshotCodec().encode(TypedReviewSnapshot(
            reviewItemId: '44444444-4444-4444-8444-00000000000$i',
            questionId: _typedDraft(i).questionId,
            draft: _typedDraft(i),
            baselineLegacy: LegacyReviewBaseline(
                questionNumber: null,
                type: 3,
                content: 'Synthetic $i',
                options: const [],
                standardAnswer: '',
                explanation: ''),
          )),
        },
    ];

Future<void> _insertTask(
    Database db, String id, bool typed, Map<String, Object?> entry,
    {String? folder = 'folder'}) async {
  await db.insert(
      'import_tasks',
      ImportTask(
        id: id,
        title: 'Synthetic',
        status: TaskStatus.pendingReview,
        bankName: 'bank',
        folderName: folder,
        parsedData: typed ? _typedQuestions() : _questions,
        diagnostics: {
          TaskManager.keyAttemptToken: 'attempt',
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyTraceId: 'trace',
          TaskManager.keyAttemptState: 'readyForReview',
          TaskManager.keyReviewDraftRevision: 1,
          TaskManager.keyImportStorageRoute: typed ? 'typedV2' : 'legacyV1',
          if (typed)
            TaskManager.keyImportStorageReason: 'typed_candidate_ready',
          ...entry,
        },
      ).toMap());
}

Future<void> _commit(String id, bool typed,
    {String token = 'attempt',
    String trace = 'trace',
    String? folderName = 'folder'}) async {
  final repository = QuestionRepository();
  if (typed) {
    await repository.commitQuestionDraftsV2ForImport(
      bankName: 'bank',
      folderName: folderName,
      questions: [for (var i = 0; i < 2; i++) _typedDraft(i)],
      guard: TypedImportCommitGuard(
          taskId: id,
          attemptToken: token,
          attemptNumber: 1,
          reviewDraftRevision: 1,
          storageRoute: 'typedV2',
          storageReason: 'typed_candidate_ready'),
      completionText: 'complete',
    );
  } else {
    await repository.commitQuestionDraftsLegacyForImport(
      bankName: 'bank',
      folderName: folderName,
      questions: QuestionDraft.listFromMaps(_questions),
      guard: LegacyImportCommitGuard(
          taskId: id,
          attemptToken: token,
          attemptNumber: 1,
          traceId: trace,
          reviewDraftRevision: 1,
          storageRoute: 'legacyV1',
          storageReason: null),
      completionText: 'complete',
    );
  }
}

Map<String, Object?> _entry() => {
      documentImportEntryMarkerKey: documentQuestionSetImportEntryMarkerValue,
      importTargetKindMarkerKey: ImportTargetKind.existing.name,
      questionSetCaptureMetadataKey: _codec.encode(_seed),
    };

Future<void> _expectRollback(Database db) async {
  for (final table in [
    'questions',
    'question_v2_payloads',
    'review_states',
    'bank_folders',
    'imported_question_sets',
    'imported_question_set_items'
  ]) {
    expect(await db.query(table), isEmpty, reason: table);
  }
  final tasks = await db.query('import_tasks');
  expect(tasks.single['status'], TaskStatus.pendingReview.index);
  expect(tasks.single['parsed_data'], isNotNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });
  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  for (final typed in [true, false]) {
    final route = typed ? 'typed' : 'legacy';
    test(
        '$route v4 writes ordered actual storage IDs and duplicate import is independent',
        () async {
      final db = await DatabaseHelper.instance.database;
      for (var i = 0; i < 2; i++) {
        await _insertTask(db, 'task-$i', typed, _entry());
        await _commit('task-$i', typed);
      }
      final sets = await db.query('imported_question_sets');
      expect(sets, hasLength(2));
      expect(sets.map((row) => row['set_id']).toSet(), hasLength(2));
      for (final set in sets) {
        expect(set['display_name'], _seed.displayName);
        expect(set['source_file_id'], _seed.sourceFileId);
        final rows = await db.rawQuery('''SELECT i.position, q.id, q.content
          FROM imported_question_set_items i JOIN questions q ON q.id = i.question_storage_id
          WHERE i.set_id = ? ORDER BY i.position''', [set['set_id']]);
        expect(rows.map((row) => row['position']), [0, 1]);
        expect(
            rows.map((row) => row['content']),
            typed
                ? ['Synthetic 0', 'Synthetic 1']
                : ['Synthetic first', 'Synthetic second']);
        expect(rows.every((row) => !row['id'].toString().startsWith('source-')),
            isTrue);
      }
      expect(await db.query('questions'), hasLength(4));
      expect(await db.query('review_states'), hasLength(4));
      expect(await db.query('question_v2_payloads'), hasLength(typed ? 4 : 0));
      await expectLater(_commit('task-0', typed), throwsA(isA<Exception>()));
      expect(await db.query('imported_question_sets'), hasLength(2));
    });

    test('$route v3 without seed stays compatible', () async {
      final db = await DatabaseHelper.instance.database;
      await _insertTask(db, 'task', typed,
          {documentImportEntryMarkerKey: documentImportEntryMarkerValue});
      await _commit('task', typed);
      expect(await db.query('questions'), hasLength(2));
      expect(await db.query('imported_question_sets'), isEmpty);
    });

    final invalid = <String, Map<String, Object?>>{
      'missing': {
        documentImportEntryMarkerKey: documentQuestionSetImportEntryMarkerValue
      },
      'null': {..._entry(), questionSetCaptureMetadataKey: null},
      'wrong type': {..._entry(), questionSetCaptureMetadataKey: 'invalid'},
      'unknown version': {
        ..._entry(),
        questionSetCaptureMetadataKey: {
          ..._codec.encode(_seed),
          'schemaVersion': 2
        }
      },
      'missing field': {
        ..._entry(),
        questionSetCaptureMetadataKey: {..._codec.encode(_seed)}
          ..remove('sourceFileId')
      },
      'extra field': {
        ..._entry(),
        questionSetCaptureMetadataKey: {..._codec.encode(_seed), 'extra': true}
      },
      'oversize': {
        ..._entry(),
        questionSetCaptureMetadataKey: {
          ..._codec.encode(_seed),
          'displayName': 'x' * 5000
        }
      },
      'v3 seed': {
        ..._entry(),
        documentImportEntryMarkerKey: documentImportEntryMarkerValue
      },
      'non-document valid seed': {
        questionSetCaptureMetadataKey: _codec.encode(_seed)
      },
      'non-document invalid seed': {questionSetCaptureMetadataKey: null},
      'unknown entry': {documentImportEntryMarkerKey: 'document_v5'},
      'wrong-type entry': {documentImportEntryMarkerKey: 7},
      'null entry': {documentImportEntryMarkerKey: null},
    };
    for (final entry in invalid.entries) {
      test('$route ${entry.key} rejects with zero learning writes', () async {
        final db = await DatabaseHelper.instance.database;
        await _insertTask(db, 'task', typed, entry.value);
        await expectLater(
            _commit('task', typed),
            throwsA(typed
                ? isA<TypedImportCommitPersistenceException>().having(
                    (e) => e.failure,
                    'failure',
                    TypedImportCommitPersistenceFailure.invalidTaskMetadata)
                : isA<LegacyImportCommitPersistenceException>().having(
                    (e) => e.failure,
                    'failure',
                    LegacyImportCommitPersistenceFailure.invalidTaskMetadata)));
        await _expectRollback(db);
      });
    }
    test('$route v4 without persisted target kind rejects with zero writes',
        () async {
      final db = await DatabaseHelper.instance.database;
      await _insertTask(
          db, 'task', typed, {..._entry()}..remove(importTargetKindMarkerKey));
      await expectLater(
          _commit('task', typed),
          throwsA(typed
              ? isA<TypedImportCommitPersistenceException>().having(
                  (e) => e.failure,
                  'failure',
                  TypedImportCommitPersistenceFailure.invalidTaskMetadata)
              : isA<LegacyImportCommitPersistenceException>().having(
                  (e) => e.failure,
                  'failure',
                  LegacyImportCommitPersistenceFailure.invalidTaskMetadata)));
      await _expectRollback(db);
    });
    test('$route v4 proposedNew commit binds the persisted frozen folder',
        () async {
      final db = await DatabaseHelper.instance.database;
      await _insertTask(
          db,
          'task',
          typed,
          {
            ..._entry(),
            importTargetKindMarkerKey: ImportTargetKind.proposedNew.name,
          },
          folder: 'frozen folder');
      await expectLater(
          _commit('task', typed, folderName: 'drifted folder'),
          throwsA(typed
              ? isA<TypedImportCommitPersistenceException>().having(
                  (e) => e.failure,
                  'failure',
                  TypedImportCommitPersistenceFailure.invalidTaskMetadata)
              : isA<LegacyImportCommitPersistenceException>().having(
                  (e) => e.failure,
                  'failure',
                  LegacyImportCommitPersistenceFailure.invalidTaskMetadata)));
      await _expectRollback(db);
      await _commit('task', typed, folderName: 'frozen folder');
      expect(await db.query('imported_question_sets'), hasLength(1));
      expect(await db.query('questions'), hasLength(2));
    });
    for (final fault in ['set', 'member', 'completion CAS']) {
      test('$route $fault failure rolls back the entire outer transaction',
          () async {
        final db = await DatabaseHelper.instance.database;
        await _insertTask(db, 'task', typed, _entry());
        final sql = switch (fault) {
          'set' =>
            "CREATE TRIGGER synthetic_failure BEFORE INSERT ON imported_question_sets BEGIN SELECT RAISE(ABORT, 'synthetic'); END",
          'member' =>
            "CREATE TRIGGER synthetic_failure BEFORE INSERT ON imported_question_set_items WHEN NEW.position = 1 BEGIN SELECT RAISE(ABORT, 'synthetic'); END",
          _ =>
            "CREATE TRIGGER synthetic_failure BEFORE UPDATE OF status ON import_tasks WHEN NEW.status = 2 BEGIN SELECT RAISE(IGNORE); END",
        };
        await db.execute(sql);
        await expectLater(_commit('task', typed), throwsA(isA<Exception>()));
        await _expectRollback(db);
      });
    }
  }

  for (final value in <Object?>[_codec.encode(_seed), null]) {
    test(
        'reserved ${value == null ? 'null' : 'valid seed'} survives replacement Review reload and OCR retry',
        () async {
      final db = await DatabaseHelper.instance.database;
      final manager = TaskManager.forTesting(
          saveTask: DatabaseHelper.instance.saveImportTask);
      await manager.ready;
      final task = ImportTask(
          id: 'lifecycle',
          title: 'Synthetic',
          bankName: 'bank',
          diagnostics: {
            ..._entry(),
            questionSetCaptureMetadataKey: value,
            TaskManager.keyAttemptNumber: 1,
            TaskManager.keyAttemptToken: 'attempt',
            TaskManager.keyTraceId: 'trace',
            TaskManager.keyParseMode: 'ocr',
            TaskManager.keyAttemptState: 'queued',
          });
      expect(
          await manager.addAttemptTask(task), ImportAttemptWriteStatus.applied);
      expect(
          await manager.requireAttemptReview(
              task.attemptRef!, 'Review', _questions, '', '',
              diagnostics: {
                questionSetCaptureMetadataKey: {'attacker': true},
                documentImportEntryMarkerKey: 'document_v3'
              }),
          ImportAttemptWriteStatus.applied);
      final saved = await manager.saveReviewDraft(task.id,
          questions: _questions,
          explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes);
      expect(saved.status, ReviewDraftSaveStatus.saved);
      final reloaded = TaskManager.forTesting(
          saveTask: DatabaseHelper.instance.saveImportTask,
          loadTasks: DatabaseHelper.instance.getAllImportTasks,
          deleteOldImportTasks: (_) async {});
      await reloaded.ready;
      final durable = reloaded.tasks.single;
      expect(durable.diagnostics!.containsKey(questionSetCaptureMetadataKey),
          isTrue);
      expect(durable.diagnostics![questionSetCaptureMetadataKey], value);
      expect(durable.diagnostics![documentImportEntryMarkerKey],
          documentQuestionSetImportEntryMarkerValue);
      // Retry belongs to a failed active attempt, never a pending Review.
      final retryTask = ImportTask(
          id: 'retry',
          title: 'Synthetic',
          bankName: 'bank',
          diagnostics: {
            ...durable.diagnostics!,
            TaskManager.keyAttemptState: 'queued'
          });
      expect(await reloaded.addAttemptTask(retryTask),
          ImportAttemptWriteStatus.applied);
      expect(
          await reloaded.failAttempt(
              retryTask.attemptRef!, 'Synthetic failure'),
          ImportAttemptWriteStatus.applied);
      expect(
          await reloaded.restartAttempt(
              ImportAttemptRef(
                  taskId: retryTask.id,
                  attemptNumber: 2,
                  attemptToken: 'next',
                  traceId: 'next-trace'),
              parseMode: 'ocr',
              explanationRetentionMode:
                  ExplanationRetentionMode.allQuestionTypes),
          ImportAttemptWriteStatus.applied);
      final row = (await db
              .query('import_tasks', where: 'id = ?', whereArgs: ['retry']))
          .single;
      final diagnostics = jsonDecode(row['diagnostics']! as String) as Map;
      expect(diagnostics.containsKey(questionSetCaptureMetadataKey), isTrue);
      expect(diagnostics[questionSetCaptureMetadataKey], value);
      final restarted = TaskManager.forTesting(
          saveTask: DatabaseHelper.instance.saveImportTask,
          loadTasks: DatabaseHelper.instance.getAllImportTasks,
          deleteOldImportTasks: (_) async {});
      await restarted.ready;
      final interrupted =
          restarted.tasks.singleWhere((task) => task.id == 'retry');
      expect(interrupted.attemptState, ImportAttemptState.interrupted);
      expect(
          interrupted.diagnostics!.containsKey(questionSetCaptureMetadataKey),
          isTrue);
      expect(interrupted.diagnostics![questionSetCaptureMetadataKey], value);
      restarted.dispose();
      manager.dispose();
      reloaded.dispose();
    });
  }

  test('parser cannot synthesize reserved seed on non-document dispatch',
      () async {
    final manager = TaskManager.forTesting();
    final done = Completer<void>();
    final coordinator = ImportTaskCoordinator(
        taskManager: manager, onReadyForReview: (_) => done.complete());
    final handle = await coordinator.dispatch(
        sourceDescription: 'image collection',
        mode: ImportParseMode.ocr,
        parse: (_) async =>
            ImportParseResult(questions: _questions, diagnostics: _entry()));
    await done.future;
    final diagnostics = manager.tasks.single.diagnostics!;
    expect(diagnostics.containsKey(questionSetCaptureMetadataKey), isFalse);
    expect(diagnostics.containsKey(documentImportEntryMarkerKey), isFalse);
    expect(handle.taskId, manager.tasks.single.id);
    manager.dispose();
  });
  test('document batch proposed target rejects before any task or parser',
      () async {
    final manager = TaskManager.forTesting();
    var parserCalls = 0;
    final coordinator = ImportTaskCoordinator(taskManager: manager);
    await expectLater(
        coordinator.dispatchIndependentBatch(items: [
          for (var i = 0; i < 2; i++)
            ImportTaskBatchItem(
                sourceDescription: '$i.pdf',
                mode: ImportParseMode.text,
                documentImportEntry: true,
                questionSetSeed: _seed,
                bankName: 'new',
                targetKind: ImportTargetKind.proposedNew,
                parse: (_) async {
                  parserCalls++;
                  return const ImportParseResult(questions: _questions);
                }),
        ]),
        throwsA(isA<ImportDocumentBatchTargetException>()));
    expect(manager.tasks, isEmpty);
    expect(parserCalls, 0);
    manager.dispose();
  });

  for (final failFirst in [false, true]) {
    test(
        'two selected documents have independent commits; first failure=$failFirst',
        () async {
      final db = await DatabaseHelper.instance.database;
      await QuestionRepository().saveQuestionDraftsToBank(
          bankName: 'bank',
          folderName: '',
          questions: QuestionDraft.listFromMaps(_questions));
      final manager = TaskManager.forTesting(
          saveTask: DatabaseHelper.instance.saveImportTask);
      final settled = Completer<void>();
      manager.addListener(() {
        if (manager.tasks.length == 2 &&
            manager.tasks
                .every((task) => task.status != TaskStatus.processing) &&
            !settled.isCompleted) {
          settled.complete();
        }
      });
      final coordinator = ImportTaskCoordinator(taskManager: manager);
      final batch = await coordinator.dispatchIndependentBatch(items: [
        for (var i = 0; i < 2; i++)
          ImportTaskBatchItem(
              sourceDescription: '$i.txt',
              mode: ImportParseMode.text,
              documentImportEntry: true,
              questionSetSeed: DocumentQuestionSetSeed(
                  displayName: '$i.txt', sourceFileId: 'source-$i'),
              bankName: 'bank',
              targetKind: ImportTargetKind.existing,
              parse: (_) async {
                if (i == 0 && failFirst) throw StateError('Synthetic failure');
                return ImportParseResult(
                    questions: _questions,
                    diagnostics: {questionSetCaptureMetadataKey: null});
              }),
      ]);
      await settled.future;
      expect(batch.tasks, hasLength(2));
      for (final task in manager.tasks
          .where((task) => task.status == TaskStatus.pendingReview)) {
        expect(task.diagnostics![documentImportEntryMarkerKey],
            documentQuestionSetImportEntryMarkerValue);
        final seed = readDocumentQuestionSetSeed(task.diagnostics!);
        expect(seed, isNotNull);
        final saved = await manager.saveReviewDraft(task.id,
            questions: task.parsedData!,
            explanationRetentionMode:
                ExplanationRetentionMode.allQuestionTypes);
        expect(saved.status, ReviewDraftSaveStatus.saved);
        await _commit(task.id, false,
            token: task.attemptToken!, trace: task.traceId!);
      }
      final sets = await db.query('imported_question_sets');
      expect(sets, hasLength(failFirst ? 1 : 2));
      expect(sets.map((row) => row['display_name']).toSet(),
          failFirst ? {'1.txt'} : {'0.txt', '1.txt'});
      expect(sets.map((row) => row['source_file_id']).toSet(),
          failFirst ? {'source-1'} : {'source-0', 'source-1'});
      expect(await db.query('imported_question_set_items'),
          hasLength(failFirst ? 2 : 4));
      manager.dispose();
    });
  }

  test('single ZIP proposed bank creates one task and set with null provenance',
      () async {
    final db = await DatabaseHelper.instance.database;
    final manager = TaskManager.forTesting(
        saveTask: DatabaseHelper.instance.saveImportTask);
    final ready = Completer<void>();
    final coordinator = ImportTaskCoordinator(
        taskManager: manager, onReadyForReview: (_) => ready.complete());
    final handle = await coordinator.dispatch(
        sourceDescription: 'fixture.zip',
        mode: ImportParseMode.text,
        documentImportEntry: true,
        questionSetSeed: DocumentQuestionSetSeed(displayName: 'fixture.zip'),
        bankName: 'bank',
        targetKind: ImportTargetKind.proposedNew,
        parse: (_) async => const ImportParseResult(questions: _questions));
    await ready.future.timeout(const Duration(seconds: 10));
    expect(manager.tasks, hasLength(1));
    expect(
        (await manager.saveReviewDraft(handle.taskId,
                questions: _questions,
                explanationRetentionMode:
                    ExplanationRetentionMode.allQuestionTypes))
            .status,
        ReviewDraftSaveStatus.saved);
    await _commit(handle.taskId, false,
        token: handle.attemptToken, trace: handle.traceId, folderName: null);
    final sets = await db.query('imported_question_sets');
    expect(sets, hasLength(1));
    expect(sets.single['source_file_id'], isNull);
    expect(await db.query('imported_question_set_items'), hasLength(2));
    manager.dispose();
  });
  test('typed v4 create parse RD0 persistence and reload preserve exact seed',
      () async {
    final helper = DatabaseHelper.instance;
    final manager = TaskManager.forTesting(saveTask: helper.saveImportTask);
    final ready = Completer<void>();
    final coordinator = ImportTaskCoordinator(
        taskManager: manager, onReadyForReview: (_) => ready.complete());
    await coordinator.dispatch(
        sourceDescription: 'fixture.pdf',
        mode: ImportParseMode.ocr,
        documentImportEntry: true,
        questionSetSeed: _seed,
        bankName: 'bank',
        targetKind: ImportTargetKind.existing,
        parse: (taskId) async {
          final created = (await helper.getAllImportTasks()).single;
          expect(
              (jsonDecode(created['diagnostics']! as String)
                  as Map)[questionSetCaptureMetadataKey],
              _codec.encode(_seed));
          return ImportParseResult.withStorageMetadata(
              questions: _typedQuestions(),
              diagnostics: {
                questionSetCaptureMetadataKey: {'capture': false}
              },
              storageRoute: ImportStorageRoute.typedV2,
              storageReason: 'typed_candidate_ready');
        });
    await ready.future.timeout(const Duration(seconds: 10));
    final reloaded = TaskManager.forTesting(
        loadTasks: helper.getAllImportTasks,
        deleteOldImportTasks: (_) async {});
    await reloaded.ready;
    final task = reloaded.tasks.single;
    expect(reloaded.reviewDraftRevision(task.id), 1);
    expect(task.status, TaskStatus.pendingReview);
    expect(
        task.diagnostics![questionSetCaptureMetadataKey], _codec.encode(_seed));
    manager.dispose();
    reloaded.dispose();
  });
}
