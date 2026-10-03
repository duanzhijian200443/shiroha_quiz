import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/ordinary_training_bank_policy.dart';
import 'package:shiroha_quiz/core/database/training_content_v29_schema.dart';
import 'package:shiroha_quiz/data/repositories/training_configuration_repository.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/domain/training/training_content.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';

const _uncategorized = UncategorizedCategoryKey();
const _codec = CategoryKeyCodec();

T _success<T>(HomeTrainingResult<T> result) {
  expect(result, isA<HomeTrainingSuccess<T>>());
  return (result as HomeTrainingSuccess<T>).value;
}

void _failure<T>(HomeTrainingResult<T> result, HomeTrainingFailure code) {
  expect(result, isA<HomeTrainingFailed<T>>());
  expect((result as HomeTrainingFailed<T>).failure, code);
}

TrainingContentEdit _edit(
        {List<String> banks = const ['Bank'],
        String name = ' Training ',
        int order = 0,
        int limit = 40}) =>
    TrainingContentEdit(
        name: name,
        questionLimit: limit,
        sortOrder: order,
        members: [
          for (var i = 0; i < banks.length; i++)
            TrainingContentMember(
              bankName: banks[i],
              position: i,
              weightPercent: i == 0 ? 100 : 0,
            )
        ]);

TrainingContentTarget _target(TrainingContent content, {int? revision}) =>
    TrainingContentTarget(
        contentId: content.contentId,
        expectedRevision: revision ?? content.revision);

TrainingPreferenceTarget _pref(CategoryKey key, int? revision) =>
    TrainingPreferenceTarget(categoryKey: key, expectedRevision: revision);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory temp;
  late TrainingConfigurationRepository repository;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    temp = await Directory.systemTemp.createTemp('training_config_');
    db = await DatabaseHelper.instance
        .openPathForTesting(p.join(temp.path, 'config.db'));
    repository = TrainingConfigurationRepository(database: () async => db);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await temp.delete(recursive: true);
  });

  Future<void> bank(String name, {String? folder}) async {
    await db.insert('questions', {
      'id': 'q-$name',
      'type': 1,
      'content': 'synthetic',
      'options': '["A"]',
      'standard_answer': 'A',
      'created_at': 1,
      'bank_name': name,
    });
    if (folder != null) {
      await db
          .insert('bank_folders', {'bank_name': name, 'folder_name': folder});
    }
  }

  Future<TrainingContent> create(
          {CategoryKey key = _uncategorized,
          List<String> banks = const ['Bank'],
          String name = 'Training',
          int order = 0}) async =>
      _success(await repository.create(CreateTrainingContentRequest(
          categoryKey: key,
          edit: _edit(banks: banks, name: name, order: order))));

  Future<String> snapshot() async {
    final tables = await db.rawQuery(
        "SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name");
    return jsonEncode({
      'schema': await db.rawQuery(
          'SELECT type, name, sql FROM sqlite_master ORDER BY type, name'),
      for (final table in tables)
        table['name'] as String:
            (await db.rawQuery('SELECT * FROM "${table['name']}"'))
                .map(jsonEncode)
                .toList()
              ..sort(),
    });
  }

  Future<void> unchanged(Future<void> Function() action) async {
    final before = await snapshot();
    await action();
    expect(await snapshot(), before);
  }

  Future<void> invalidate(TrainingContent content) async {
    await db.update(
        trainingContentMembersTable,
        {
          'binding_status': 'invalidated',
          'invalidation_reason': 'bankMissing',
        },
        where: 'content_id = ?',
        whereArgs: [content.contentId]);
  }

  test(
      'catalog keeps exact folders, empty folders and one real-bank eligibility decision; read only',
      () async {
    await bank('Bank', folder: ' 📁 未分类题库 ');
    await bank('bank');
    await bank(globalWrongBookBankName, folder: 'Reserved');
    await bank(hiddenExamBankName);
    await bank('🔥 用户普通库', folder: 'Math');
    await db.execute('CREATE TABLE custom_folders (name TEXT PRIMARY KEY)');
    await db.insert('custom_folders', {'name': 'Empty'});
    await db
        .insert('bank_folders', {'bank_name': 'Gone', 'folder_name': 'Ghost'});
    await unchanged(() async {
      final catalog = _success(await repository.capture());
      expect(catalog.categories, [
        FolderCategoryKey(' 📁 未分类题库 '),
        FolderCategoryKey('Empty'),
        FolderCategoryKey('Math'),
        FolderCategoryKey('Reserved'),
        _uncategorized
      ]);
      final banks = {for (final value in catalog.banks) value.bankName: value};
      expect(
          banks.keys,
          unorderedEquals([
            'Bank',
            'bank',
            globalWrongBookBankName,
            hiddenExamBankName,
            '🔥 用户普通库'
          ]));
      expect(banks['Bank']!.categoryKey, FolderCategoryKey(' 📁 未分类题库 '));
      expect(banks['bank']!.categoryKey, _uncategorized);
      expect(banks['Bank']!.ordinaryTrainingEligible, isTrue);
      expect(banks['🔥 用户普通库']!.ordinaryTrainingEligible, isTrue);
      expect(banks[globalWrongBookBankName]!.ordinaryTrainingEligible, isFalse);
      expect(banks[hiddenExamBankName]!.ordinaryTrainingEligible, isFalse);
    });
    expect(await db.query('review_states'), isEmpty);
    expect(
        (await db.query('questions')).every((row) => row['type'] == 1), isTrue);
  });

  test(
      'fresh DB catalog tolerates absent legacy custom-folder table without creating it',
      () async {
    await unchanged(() async {
      expect(_success(await repository.capture()).categories, isEmpty);
      expect(_success(await repository.current()).state,
          TrainingCurrentContentState.unconfigured);
    });
  });

  test('eligibility adapter is read-only and missing bank is ineligible',
      () async {
    await bank('Bank');
    await unchanged(() async {
      final adapter = DatabaseOrdinaryTrainingBankEligibility(db);
      expect(
          _success(await adapter.evaluate(OrdinaryTrainingBankInput('Bank'))),
          OrdinaryTrainingBankEligibilityStatus.eligible);
      expect(
          _success(
              await adapter.evaluate(OrdinaryTrainingBankInput('Missing'))),
          OrdinaryTrainingBankEligibilityStatus.ineligible);
    });
  });

  test(
      'create single and multi-bank persists ordered members with revision 1 and no selection',
      () async {
    await bank('Bank', folder: 'Exact');
    await bank('Second', folder: 'Exact');
    final key = FolderCategoryKey('Exact');
    final first = await create(key: key);
    final second = await create(key: key, banks: ['Bank', 'Second']);
    expect(first.revision, 1);
    expect(second.revision, 1);
    expect(first.contentId, isNot(second.contentId));
    expect(second.members.map((m) => m.weightPercent), [100, 0]);
    expect(_success(await repository.getById(second.contentId)).content.members,
        second.members);
    expect(await db.query(trainingContentMembersTable), hasLength(3));
    expect(await db.query(trainingCategoryPreferencesTable), isEmpty);
    expect(await db.query('app_settings'), isEmpty);
    expect(await db.query('review_states'), isEmpty);
    await validateTrainingContentV29Data(db);
  });

  for (final invalid in [
    'missing',
    'reserved',
    'other category',
    'case differs'
  ]) {
    test('create rejects $invalid bank with zero mutation', () async {
      await bank('Bank');
      String name = 'Missing';
      if (invalid == 'reserved') {
        name = globalWrongBookBankName;
        await bank(name);
      } else if (invalid == 'other category') {
        name = 'Other';
        await bank(name, folder: 'Elsewhere');
      } else if (invalid == 'case differs') {
        name = 'bank';
      }
      await unchanged(() async {
        _failure(
            await repository.create(CreateTrainingContentRequest(
                categoryKey: _uncategorized,
                edit: _edit(banks: ['Bank', name]))),
            HomeTrainingFailure.invalidInput);
      });
    });
  }

  test('parent and members rollback on a member insertion failure', () async {
    await bank('Bank');
    await db.execute(
        "CREATE TRIGGER reject_member BEFORE INSERT ON training_content_members BEGIN SELECT RAISE(ABORT, 'synthetic'); END");
    await unchanged(() async {
      _failure(
          await repository.create(CreateTrainingContentRequest(
              categoryKey: _uncategorized, edit: _edit())),
          HomeTrainingFailure.unavailable);
    });
  });

  test(
      'update exact CAS replaces all members atomically and preserves Category/preference revision',
      () async {
    await bank('Bank');
    await bank('Second');
    final old = await create();
    _success(await repository.updateCategoryVisual(UpdateCategoryVisualRequest(
        target: _pref(_uncategorized, null),
        visualKey: CategoryVisualKey.math)));
    final updated = _success(await repository.update(
        UpdateTrainingContentRequest(
            target: _target(old),
            edit: _edit(
                banks: ['Second'], name: ' Changed ', order: -2, limit: 1))));
    expect(updated.name, 'Changed');
    expect(updated.questionLimit, 1);
    expect(updated.sortOrder, -2);
    expect(updated.categoryKey, old.categoryKey);
    expect(updated.revision, 2);
    expect(updated.members.single.bankName, 'Second');
    final rows = await db.query(trainingContentMembersTable);
    expect(rows, hasLength(1));
    expect(rows.single['bank_name'], 'Second');
    expect(
        _success(await repository.listByCategory(_uncategorized))
            .preference
            .revision,
        1);
    await validateTrainingContentV29Data(db);
  });

  test('stale update and delete return stale with zero mutation', () async {
    await bank('Bank');
    final content = await create();
    await unchanged(() async {
      _failure(
          await repository.update(UpdateTrainingContentRequest(
              target: _target(content, revision: 2),
              edit: _edit(name: 'Changed'))),
          HomeTrainingFailure.stale);
      _failure(await repository.delete(_target(content, revision: 2)),
          HomeTrainingFailure.stale);
    });
  });

  test('two competing updates on one revision commit once, never retry',
      () async {
    await bank('Bank');
    final content = await create();
    final results = await Future.wait([
      for (var i = 0; i < 2; i++)
        repository.update(UpdateTrainingContentRequest(
            target: _target(content), edit: _edit(name: 'Edit $i')))
    ]);
    expect(results.whereType<HomeTrainingSuccess<TrainingContent>>(),
        hasLength(1));
    expect(
        results.whereType<HomeTrainingFailed<TrainingContent>>().single.failure,
        HomeTrainingFailure.stale);
    expect(
        _success(await repository.getById(content.contentId)).content.revision,
        2);
  });

  test('missing targets return notFound', () async {
    final target =
        TrainingContentTarget(contentId: 'missing', expectedRevision: 1);
    _failure(await repository.getById('missing'), HomeTrainingFailure.notFound);
    _failure(
        await repository.update(
            UpdateTrainingContentRequest(target: target, edit: _edit())),
        HomeTrainingFailure.notFound);
    _failure(await repository.delete(target), HomeTrainingFailure.notFound);
  });

  test(
      'update rejects cross-category/missing members and cannot migrate Category',
      () async {
    await bank('Bank');
    await bank('Other', folder: 'Other');
    final content = await create();
    for (final name in ['Other', 'Missing']) {
      await unchanged(() async {
        _failure(
            await repository.update(UpdateTrainingContentRequest(
                target: _target(content), edit: _edit(banks: [name]))),
            HomeTrainingFailure.invalidInput);
      });
    }
    expect(
        _success(await repository.getById(content.contentId))
            .content
            .categoryKey,
        _uncategorized);
  });

  test('failed replacement rolls parent and removed member rows back',
      () async {
    await bank('Bank');
    await bank('Second');
    final content = await create();
    await db.execute(
        "CREATE TRIGGER reject_replacement BEFORE INSERT ON training_content_members WHEN NEW.bank_name = 'Second' BEGIN SELECT RAISE(ABORT, 'synthetic'); END");
    await unchanged(() async {
      _failure(
          await repository.update(UpdateTrainingContentRequest(
              target: _target(content),
              edit: _edit(banks: ['Second'], name: 'Changed'))),
          HomeTrainingFailure.unavailable);
    });
  });

  test('ordinary update cannot rebind an invalidated member', () async {
    await bank('Bank');
    final content = await create();
    await invalidate(content);
    await unchanged(() async {
      _failure(
          await repository.update(UpdateTrainingContentRequest(
              target: _target(content), edit: _edit())),
          HomeTrainingFailure.conflict);
    });
  });

  test(
      'delete removes config only, clears referenced preference with independent revision and never saves fallback',
      () async {
    await bank('Bank');
    final a = await create(name: 'A', order: 0);
    final b = await create(name: 'B', order: 1);
    await db.insert('review_states', {'question_id': 'q-Bank', 'state': 0});
    await db.insert('review_logs', {
      'id': 'log',
      'question_id': 'q-Bank',
      'grade': 3,
      'review_time': 1,
      'duration_ms': 1
    });
    await db.insert('answer_attempts', {
      'attempt_id': 'attempt',
      'question_id': 'q-Bank',
      'session_kind': 'normal',
      'modality': 'text',
      'answer_payload_json': '{"synthetic":true}',
      'answered_at': 1,
    });
    final questions = await db.query('questions');
    final states = await db.query('review_states');
    final logs = await db.query('review_logs');
    final attempts = await db.query('answer_attempts');
    _success(await repository.selectCurrent(SelectTrainingContentRequest(
        target: _pref(_uncategorized, null), contentId: a.contentId)));
    _success(await repository.delete(_target(a)));
    expect(await db.query('questions'), questions);
    expect(await db.query('review_states'), states);
    expect(await db.query('review_logs'), logs);
    expect(await db.query('answer_attempts'), attempts);
    expect(await db.query(trainingContentMembersTable), hasLength(1));
    final pref = (await db.query(trainingCategoryPreferencesTable)).single;
    expect(pref['current_content_id'], isNull);
    expect(pref['revision'], 2);
    await unchanged(() async {
      final current = _success(await repository.current());
      expect(current.currentContent!.content.contentId, b.contentId);
      expect(current.preference!.currentContentId, isNull);
    });
    await validateTrainingContentV29Data(db);
  });

  test('delete non-current content does not advance preference', () async {
    await bank('Bank');
    final a = await create();
    final b = await create();
    _success(await repository.selectCurrent(SelectTrainingContentRequest(
        target: _pref(_uncategorized, null), contentId: a.contentId)));
    _success(await repository.delete(_target(b)));
    final pref =
        _success(await repository.listByCategory(_uncategorized)).preference;
    expect(pref.revision, 1);
    expect(pref.currentContentId, a.contentId);
  });

  test('delete rolls removal back when preference cleanup fails', () async {
    await bank('Bank');
    final content = await create();
    _success(await repository.selectCurrent(SelectTrainingContentRequest(
        target: _pref(_uncategorized, null), contentId: content.contentId)));
    await db.execute(
        "CREATE TRIGGER reject_cleanup BEFORE UPDATE ON training_category_preferences BEGIN SELECT RAISE(ABORT, 'synthetic'); END");
    await unchanged(() async {
      _failure(await repository.delete(_target(content)),
          HomeTrainingFailure.unavailable);
    });
  });

  test(
      'visual absent/exact CAS preserves content revision, current selection and global setting',
      () async {
    await bank('Bank');
    final content = await create();
    final visual = _success(await repository.updateCategoryVisual(
        UpdateCategoryVisualRequest(
            target: _pref(_uncategorized, null),
            visualKey: CategoryVisualKey.english)));
    expect(visual.revision, 1);
    expect(visual.currentContentId, isNull);
    expect(await db.query('app_settings'), isEmpty);
    _success(await repository.selectCurrent(SelectTrainingContentRequest(
        target: _pref(_uncategorized, 1), contentId: content.contentId)));
    final setting = await db.query('app_settings');
    final next = _success(await repository.updateCategoryVisual(
        UpdateCategoryVisualRequest(
            target: _pref(_uncategorized, 2),
            visualKey: CategoryVisualKey.math)));
    expect(next.revision, 3);
    expect(next.currentContentId, content.contentId);
    expect(next.visualKey, CategoryVisualKey.math);
    expect(await db.query('app_settings'), setting);
    expect(
        _success(await repository.getById(content.contentId)).content.revision,
        1);
  });

  for (final revision in <int?>[null, 2]) {
    test(
        'existing preference with expected $revision is stale for selection and visual; zero mutation',
        () async {
      await bank('Bank');
      final content = await create();
      _success(await repository.selectCurrent(SelectTrainingContentRequest(
          target: _pref(_uncategorized, null), contentId: content.contentId)));
      await unchanged(() async {
        _failure(
            await repository.selectCurrent(SelectTrainingContentRequest(
                target: _pref(_uncategorized, revision), contentId: null)),
            HomeTrainingFailure.stale);
        _failure(
            await repository.updateCategoryVisual(UpdateCategoryVisualRequest(
                target: _pref(_uncategorized, revision),
                visualKey: CategoryVisualKey.math)),
            HomeTrainingFailure.stale);
      });
    });
  }

  test('absent preference with non-null expected revision is stale', () async {
    await unchanged(() async {
      _failure(
          await repository.selectCurrent(SelectTrainingContentRequest(
              target: _pref(_uncategorized, 1), contentId: null)),
          HomeTrainingFailure.stale);
      _failure(
          await repository.updateCategoryVisual(UpdateCategoryVisualRequest(
              target: _pref(_uncategorized, 1),
              visualKey: CategoryVisualKey.math)),
          HomeTrainingFailure.stale);
    });
  });

  test(
      'selection atomically stores global Category and advances separate preference CAS',
      () async {
    await bank('Bank', folder: 'Folder');
    final key = FolderCategoryKey('Folder');
    final content = await create(key: key);
    final selected = _success(await repository.selectCurrent(
        SelectTrainingContentRequest(
            target: _pref(key, null), contentId: content.contentId)));
    expect(selected.persistedCategoryKey, key);
    expect(selected.categoryKey, key);
    expect(selected.preference!.revision, 1);
    expect(selected.currentContent!.content.contentId, content.contentId);
    expect((await db.query('app_settings')).single['value'],
        _codec.encodeString(key));
    final cleared = _success(await repository.selectCurrent(
        SelectTrainingContentRequest(target: _pref(key, 1), contentId: null)));
    expect(cleared.preference!.revision, 2);
    expect(cleared.preference!.currentContentId, isNull);
    expect(cleared.currentContent!.content.contentId, content.contentId);
  });

  test('selection missing or cross-category reference fails with zero mutation',
      () async {
    await bank('Bank', folder: 'Other');
    final content = await create(key: FolderCategoryKey('Other'));
    await unchanged(() async {
      _failure(
          await repository.selectCurrent(SelectTrainingContentRequest(
              target: _pref(_uncategorized, null),
              contentId: content.contentId)),
          HomeTrainingFailure.invalidInput);
      _failure(
          await repository.selectCurrent(SelectTrainingContentRequest(
              target: _pref(_uncategorized, null), contentId: 'missing')),
          HomeTrainingFailure.notFound);
    });
  });

  test(
      'global setting failure rolls selection preference back and returns safe failure',
      () async {
    await bank('Bank');
    final content = await create();
    await db.execute(
        "CREATE TRIGGER reject_current BEFORE INSERT ON app_settings BEGIN SELECT RAISE(ABORT, 'synthetic'); END");
    await unchanged(() async {
      _failure(
          await repository.selectCurrent(SelectTrainingContentRequest(
              target: _pref(_uncategorized, null),
              contentId: content.contentId)),
          HomeTrainingFailure.unavailable);
    });
  });

  test('persisted usable current overrides stable fallback order', () async {
    await bank('Bank');
    await create(name: 'A', order: -1);
    final b = await create(name: 'B', order: 3);
    _success(await repository.selectCurrent(SelectTrainingContentRequest(
        target: _pref(_uncategorized, null), contentId: b.contentId)));
    await unchanged(() async {
      expect(
          _success(await repository.current())
              .currentContent!
              .content
              .contentId,
          b.contentId);
    });
  });

  test(
      'unavailable persisted A remains structurally valid; runtime B never writes back',
      () async {
    await bank('Bank');
    final a = await create(name: 'A');
    final b = await create(name: 'B', order: 2);
    await invalidate(a);
    final selected = _success(await repository.selectCurrent(
        SelectTrainingContentRequest(
            target: _pref(_uncategorized, null), contentId: a.contentId)));
    expect(selected.currentContent!.content.contentId, b.contentId);
    expect(selected.preference!.currentContentId, a.contentId);
    await unchanged(() async {
      final current = _success(await repository.current());
      expect(current.state, TrainingCurrentContentState.usable);
      expect(current.currentContent!.content.contentId, b.contentId);
      expect(current.preference!.currentContentId, a.contentId);
      expect(_success(await repository.getById(a.contentId)).usable, isFalse);
    });
    await validateTrainingContentV29Data(db);
  });

  test(
      'no configs is unconfigured; configs with no usable member is unavailable',
      () async {
    await bank('Bank');
    expect(_success(await repository.current()).state,
        TrainingCurrentContentState.unconfigured);
    final content = await create();
    await invalidate(content);
    await unchanged(() async {
      final current = _success(await repository.current());
      expect(current.state, TrainingCurrentContentState.unavailable);
      expect(current.categoryKey, _uncategorized);
      expect(current.currentContent, isNull);
    });
  });

  test(
      'Category fallback uses folders in deterministic order, excludes empty folders and puts Uncategorized last',
      () async {
    await bank('Z', folder: 'Z');
    await bank('a', folder: 'a');
    await bank('Unmapped');
    await db.execute('CREATE TABLE custom_folders (name TEXT PRIMARY KEY)');
    await db.insert('custom_folders', {'name': 'A empty'});
    final absent = FolderCategoryKey('Gone');
    _success(await repository.selectCurrent(SelectTrainingContentRequest(
        target: _pref(absent, null), contentId: null)));
    await unchanged(() async {
      final current = _success(await repository.current());
      expect(current.persistedCategoryKey, absent);
      expect(current.categoryKey, FolderCategoryKey('Z'));
    });
    await db.delete('questions', where: 'bank_name = ?', whereArgs: ['Z']);
    expect(_success(await repository.current()).categoryKey,
        FolderCategoryKey('a'));
    await db.delete('questions', where: 'bank_name = ?', whereArgs: ['a']);
    expect(_success(await repository.current()).categoryKey, _uncategorized);
    expect((await db.query('app_settings')).single['value'],
        _codec.encodeString(absent));
  });

  test('content-only Category remains visible after its real bank disappears',
      () async {
    await bank('Bank', folder: 'A');
    await create(key: FolderCategoryKey('A'));
    await db.delete('questions');
    await unchanged(() async {
      final current = _success(await repository.current());
      expect(current.categoryKey, FolderCategoryKey('A'));
      expect(current.state, TrainingCurrentContentState.unavailable);
    });
  });

  for (final drift in ['disappears', 'moves', 'ineligible']) {
    test(
        'valid binding whose bank $drift is unusable without persistent invalidation',
        () async {
      final name = drift == 'ineligible' ? globalWrongBookBankName : 'Bank';
      await bank('Bank');
      final content = await create();
      if (drift == 'disappears') {
        await db.delete('questions');
      } else if (drift == 'moves') {
        await db.insert(
            'bank_folders', {'bank_name': name, 'folder_name': 'Moved'});
      } else {
        await bank(name);
        // Synthetic structurally valid persisted relation to prove the same
        // eligibility authority is consulted at query time too.
        await db.update(trainingContentMembersTable, {'bank_name': name},
            where: 'content_id = ?', whereArgs: [content.contentId]);
      }
      await unchanged(() async {
        final view = _success(await repository.getById(content.contentId));
        expect(view.usable, isFalse);
        expect(view.content.members.single.bindingStatus,
            TrainingBindingStatus.valid);
        expect(view.content.revision, 1);
        expect(
            _success(await repository.listByCategory(_uncategorized))
                .contents
                .single
                .usable,
            isFalse);
      });
    });
  }

  test('list sorting and current fallback use sortOrder then opaque contentId',
      () async {
    await bank('Bank');
    final a = await create(order: 2);
    final b = await create(order: 2);
    final c = await create(order: -1);
    final tie = [a.contentId, b.contentId]..sort();
    await unchanged(() async {
      expect(
          _success(await repository.listByCategory(_uncategorized))
              .contents
              .map((view) => view.content.contentId),
          [c.contentId, ...tie]);
      expect(
          _success(await repository.current())
              .currentContent!
              .content
              .contentId,
          c.contentId);
    });
    _success(await repository.delete(_target(c)));
    expect(
        _success(await repository.current()).currentContent!.content.contentId,
        tie.first);
  });

  test(
      'malformed global Category, dangling preference and malformed member are unavailable without repair',
      () async {
    await bank('Bank');
    final content = await create();
    await db.insert('app_settings',
        {'key': currentTrainingCategorySetting, 'value': 'invalid'});
    await unchanged(() async {
      _failure(await repository.current(), HomeTrainingFailure.unavailable);
    });
    await db.delete('app_settings');
    await db.insert(trainingCategoryPreferencesTable, {
      'category_key': _codec.encodeString(_uncategorized),
      'revision': 1,
      'current_content_id': 'missing'
    });
    await unchanged(() async {
      _failure(await repository.listByCategory(_uncategorized),
          HomeTrainingFailure.unavailable);
    });
    await db.delete(trainingCategoryPreferencesTable);
    await db.update(trainingContentMembersTable, {'weight_percent': 99});
    await unchanged(() async {
      _failure(await repository.getById(content.contentId),
          HomeTrainingFailure.unavailable);
    });
  });

  test('database open failure returns fixed unavailable on query and mutation',
      () async {
    final failed = TrainingConfigurationRepository(
        database: () async => throw StateError('synthetic'));
    _failure(await failed.capture(), HomeTrainingFailure.unavailable);
    _failure(await failed.current(), HomeTrainingFailure.unavailable);
    _failure(
        await failed.create(CreateTrainingContentRequest(
            categoryKey: _uncategorized, edit: _edit())),
        HomeTrainingFailure.unavailable);
  });

  test(
      'dangling preference outside the visible catalog fails current without mutation',
      () async {
    await bank('Bank');
    await db.insert(trainingCategoryPreferencesTable, {
      'category_key': _codec.encodeString(FolderCategoryKey('Gone')),
      'revision': 1,
      'current_content_id': 'missing',
    });
    await unchanged(() async {
      _failure(await repository.current(), HomeTrainingFailure.unavailable);
    });
  });

  test(
      'failure projecting post-selection context rolls back both persisted references',
      () async {
    await bank('Bank');
    final selected = await create();
    final corrupt = await create();
    await db.update(trainingContentMembersTable, {'weight_percent': 99},
        where: 'content_id = ?', whereArgs: [corrupt.contentId]);
    await unchanged(() async {
      _failure(
          await repository.selectCurrent(SelectTrainingContentRequest(
              target: _pref(_uncategorized, null),
              contentId: selected.contentId)),
          HomeTrainingFailure.unavailable);
    });
  });

  test('competing absent-row preference selections commit once', () async {
    await bank('Bank');
    final content = await create();
    final results = await Future.wait([
      for (var i = 0; i < 2; i++)
        repository.selectCurrent(SelectTrainingContentRequest(
            target: _pref(_uncategorized, null), contentId: content.contentId))
    ]);
    expect(results.whereType<HomeTrainingSuccess<TrainingCurrentSelection>>(),
        hasLength(1));
    expect(
        results
            .whereType<HomeTrainingFailed<TrainingCurrentSelection>>()
            .single
            .failure,
        HomeTrainingFailure.stale);
    expect(_success(await repository.current()).preference!.revision, 1);
  });
}
