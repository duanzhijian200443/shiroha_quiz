import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/today/today_context_query.dart';
import 'package:shiroha_quiz/services/today/today_context_query_adapter.dart';

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
}
