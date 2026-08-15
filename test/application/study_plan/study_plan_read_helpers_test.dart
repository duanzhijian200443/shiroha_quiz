// SPL-1-D0 read-helper tests: deterministic pool ordering, mandatory
// storageId dedup, the deterministic preview builder, and focused
// layering/privacy evidence for the study_plan sources.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_pool_order.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_preview_builder.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';

StudyPlanCandidate _candidate({
  required String storageId,
  bool due = false,
  int? nextReviewAt,
  int lapses = 0,
  double difficulty = 5.0,
  StudyPlanQuestionClassification classification =
      StudyPlanQuestionClassification.review,
}) {
  return StudyPlanCandidate(
    storageId: storageId,
    bankName: 'Math',
    due: due,
    nextReviewAt: nextReviewAt,
    lapses: lapses,
    difficulty: difficulty,
    classification: classification,
  );
}

void main() {
  const order = StudyPlanPoolOrder();

  group('StudyPlanPoolOrder', () {
    test('due: nextReviewAt ASC then storageId ASC; nulls last', () {
      final shuffled = <StudyPlanCandidate>[
        _candidate(storageId: 'b', nextReviewAt: 200),
        _candidate(storageId: 'a', nextReviewAt: 200),
        _candidate(storageId: 'c', nextReviewAt: 100),
        _candidate(storageId: 'd'),
      ];
      final ordered = order.orderDue(shuffled);
      expect(
        ordered.map((c) => c.storageId).toList(),
        <String>['c', 'a', 'b', 'd'],
      );
    });

    test('weak: lapses DESC, difficulty DESC, storageId ASC', () {
      final shuffled = <StudyPlanCandidate>[
        _candidate(storageId: 'z', lapses: 1, difficulty: 9.0),
        _candidate(storageId: 'a', lapses: 2, difficulty: 4.0),
        _candidate(storageId: 'b', lapses: 2, difficulty: 8.0),
        _candidate(storageId: 'c', lapses: 2, difficulty: 8.0),
      ];
      final ordered = order.orderWeak(shuffled);
      expect(
        ordered.map((c) => c.storageId).toList(),
        <String>['b', 'c', 'a', 'z'],
      );
    });

    test('new: storageId ASC', () {
      final shuffled = <StudyPlanCandidate>[
        _candidate(storageId: 'q'),
        _candidate(storageId: 'a'),
        _candidate(storageId: 'm'),
      ];
      final ordered = order.orderNew(shuffled);
      expect(
        ordered.map((c) => c.storageId).toList(),
        <String>['a', 'm', 'q'],
      );
    });

    test('dedupeByStorageId keeps the first occurrence and stays stable', () {
      final candidates = <StudyPlanCandidate>[
        _candidate(storageId: 'a', lapses: 3),
        _candidate(storageId: 'b', lapses: 2),
        _candidate(storageId: 'a', lapses: 1),
        _candidate(storageId: 'c', lapses: 0),
      ];
      final deduped = order.dedupeByStorageId(candidates);
      expect(deduped.map((c) => c.storageId).toList(), <String>['a', 'b', 'c']);
      expect(deduped[0].lapses, 3);
    });
  });

  group('StudyPlanPreviewBuilder', () {
    const builder = StudyPlanPreviewBuilder();

    test('is deterministic and mirrors the admitted context', () {
      final plan = StudyPlanInput.normalize(
        bankName: 'Math',
        goal: 'Goal',
        dailyTarget: 25,
        priority: StudyPlanPriority.dueFirst,
        horizonDays: 14,
      );
      const context = StudyPlanPlanningContext(
        bankName: 'Math',
        questionCount: 120,
        masteredCount: 30,
        dueCount: 40,
        weakCount: 10,
        newCount: 50,
      );
      final a = builder.build(plan: plan, context: context);
      final b = builder.build(plan: plan, context: context);
      expect(a, b);
      expect(a.bankName, 'Math');
      expect(a.goal, 'Goal');
      expect(a.dailyTarget, 25);
      expect(a.priority, StudyPlanPriority.dueFirst);
      expect(a.horizonDays, 14);
      expect(a.questionCount, 120);
      expect(a.masteredCount, 30);
      expect(a.dueCount, 40);
      expect(a.weakCount, 10);
      expect(a.newCount, 50);
      expect(a.estimatedDays, 4); // ceil(90 / 25)
    });

    test('estimatedDays is zero when nothing is unmastered', () {
      final plan = StudyPlanInput.normalize(bankName: 'Math');
      const context = StudyPlanPlanningContext(
        bankName: 'Math',
        questionCount: 50,
        masteredCount: 50,
        dueCount: 0,
        weakCount: 0,
        newCount: 0,
      );
      expect(
        builder.build(plan: plan, context: context).estimatedDays,
        0,
      );
    });
  });

  group('study_plan source layering', () {
    test('application/domain study_plan sources stay producer-neutral', () {
      final forbidden = <RegExp>[
        RegExp(r'''^\s*import\s+['"]package:sqflite'''),
        RegExp(r'\bDatabaseHelper\b'),
        RegExp(r'''data/models/(question|persisted_question)\.dart'''),
        RegExp(r'''^\s*import\s+['"]package:flutter/'''),
      ];
      final roots = <String>[
        'lib/application/study_plan',
        'lib/domain/study_plan',
      ];
      for (final root in roots) {
        final directory = Directory(root);
        if (!directory.existsSync()) {
          fail('Missing expected source directory: $root');
        }
        final files = <File>[
          ...directory
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart')),
        ];
        expect(files, isNotEmpty, reason: '$root must contain Dart sources');
        for (final file in files) {
          final source = file.readAsStringSync();
          for (final pattern in forbidden) {
            expect(
              pattern.hasMatch(source),
              isFalse,
              reason: '${file.path} must not match $pattern',
            );
          }
        }
      }
    });
  });
}
