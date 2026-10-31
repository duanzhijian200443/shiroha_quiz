import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/data/repositories/external_question_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_study_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_target_read_repository.dart';
import 'external_question_read_test_support.dart';
import '../study_query/study_query_test_support.dart'
    show insertReviewState, insertReviewLog, corruptSidecar;

void main() {
  initializeGeneratedTests();
  late QuestionReadHarness h;
  late ExternalReadContextService read;
  late List<ExternalGrantScope> scopes;
  Future<void> grant(
      {bool statistics = true, bool content = true, bool empty = false}) async {
    final revision =
        (await h.s.management.read(h.s.profile)).profile.grantRevision;
    await h.s.management.replaceGrant(
        h.s.profile,
        revision,
        h.s.policy(
            permissions: [CapabilityPermission.read],
            scopes: empty ? [] : scopes,
            categories: [
              if (content) ExternalContentCategory.questionContent,
              if (statistics) ExternalContentCategory.studyStatistics,
            ]));
  }

  void compose({Future<void> Function()? afterQuery, String timezone = 'UTC'}) {
    read = ExternalReadContextService(
        admission: h.s.service.runtimeAdmission,
        studyTimeZone: timezone,
        targets:
            SqliteExternalTargetReadRepository(databaseHelper: h.s.h.helper),
        questions:
            SqliteExternalQuestionReadRepository(databaseHelper: h.s.h.helper),
        study: SqliteExternalStudyReadRepository(
            databaseHelper: h.s.h.helper, afterQuery: afterQuery));
  }

  setUp(() async {
    h = QuestionReadHarness();
    h.s.clock.current = DateTime.utc(2026, 8, 8, 17);
    await h.open();
    final db = h.s.h.db;
    for (final name in ['second', 'private']) {
      await db
          .insert('bank_folders', {'bank_name': name, 'folder_name': 'folder'});
    }
    await db.insert('projects',
        {'project_id': 'space', 'display_name': 'Space', 'created_at': 0});
    await db
        .insert('project_banks', {'project_id': 'space', 'bank_name': 'bank'});
    scopes = [
      h.s.bank,
      ExternalGrantScope(
          kind: ExternalTargetKind.bank, targetId: 'bank', projectId: 'space'),
      ExternalGrantScope(kind: ExternalTargetKind.bank, targetId: 'second'),
    ];
    await grant();
    await h.legacy('a');
    await h.typed(id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', bank: 'second');
    await h.typed(id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', bank: 'private');
    await corruptSidecar(db, storageId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc');
    final now = h.s.clock.current.millisecondsSinceEpoch ~/ 1000;
    await insertReviewState(db,
        questionId: 'a',
        state: 3,
        nextReviewTime: now - 1,
        lapses: 2,
        difficulty: 7,
        lastLapseTime: 200);
    await insertReviewState(db,
        questionId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        state: 1,
        nextReviewTime: now + 3600,
        lapses: 1,
        difficulty: 2,
        lastLapseTime: 100);
    await insertReviewState(db,
        questionId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        state: 3,
        nextReviewTime: now - 1,
        lapses: 9,
        lastLapseTime: 999);
    await insertReviewLog(db, questionId: 'a', reviewTime: now - 1800);
    await insertReviewLog(db, questionId: 'a', reviewTime: now - 1700);
    await insertReviewLog(db,
        questionId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        reviewTime: now - 7200);
    compose();
  });
  tearDown(() async {
    read.close();
    await read.whenIdle;
    await h.close();
  });
  Future<String> context() => read.openStudyContext(session: h.s.session);

  test(
      'omitted timezone uses target configuration and DST buckets stay half-open',
      () async {
    read.close();
    compose(timezone: 'Asia/Shanghai');
    final ref = await context();
    expect(
        (await read.studyOverview(session: h.s.session, context: ref))
            .toJson()['todayPracticeCount'],
        1);
    expect(
        (await read.studyOverview(
                session: h.s.session, context: ref, timezone: 'UTC'))
            .toJson()['todayPracticeCount'],
        2);
    final from = DateTime.utc(2026, 3, 8, 5), to = DateTime.utc(2026, 3, 9, 4);
    await h.s.h.db.update('review_states',
        {'next_review_time': from.millisecondsSinceEpoch ~/ 1000},
        where: 'question_id=?', whereArgs: ['a']);
    await h.s.h.db.update('review_states',
        {'next_review_time': to.millisecondsSinceEpoch ~/ 1000},
        where: 'question_id=?',
        whereArgs: ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb']);
    final actual = (await read.studyDueSummary(
            session: h.s.session,
            context: ref,
            from: from,
            to: to,
            timezone: 'America/New_York'))
        .toJson();
    expect(actual['scheduledCount'], 1);
    expect(actual['buckets'], [
      {'date': '2026-03-08', 'count': 1}
    ]);
    await expectLater(
        read.studyOverview(
            session: h.s.session, context: ref, timezone: 'Unknown/Zone'),
        throwsA(isA<ExternalReadException>().having((e) => e.failure,
            'invalid zone', ExternalReadFailure.invalidRequest)));
  });

  test('explicit allContent includes current banks, with bounded discovery',
      () async {
    final revision =
        (await h.s.management.read(h.s.profile)).profile.grantRevision;
    await h.s.management.replaceGrant(
        h.s.profile,
        revision,
        ExternalGrantPolicy(
            permissions: [CapabilityPermission.read],
            scopes: [],
            allContent: true,
            categories: [ExternalContentCategory.studyStatistics]));
    final ref = await context();
    expect(
        (await read.studyOverview(session: h.s.session, context: ref))
            .toJson()['questionCount'],
        3);
    for (var i = 0; i < 129; i++) {
      await h.s.h.db.insert(
          'bank_folders', {'bank_name': 'bounded-$i', 'folder_name': 'folder'});
    }
    await expectLater(
        context(),
        throwsA(isA<ExternalReadException>().having((e) => e.failure,
            'fixed budget error', ExternalReadFailure.resourceLimit)));
  });

  test('same-data T0 metrics agree for each authorized bank', () async {
    final repo = ReviewRepository(databaseHelper: h.s.h.helper);
    final now = h.s.clock.current.millisecondsSinceEpoch ~/ 1000;
    final ref = await context();
    final banks =
        (await read.listStudyBanks(session: h.s.session, context: ref))
            .toJson();
    for (final bank in banks['items'] as List) {
      final single = await read.openStudyContext(
          session: h.s.session, targetRef: bank['targetRef']);
      final actual =
          (await read.studyOverview(session: h.s.session, context: single))
              .toJson();
      final expected = await repo.getStudyOverviewCounts(
          bankName: bank['bankName'],
          nowUnixSeconds: now,
          todayStartUnixSeconds:
              DateTime.utc(2026, 8, 8).millisecondsSinceEpoch ~/ 1000);
      expect(actual, {
        'questionCount': expected.questionCount,
        'masteredCount': expected.masteredCount,
        'dueCount': expected.dueCount,
        'todayPracticeCount': expected.todayPracticeCount,
        'wrongQuestionCount': expected.wrongQuestionCount
      });
    }
  });

  test('scheduled keyset pages count equal timestamps without truncation',
      () async {
    final now = h.s.clock.current.millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < 260; i++) {
      await h.legacy('page-$i');
      await insertReviewState(h.s.h.db,
          questionId: 'page-$i', state: 1, nextReviewTime: now);
    }
    final ref = await context();
    final actual = (await read.studyDueSummary(
            session: h.s.session,
            context: ref,
            from: h.s.clock.current,
            to: h.s.clock.current.add(const Duration(seconds: 1))))
        .toJson();
    expect(actual['scheduledCount'], 260);
    expect((actual['buckets'] as List).single['count'], 260);
    final excluded = (await read.studyDueSummary(
            session: h.s.session,
            context: ref,
            from: h.s.clock.current.subtract(const Duration(seconds: 1)),
            to: h.s.clock.current))
        .toJson();
    expect(excluded['scheduledCount'], 1);
  });

  test('fractional window edges preserve the exact half-open interval',
      () async {
    final start = h.s.clock.current;
    await h.s.h.db.update('review_states',
        {'next_review_time': start.millisecondsSinceEpoch ~/ 1000},
        where: 'question_id=?', whereArgs: ['a']);
    await h.s.h.db.update('review_states',
        {'next_review_time': start.millisecondsSinceEpoch ~/ 1000 + 1},
        where: 'question_id=?',
        whereArgs: ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb']);
    final ref = await context();
    final actual = (await read.studyDueSummary(
            session: h.s.session,
            context: ref,
            from: start.add(const Duration(milliseconds: 500)),
            to: start.add(const Duration(milliseconds: 1500))))
        .toJson();
    expect(actual['scheduledCount'], 1);
    final none = (await read.studyDueSummary(
            session: h.s.session,
            context: ref,
            from: start.add(const Duration(milliseconds: 500)),
            to: start.add(const Duration(seconds: 1))))
        .toJson();
    expect(none['scheduledCount'], 0);
  });

  test('null and zero lapse history retain T0 unknown-history semantics',
      () async {
    await h.s.h.db.update('review_states', {'last_lapse_time': null},
        where: 'question_id=?', whereArgs: ['a']);
    await h.s.h.db.update('review_states', {'last_lapse_time': 0},
        where: 'question_id=?',
        whereArgs: ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb']);
    final ref = await context();
    final first = (await read.studyWeakQuestions(
            session: h.s.session, context: ref, pageSize: 1))
        .toJson();
    expect((first['items'] as List).single['lastLapseAt'], isNull);
    final second = (await read.studyWeakQuestions(
            session: h.s.session,
            context: ref,
            pageSize: 1,
            cursor: first['nextCursor'] as String))
        .toJson();
    expect((second['items'] as List).single['lastLapseAt'], isNull);
    expect(second['nextCursor'], isNull);
  });

  for (final mutation in ['content', 'scope', 'revoke', 'delete', 'move']) {
    test('held statistics/weak output is refused after $mutation', () async {
      final ref = await context();
      final held =
          await read.studyWeakQuestions(session: h.s.session, context: ref);
      switch (mutation) {
        case 'content':
          await h.s.h.db.update('questions', {'content': 'changed'},
              where: 'id=?', whereArgs: ['a']);
        case 'scope':
          await grant(empty: true);
        case 'revoke':
          await grant(statistics: false);
        case 'delete':
          await h.s.h.db.delete('questions', where: 'id=?', whereArgs: ['a']);
        case 'move':
          await h.s.h.db.update('questions', {'bank_name': 'private'},
              where: 'id=?', whereArgs: ['a']);
      }
      await expectLater(
          held.release(h.s.session, ref, ExternalCallControl(clock: h.s.clock)),
          throwsA(isA<ExternalReadException>()));
    });
  }

  test('held aggregate cannot release after learning data changes', () async {
    final ref = await context();
    final held = await read.studyOverview(session: h.s.session, context: ref);
    await h.s.h.db.update('review_states', {'state': 0},
        where: 'question_id=?', whereArgs: ['a']);
    await expectLater(
        held.release(h.s.session, ref, ExternalCallControl(clock: h.s.clock)),
        throwsA(isA<ExternalReadException>()));
  });

  test('cancelled query retains its original slot until SQLite work settles',
      () async {
    final entered = Completer<void>(), finish = Completer<void>();
    read.close();
    compose(afterQuery: () async {
      entered.complete();
      await finish.future;
    });
    final ref = await context();
    final control = ExternalCallControl(clock: h.s.clock);
    final pending = read.studyOverview(
        session: h.s.session, context: ref, control: control);
    final refused = expectLater(pending, throwsA(isA<ExternalReadException>()));
    await entered.future;
    control.cancel();
    await refused;
    expect(read.pendingCount, 1);
    var settled = false;
    final drain = read.whenIdle.then((_) => settled = true);
    await Future<void>.delayed(Duration.zero);
    expect(settled, false);
    finish.complete();
    await drain;
    expect(read.pendingCount, 0);
  });

  Future<Map<String, Object?>> readOverview(
          {required ExternalSession session,
          required String context,
          String timezone = 'UTC'}) async =>
      (await read.studyOverview(
              session: session, context: context, timezone: timezone))
          .toJson();
  Future<Map<String, Object?>> dueSummary(
          {required ExternalSession session,
          required String context,
          required DateTime from,
          required DateTime to,
          String timezone = 'UTC'}) async =>
      (await read.studyDueSummary(
              session: session,
              context: context,
              from: from,
              to: to,
              timezone: timezone))
          .toJson();
  Future<Map<String, Object?>> banksPage(
          {required ExternalSession session, required String context}) async =>
      (await read.listStudyBanks(session: session, context: context)).toJson();
  Future<Map<String, Object?>> weakPage(
          {required ExternalSession session,
          required String context,
          int pageSize = 20,
          String? cursor}) async =>
      (await read.studyWeakQuestions(
              session: session,
              context: context,
              pageSize: pageSize,
              cursor: cursor))
          .toJson();

  test(
      'authorized aggregate deduplicates overlapping grants and keeps T0 counts',
      () async {
    final ref = await context();
    expect(
        await readOverview(
            session: h.s.session, context: ref, timezone: 'Asia/Shanghai'),
        {
          'questionCount': 2,
          'masteredCount': 1,
          'dueCount': 1,
          'todayPracticeCount': 1,
          'wrongQuestionCount': 2,
        });
    final banks = await banksPage(session: h.s.session, context: ref);
    expect((banks['items'] as List).length, 2);
    final target = (banks['items'] as List).first as Map;
    final one = await read.openStudyContext(
        session: h.s.session, targetRef: target['targetRef'] as String);
    final overview = await readOverview(session: h.s.session, context: one);
    expect(overview['questionCount'], 1);
  });

  test('due buckets use original half-open window and requested local timezone',
      () async {
    final ref = await context();
    expect(
        await dueSummary(
            session: h.s.session,
            context: ref,
            timezone: 'Asia/Shanghai',
            from: DateTime.utc(2026, 8, 8, 16),
            to: DateTime.utc(2026, 8, 9, 16)),
        {
          'dueNow': 1,
          'scheduledCount': 2,
          'buckets': [
            {'date': '2026-08-09', 'count': 2}
          ],
        });
  });

  test('weak cursor order and opaque references work for aggregate details',
      () async {
    final ref = await context();
    final first =
        await weakPage(session: h.s.session, context: ref, pageSize: 1);
    final item = (first['items'] as List).single as Map;
    expect(item['bankName'], 'bank');
    expect(item['lapseCount'], 2);
    expect(item['questionRef'], hasLength(43));
    final detail = await read.getQuestionDetail(
        session: h.s.session,
        context: ref,
        questionRef: item['questionRef'] as String);
    expect(detail.toJson()['sourceKind'], 'legacy');
    final second = await weakPage(
        session: h.s.session,
        context: ref,
        pageSize: 1,
        cursor: first['nextCursor'] as String);
    expect(((second['items'] as List).single as Map)['bankName'], 'second');
    expect(second['nextCursor'], isNull);
    await h.s.h.db.update('questions', {'content': 'Changed'},
        where: 'id=?', whereArgs: ['a']);
    await expectLater(
        read.getQuestionDetail(
            session: h.s.session,
            context: ref,
            questionRef: item['questionRef'] as String),
        throwsA(isA<ExternalReadException>()));
  });

  test('missing statistics omits all progress fields and refuses metrics',
      () async {
    await grant(statistics: false);
    final ref = await context();
    final banks = await banksPage(session: h.s.session, context: ref);
    expect(banks['statisticsAuthorized'], false);
    expect(
        ((banks['items'] as List).first as Map).containsKey('dueCount'), false);
    await expectLater(readOverview(session: h.s.session, context: ref),
        throwsA(isA<ExternalReadException>()));
  });

  test('statistics-only consent cannot release question previews', () async {
    await grant(content: false);
    final ref = await context();
    expect(
        (await readOverview(
            session: h.s.session, context: ref))['questionCount'],
        2);
    await expectLater(weakPage(session: h.s.session, context: ref),
        throwsA(isA<ExternalReadException>()));
  });

  test('empty authorized set is zero, but revoke during query withholds output',
      () async {
    await grant(empty: true);
    final empty = await context();
    expect(
        (await readOverview(
            session: h.s.session, context: empty))['questionCount'],
        0);
    await grant();
    read.close();
    compose(afterQuery: () => grant(statistics: false));
    final ref = await context();
    await expectLater(readOverview(session: h.s.session, context: ref),
        throwsA(isA<ExternalReadException>()));
  });

  test('replaced connection registry refuses old context and weak references',
      () async {
    final ref = await context();
    final weak = await weakPage(session: h.s.session, context: ref);
    final item = (weak['items'] as List).first as Map;
    read.close();
    compose();
    await expectLater(
        read.getQuestionDetail(
            session: h.s.session,
            context: ref,
            questionRef: item['questionRef'] as String),
        throwsA(isA<ExternalReadException>()));
  });
}
