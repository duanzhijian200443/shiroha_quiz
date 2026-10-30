import 'package:flutter_test/flutter_test.dart';
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

  void compose({Future<void> Function()? afterQuery}) {
    read = ExternalReadContextService(
        admission: h.s.service.runtimeAdmission,
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
      'authorized aggregate deduplicates overlapping grants and keeps T0 counts',
      () async {
    final ref = await context();
    expect(
        await read.studyOverview(
            session: h.s.session, context: ref, timezone: 'Asia/Shanghai'),
        {
          'questionCount': 2,
          'masteredCount': 1,
          'dueCount': 1,
          'todayPracticeCount': 1,
          'wrongQuestionCount': 2,
        });
    final banks = await read.listStudyBanks(session: h.s.session, context: ref);
    expect((banks['items'] as List).length, 2);
    final target = (banks['items'] as List).first as Map;
    final one = await read.openStudyContext(
        session: h.s.session, targetRef: target['targetRef'] as String);
    final overview =
        await read.studyOverview(session: h.s.session, context: one);
    expect(overview['questionCount'], 1);
  });

  test('due buckets use original half-open window and requested local timezone',
      () async {
    final ref = await context();
    expect(
        await read.studyDueSummary(
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
    final first = await read.studyWeakQuestions(
        session: h.s.session, context: ref, pageSize: 1);
    final item = (first['items'] as List).single as Map;
    expect(item['bankName'], 'bank');
    expect(item['lapseCount'], 2);
    expect(item['questionRef'], hasLength(43));
    final detail = await read.getQuestionDetail(
        session: h.s.session,
        context: ref,
        questionRef: item['questionRef'] as String);
    expect(detail.toJson()['sourceKind'], 'legacy');
    final second = await read.studyWeakQuestions(
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
    final banks = await read.listStudyBanks(session: h.s.session, context: ref);
    expect(banks['statisticsAuthorized'], false);
    expect(
        ((banks['items'] as List).first as Map).containsKey('dueCount'), false);
    await expectLater(read.studyOverview(session: h.s.session, context: ref),
        throwsA(isA<ExternalReadException>()));
  });

  test('statistics-only consent cannot release question previews', () async {
    await grant(content: false);
    final ref = await context();
    expect(
        (await read.studyOverview(
            session: h.s.session, context: ref))['questionCount'],
        2);
    await expectLater(
        read.studyWeakQuestions(session: h.s.session, context: ref),
        throwsA(isA<ExternalReadException>()));
  });

  test('empty authorized set is zero, but revoke during query withholds output',
      () async {
    await grant(empty: true);
    final empty = await context();
    expect(
        (await read.studyOverview(
            session: h.s.session, context: empty))['questionCount'],
        0);
    await grant();
    read.close();
    compose(afterQuery: () => grant(statistics: false));
    final ref = await context();
    await expectLater(read.studyOverview(session: h.s.session, context: ref),
        throwsA(isA<ExternalReadException>()));
  });

  test('replaced connection registry refuses old context and weak references',
      () async {
    final ref = await context();
    final weak =
        await read.studyWeakQuestions(session: h.s.session, context: ref);
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
