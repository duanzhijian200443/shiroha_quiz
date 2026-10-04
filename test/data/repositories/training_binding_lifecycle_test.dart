import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/training_content_binding_lifecycle.dart';
import 'package:shiroha_quiz/core/database/training_content_v29_schema.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:shiroha_quiz/data/repositories/training_configuration_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/domain/training/training_content.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';

const _key = UncategorizedCategoryKey();

T _success<T>(HomeTrainingResult<T> result) {
  expect(result, isA<HomeTrainingSuccess<T>>());
  return (result as HomeTrainingSuccess<T>).value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late QuestionRepository questions;
  late TrainingConfigurationRepository configs;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    db = await DatabaseHelper.instance.database;
    questions = QuestionRepository();
    configs = TrainingConfigurationRepository();
  });
  tearDown(() async {
    BackupRestoreMutationGate.resetForTesting();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  Future<void> question(String id,
      {String bank = 'Bank', String? folder}) async {
    await db.insert('questions', {
      'id': id,
      'bank_name': bank,
      'type': 0,
      'content': 'synthetic',
      'standard_answer': 'A',
      'created_at': 1
    });
    await db.insert('review_states', {'question_id': id, 'state': 0});
    await db.insert('review_logs', {
      'id': 'log-$id',
      'question_id': id,
      'grade': 3,
      'review_time': 1,
      'duration_ms': 1
    });
    await db.insert('answer_attempts', {
      'attempt_id': 'attempt-$id',
      'question_id': id,
      'session_kind': 'normal',
      'modality': 'text',
      'answer_payload_json': '{}',
      'answered_at': 1
    });
    if (folder != null) {
      await db.insert(
          'bank_folders', {'bank_name': bank, 'folder_name': folder},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<TrainingContent> content(
          {CategoryKey key = _key,
          List<String> banks = const ['Bank']}) async =>
      _success(await configs.create(CreateTrainingContentRequest(
          categoryKey: key,
          edit: TrainingContentEdit(
              name: 'Training',
              questionLimit: 40,
              sortOrder: 0,
              members: [
                for (var i = 0; i < banks.length; i++)
                  TrainingContentMember(
                      bankName: banks[i],
                      position: i,
                      weightPercent: i == 0 ? 100 : 0)
              ]))));

  Future<TrainingContent> saved(TrainingContent initial) async =>
      _success(await configs.getById(initial.contentId)).content;

  Future<void> expectBinding(TrainingContent initial,
      {int revision = 2,
      TrainingBindingStatus status = TrainingBindingStatus.invalidated,
      TrainingBindingInvalidationReason? reason =
          TrainingBindingInvalidationReason.bankMissing}) async {
    final value = await saved(initial);
    expect(value.revision, revision);
    expect(value.members.every((member) => member.bindingStatus == status),
        isTrue);
    expect(value.members.every((member) => member.invalidationReason == reason),
        isTrue);
    expect(value.members.map((member) => member.weightPercent),
        initial.members.map((member) => member.weightPercent));
    expect(value.members.map((member) => member.position),
        initial.members.map((member) => member.position));
  }

  Future<String> snapshot() async {
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name");
    return jsonEncode({
      for (final table in tables)
        table['name'] as String:
            (await db.rawQuery('SELECT * FROM "${table['name']}"'))
                .map(jsonEncode)
                .toList()
              ..sort()
    });
  }

  Future<void> failsAtomically(Future<void> Function() mutation) async {
    final before = await snapshot();
    await expectLater(mutation(), throwsA(isA<Exception>()));
    expect(await snapshot(), before);
  }

  Future<void> rejectInvalidation({bool revision = false}) => db.execute(
      "CREATE TRIGGER synthetic_failure BEFORE UPDATE ON ${revision ? trainingContentsTable : trainingContentMembersTable} BEGIN SELECT RAISE(ABORT, 'synthetic'); END");

  test('nullable historical bank rows do not block legacy mutation', () async {
    await question('ordinary');
    final initial = await content();
    for (final id in ['delete-null', 'update-null', 'preview-null']) {
      await db.insert('questions', {
        'id': id,
        'bank_name': null,
        'type': 0,
        'content': 'synthetic',
        'standard_answer': 'A',
        'created_at': 1,
      });
    }
    await questions.deleteQuestion('delete-null');
    await DatabaseHelper.instance
        .updateQuestion({'id': 'update-null', 'bank_name': 'Bank'});
    await questions.savePreviewQuestion({
      'id': 'preview-null',
      'bank_name': 'Bank',
      'type': 0,
      'content': 'synthetic',
      'standard_answer': 'A',
      'created_at': 1,
    });
    expect(
        await db
            .query('questions', where: 'id = ?', whereArgs: ['delete-null']),
        isEmpty);
    expect((await saved(initial)).revision, 1);
    expect((await saved(initial)).members.single.bindingStatus,
        TrainingBindingStatus.valid);
  });

  test(
      'whole-bank deletion invalidates every sharing content and preserves preferences/global selection',
      () async {
    await question('q');
    await question('other', bank: 'Other');
    final a = await content();
    final b = await content();
    final unrelated = await content(banks: ['Other']);
    _success(await configs.selectCurrent(SelectTrainingContentRequest(
        target:
            TrainingPreferenceTarget(categoryKey: _key, expectedRevision: null),
        contentId: a.contentId)));
    final prefs = await db.query(trainingCategoryPreferencesTable);
    final global = await db.query('app_settings');
    await questions.deleteQuestionBank('Bank');
    await expectBinding(a);
    await expectBinding(b);
    await expectBinding(unrelated,
        revision: 1, status: TrainingBindingStatus.valid, reason: null);
    expect(await db.query(trainingCategoryPreferencesTable), prefs);
    expect(await db.query('app_settings'), global);
    final current = _success(await configs.current());
    expect(current.preference!.currentContentId, a.contentId);
    expect(current.currentContent!.content.contentId, unrelated.contentId);
    await validateTrainingContentV29Data(db);
  });

  test(
      'single deletion retains binding until last question disappears, with learning/set cleanup unchanged',
      () async {
    await question('q1');
    await question('q2');
    final config = await content();
    await db.insert('question_v2_payloads', {
      'question_id': 'q2',
      'payload_schema_version': 2,
      'payload_json': '{"synthetic":true}'
    });
    await db.insert('imported_question_sets', {
      'set_id': 'set',
      'bank_name': 'Bank',
      'display_name': 'Set',
      'created_at': 1
    });
    await db.insert('imported_question_set_items',
        {'set_id': 'set', 'question_storage_id': 'q2', 'position': 0});
    await questions.deleteQuestion('q1');
    await expectBinding(config,
        revision: 1, status: TrainingBindingStatus.valid, reason: null);
    await questions.deleteQuestion('q2');
    await expectBinding(config);
    expect(await db.query('questions'), isEmpty);
    expect(await db.query('question_v2_payloads'), isEmpty);
    expect(await db.query('review_states'), isEmpty);
    expect(await db.query('review_logs'), isEmpty);
    expect(await db.query('answer_attempts'), hasLength(2));
    expect(await db.query('imported_question_sets'), isEmpty);
    expect(await db.query('imported_question_set_items'), isEmpty);
  });

  test(
      'legacy movement invalidates old bank only on final move-out and detaches QuestionSet membership',
      () async {
    await question('q1');
    await question('q2');
    final config = await content();
    await db.insert('imported_question_sets', {
      'set_id': 'set',
      'bank_name': 'Bank',
      'display_name': 'Set',
      'created_at': 1
    });
    await db.insert('imported_question_set_items',
        {'set_id': 'set', 'question_storage_id': 'q2', 'position': 0});
    await questions.updateQuestion({'id': 'q1', 'bank_name': 'New'});
    await expectBinding(config,
        revision: 1, status: TrainingBindingStatus.valid, reason: null);
    await questions.updateQuestion({'id': 'q2', 'bank_name': 'New'});
    await expectBinding(config);
    expect(await db.query('imported_question_sets'), isEmpty);
    expect(await db.query('review_states'), hasLength(2));
    expect(await db.query('answer_attempts'), hasLength(2));
    expect(await db.query(trainingContentMembersTable), hasLength(1));
  });

  test(
      'folder movement and move-back never restore binding or advance preferences',
      () async {
    await question('q', folder: 'Math');
    final config = await content(key: FolderCategoryKey('Math'));
    _success(await configs.selectCurrent(SelectTrainingContentRequest(
        target: TrainingPreferenceTarget(
            categoryKey: config.categoryKey, expectedRevision: null),
        contentId: config.contentId)));
    final prefs = await db.query(trainingCategoryPreferencesTable);
    await questions.updateBankFolder('Bank', 'Math');
    await expectBinding(config,
        revision: 1, status: TrainingBindingStatus.valid, reason: null);
    await questions.updateBankFolder('Bank', 'English');
    await expectBinding(config,
        reason: TrainingBindingInvalidationReason.categoryChanged);
    await questions.updateBankFolder('Bank', 'Math');
    await expectBinding(config,
        reason: TrainingBindingInvalidationReason.categoryChanged);
    expect(await db.query(trainingCategoryPreferencesTable), prefs);
    await validateTrainingContentV29Data(db);
  });

  test(
      'same exact bank recreation remains invalidated until explicit fresh-CAS rebind',
      () async {
    await question('q');
    final config = await content();
    await questions.deleteQuestionBank('Bank');
    await questions.savePreviewQuestion({
      'id': 'new-q',
      'bank_name': 'Bank',
      'content': 'synthetic',
      'standard_answer': 'A'
    });
    _success(await configs.capture());
    await expectBinding(config);
    expect(_success(await configs.getById(config.contentId)).usable, isFalse);
    await validateTrainingContentV29Data(db);
    final stale = await configs.rebindMember(RebindTrainingContentMemberRequest(
        target: TrainingContentTarget(
            contentId: config.contentId, expectedRevision: 1),
        bankName: 'Bank'));
    expect((stale as HomeTrainingFailed<TrainingContent>).failure,
        HomeTrainingFailure.stale);
    final rebound = _success(await configs.rebindMember(
        RebindTrainingContentMemberRequest(
            target: TrainingContentTarget(
                contentId: config.contentId, expectedRevision: 2),
            bankName: 'Bank')));
    expect(rebound.revision, 3);
    expect(rebound.members.single.bindingStatus, TrainingBindingStatus.valid);
    expect(rebound.members.single.invalidationReason, isNull);
  });

  test(
      'P2a carry-over missing bank is invalidated before same-name recreation heals it',
      () async {
    await question('q');
    final config = await content();
    // P2a-era durable deletion: no P2b writer runs, so the binding stays
    // valid while the bank is already gone.
    await db.delete('questions', where: 'bank_name = ?', whereArgs: ['Bank']);
    await expectBinding(config,
        revision: 1, status: TrainingBindingStatus.valid, reason: null);
    expect(_success(await configs.getById(config.contentId)).usable, isFalse);
    // A P2b writer recreates the exact bank name.
    await questions.savePreviewQuestion({
      'id': 'new-q',
      'bank_name': 'Bank',
      'content': 'synthetic',
      'standard_answer': 'A'
    });
    await expectBinding(config);
    expect(_success(await configs.getById(config.contentId)).usable, isFalse);
    await validateTrainingContentV29Data(db);
    final rebound = _success(await configs.rebindMember(
        RebindTrainingContentMemberRequest(
            target: TrainingContentTarget(
                contentId: config.contentId, expectedRevision: 2),
            bankName: 'Bank')));
    expect(rebound.revision, 3);
    expect(rebound.members.single.bindingStatus, TrainingBindingStatus.valid);
    expect(_success(await configs.getById(config.contentId)).usable, isTrue);
  });

  test('P2a carry-over moved bank is invalidated before move-back heals it',
      () async {
    await question('q', folder: 'Math');
    final config = await content(key: FolderCategoryKey('Math'));
    // P2a-era durable folder move: no P2b writer runs, so the binding stays
    // valid while the bank is in another Category.
    await db.update('bank_folders', {'folder_name': 'English'},
        where: 'bank_name = ?', whereArgs: ['Bank']);
    await expectBinding(config,
        revision: 1, status: TrainingBindingStatus.valid, reason: null);
    expect(_success(await configs.getById(config.contentId)).usable, isFalse);
    // A P2b writer moves the bank back into the content Category.
    await questions.updateBankFolder('Bank', 'Math');
    await expectBinding(config,
        reason: TrainingBindingInvalidationReason.categoryChanged);
    expect(_success(await configs.getById(config.contentId)).usable, isFalse);
    await validateTrainingContentV29Data(db);
    final rebound = _success(await configs.rebindMember(
        RebindTrainingContentMemberRequest(
            target: TrainingContentTarget(
                contentId: config.contentId, expectedRevision: 2),
            bankName: 'Bank')));
    expect(rebound.revision, 3);
    expect(rebound.members.single.bindingStatus, TrainingBindingStatus.valid);
    expect(_success(await configs.getById(config.contentId)).usable, isTrue);
  });

  test(
      'clear-all invalidates multiple members once per content and is idempotent',
      () async {
    await question('q1');
    await question('q2', bank: 'Second');
    final multi = await content(banks: ['Bank', 'Second']);
    final shared = await content();
    _success(await configs.selectCurrent(SelectTrainingContentRequest(
        target:
            TrainingPreferenceTarget(categoryKey: _key, expectedRevision: null),
        contentId: multi.contentId)));
    final prefs = await db.query(trainingCategoryPreferencesTable);
    final settings = await db.query('app_settings');
    await ReviewRepository().clearAllData();
    await expectBinding(multi);
    await expectBinding(shared);
    for (final table in [
      'questions',
      'review_states',
      'review_logs',
      'answer_attempts'
    ]) {
      expect(await db.query(table), isEmpty);
    }
    await ReviewRepository().clearAllData();
    await expectBinding(multi);
    expect(await db.query(trainingCategoryPreferencesTable), prefs);
    expect(await db.query('app_settings'), settings);
    await validateTrainingContentV29Data(db);
  });

  for (final operation in ['single', 'bank', 'clear']) {
    test(
        'exam-referenced $operation deletion preserves all durable data and bindings',
        () async {
      await question('q');
      await content();
      await DatabaseHelper.instance.createExamPaper('Synthetic exam', 0, [
        {'id': 'q'}
      ]);
      await failsAtomically(() => switch (operation) {
            'single' => questions.deleteQuestion('q'),
            'bank' => questions.deleteQuestionBank('Bank'),
            _ => ReviewRepository().clearAllData(),
          });
    });
  }

  for (final operation in [
    'single',
    'bank',
    'folder',
    'move',
    'clear',
    'preview'
  ]) {
    test('invalidation failure rolls back $operation business writes',
        () async {
      await question('q');
      await content();
      await rejectInvalidation();
      await failsAtomically(() => switch (operation) {
            'single' => questions.deleteQuestion('q'),
            'bank' => questions.deleteQuestionBank('Bank'),
            'folder' => questions.updateBankFolder('Bank', 'Moved'),
            'move' =>
              questions.updateQuestion({'id': 'q', 'bank_name': 'Moved'}),
            'preview' => questions.savePreviewQuestion(
                {'id': 'q', 'bank_name': 'Moved', 'content': 'synthetic'}),
            _ => ReviewRepository().clearAllData(),
          });
    });
  }

  test(
      'content revision write failure also rolls original mutation and member status back',
      () async {
    await question('q');
    await content();
    await rejectInvalidation(revision: true);
    await failsAtomically(() => questions.deleteQuestionBank('Bank'));
  });

  test('ordinary Question write failure cannot publish binding invalidation',
      () async {
    await question('q');
    await content();
    await db.execute(
        "CREATE TRIGGER reject_question BEFORE DELETE ON questions BEGIN SELECT RAISE(ABORT, 'synthetic'); END");
    await failsAtomically(() => questions.deleteQuestionBank('Bank'));
  });

  test(
      'preview REPLACE observes final state: same bank stays valid, old bank move-out invalidates',
      () async {
    await question('q');
    final config = await content();
    await questions.savePreviewQuestion(
        {'id': 'q', 'bank_name': 'Bank', 'content': 'replacement'});
    await expectBinding(config,
        revision: 1, status: TrainingBindingStatus.valid, reason: null);
    await questions.savePreviewQuestion(
        {'id': 'q', 'bank_name': 'Moved', 'content': 'replacement'});
    await expectBinding(config);
  });

  test('typed guard rejects legacy bank movement without touching binding',
      () async {
    await question('q');
    await content();
    await db.insert('question_v2_payloads', {
      'question_id': 'q',
      'payload_schema_version': 2,
      'payload_json': '{"synthetic":true}'
    });
    await failsAtomically(
        () => questions.updateQuestion({'id': 'q', 'bank_name': 'Moved'}));
    await failsAtomically(
        () => questions.savePreviewQuestion({'id': 'q', 'bank_name': 'Moved'}));
  });

  test(
      'typed batch folder writer invalidates in its transaction; lifecycle failure rolls entire batch back',
      () async {
    await question('q', folder: 'Math');
    final config = await content(key: FolderCategoryKey('Math'));
    final draft = QuestionDraftV2(
      questionId: 'synthetic',
      kind: QuestionKind.shortAnswer,
      stem: RichContent(nodes: [const TextNode('synthetic')]),
      answer: ContentAnswer(
          content: RichContent(nodes: [const TextNode('synthetic')])),
    );
    await rejectInvalidation();
    await failsAtomically(() => questions.saveQuestionDraftsV2ToBank(
        bankName: 'Bank', folderName: 'English', questions: [draft]));
    await db.execute('DROP TRIGGER synthetic_failure');
    await questions.saveQuestionDraftsV2ToBank(
        bankName: 'Bank', folderName: 'English', questions: [draft]);
    await expectBinding(config,
        reason: TrainingBindingInvalidationReason.categoryChanged);
    expect(await db.query('questions'), hasLength(2));
    expect(await db.query('question_v2_payloads'), hasLength(1));
    await validateTrainingContentV29Data(db);
  });

  test(
      'helper failure forces caller rollback even after invalidation has executed',
      () async {
    await question('q');
    await content();
    await failsAtomically(() => db.transaction((txn) async {
          await txn.delete('questions');
          await invalidateTrainingBindingsAtFinalState(txn,
              affectedBankNames: ['Bank']);
          throw const TrainingBindingLifecycleException();
        }));
  });

  test('file-backed reopen keeps invalidation after same-name bank recreation',
      () async {
    final temp = await Directory.systemTemp.createTemp('binding_reopen_');
    try {
      await DatabaseHelper.resetRuntimeProfileForTesting();
      DatabaseHelper.configureRuntimeProfile(
          DatabaseRuntimeProfile.explicitFile,
          databasePath: temp.path);
      db = await DatabaseHelper.instance.database;
      await question('q');
      final config = await content();
      await questions.deleteQuestionBank('Bank');
      await questions.savePreviewQuestion(
          {'id': 'new-q', 'bank_name': 'Bank', 'content': 'synthetic'});
      await DatabaseHelper.resetRuntimeProfileForTesting();
      DatabaseHelper.configureRuntimeProfile(
          DatabaseRuntimeProfile.explicitFile,
          databasePath: temp.path);
      db = await DatabaseHelper.instance.database;
      await expectBinding(config);
      expect(_success(await configs.current()).state,
          TrainingCurrentContentState.unavailable);
      expect(await db.getVersion(), DatabaseHelper.databaseVersion);
    } finally {
      await DatabaseHelper.resetRuntimeProfileForTesting();
      await temp.delete(recursive: true);
    }
  });
}
