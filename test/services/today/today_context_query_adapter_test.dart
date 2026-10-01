import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/application/study_query/study_query_clock.dart';
import 'package:shiroha_quiz/application/study_query/study_query_error.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:shiroha_quiz/services/today/system_local_study_time_zone.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/today/today_context_query.dart';
import 'package:shiroha_quiz/services/today/today_context_query_adapter.dart';

final class _Clock implements StudyClock {
  _Clock(this.instant);
  final DateTime instant;
  @override
  DateTime nowUtc() => instant.toUtc();
}

void main() {
  test('no chosen bank never issues a statistics read', () async {
    var reads = 0;
    for (final bank in [null, '点击修改选择题库']) {
      final subject = TodayContextQueryAdapter(
        loadCurrentBank: () async => bank,
        loadBankStats: (_) async {
          reads++;
          return {};
        },
      );
      final snapshot = await subject.loadContext();
      expect(snapshot.bankName, isNull);
      expect(snapshot.totalCount, 0);
    }
    expect(reads, 0);
  });

  test('reads chosen bank once and retains ordinary counts without mixing due',
      () async {
    final calls = <String>[];
    final subject = TodayContextQueryAdapter(
      loadCurrentBank: () async => 'ordinary-bank',
      loadBankStats: (bank) async {
        calls.add(bank);
        return {
          'total': 20,
          'new_count': 6,
          'review_count': 4,
          'mastered_count': 10,
          'due_count': 99,
        };
      },
    );
    final snapshot = await subject.loadContext();
    expect(calls, ['ordinary-bank']);
    expect(snapshot.bankName, 'ordinary-bank');
    expect(snapshot.totalCount, 20);
    expect(snapshot.newCount, 6);
    expect(snapshot.reviewCount, 4);
    expect(snapshot.masteredCount, 10);
  });

  test('storage failure crosses the port only as a safe category', () async {
    for (final settingsFails in [true, false]) {
      final subject = TodayContextQueryAdapter(
        loadCurrentBank: () async {
          if (settingsFails) throw StateError('private-storage-error');
          return 'ordinary-bank';
        },
        loadBankStats: (_) async => throw StateError('private-storage-error'),
      );
      await expectLater(
          subject.loadContext(), throwsA(isA<TodayContextUnavailable>()));
    }
  });
  test(
      'overview summaries keep their scope without replacing ordinary due semantics',
      () async {
    final banks = <String>[];
    final subject = TodayContextQueryAdapter(
        loadCurrentBank: () async => 'ordinary-bank',
        loadBankStats: (_) async => {
              'new_count': 6,
              'review_count': 4,
              'total': 999,
              'mastered_count': 999
            },
        loadStudyOverview: (bank) async {
          banks.add(bank);
          return const StudyOverview(
              questionCount: 20,
              masteredCount: 10,
              dueCount: 99,
              todayPracticeCount: 3,
              wrongQuestionCount: 2);
        });
    final value = await subject.loadContext();
    expect(banks, ['ordinary-bank']);
    expect(value.totalCount, 20);
    expect(value.masteredCount, 10);
    expect(value.todayPracticeCount, 3);
    expect(value.newCount, 6);
    expect(value.reviewCount, 4);
  });

  test(
      'missing overview is unknown; failed overview is a safe failure rather than zero',
      () async {
    final missing = TodayContextQueryAdapter(
        loadCurrentBank: () async => 'bank', loadBankStats: (_) async => {});
    expect((await missing.loadContext()).todayPracticeCount, isNull);
    final failed = TodayContextQueryAdapter(
        loadCurrentBank: () async => 'bank',
        loadBankStats: (_) async => {},
        loadStudyOverview: (_) async =>
            throw StateError('private-storage-cause'));
    await expectLater(
        failed.loadContext(), throwsA(isA<TodayContextUnavailable>()));
  });

  test(
      'system local resolver uses calendar midnight and rejects other zone names',
      () {
    const resolver = SystemLocalStudyTimeZone();
    final instant = DateTime.utc(2026, 10, 1, 23, 30);
    final local = instant.toLocal();
    final date =
        resolver.localDateOf(instant, SystemLocalStudyTimeZone.zoneName);
    expect(date,
        StudyLocalDate(year: local.year, month: local.month, day: local.day));
    expect(
        resolver.utcInstantOfLocalMidnight(
            date, SystemLocalStudyTimeZone.zoneName),
        DateTime(local.year, local.month, local.day).toUtc());
    expect(() => resolver.localDateOf(instant, 'UTC'),
        throwsA(isA<StudyQueryException>()));
  });

  test(
      'real overview counts distinct bank-local reviews at midnight and supports the virtual wrong bank only in Today',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await DatabaseHelper.deleteDatabaseFile();
    addTearDown(DatabaseHelper.deleteDatabaseFile);
    final db = await DatabaseHelper.instance.database;
    final midnight = DateTime(2026, 10, 1).millisecondsSinceEpoch ~/ 1000;
    for (final id in ['today', 'old', 'other']) {
      await db.insert('questions', {
        'id': id,
        'type': 0,
        'content': 'synthetic',
        'standard_answer': 'A',
        'created_at': 0,
        'bank_name': id == 'other' ? 'other-bank' : 'bank'
      });
      await db.insert('review_states', {
        'question_id': id,
        'state': id == 'today' ? 3 : 0,
        'next_review_time': 0,
        'lapses': id == 'today' ? 1 : 0
      });
    }
    for (final entry in [
      ('today', midnight),
      ('today', midnight + 60),
      ('old', midnight - 1),
      ('other', midnight + 1)
    ]) {
      await db.insert('review_logs', {
        'id': '${entry.$1}-${entry.$2}',
        'question_id': entry.$1,
        'review_time': entry.$2,
        'duration_ms': 0,
        'grade': 3
      });
    }
    final query = StudyQueryService(
        questionQuery: QuestionRepository.instance,
        metricsQuery: TodayStudyMetricsQuery(),
        timeZone: const SystemLocalStudyTimeZone(),
        clock: _Clock(DateTime(2026, 10, 1, 12)));
    final subject = TodayContextQueryAdapter(
        loadCurrentBank: () async => 'bank',
        loadBankStats: (bank) =>
            ReviewRepository.instance.getBankStats(bank, midnight + 43200),
        loadStudyOverview: (bank) => query.getStudyOverview(
            bankName: bank, timezone: SystemLocalStudyTimeZone.zoneName));
    final result = await subject.loadContext();
    expect(result.totalCount, 2);
    expect(result.masteredCount, 1);
    expect(result.todayPracticeCount, 1);
    expect(result.newCount, 1);
    expect(result.reviewCount, 1);
    final wrong = await query.getStudyOverview(
        bankName: '🔥 全局错题本', timezone: SystemLocalStudyTimeZone.zoneName);
    expect(wrong.questionCount, 1);
    expect(wrong.todayPracticeCount, 1);
    expect(wrong.masteredCount, 1);
    final ordinaryT0 = await ReviewRepository.instance.getStudyOverviewCounts(
        bankName: '🔥 全局错题本',
        nowUnixSeconds: midnight + 43200,
        todayStartUnixSeconds: midnight);
    expect(ordinaryT0.questionCount, 0); // Unchanged T0 exact bank-name scope.
  });
}
