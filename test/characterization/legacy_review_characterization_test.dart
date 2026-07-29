import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

void main() {
  group('legacy review snapshot characterization', () {
    test(
      'revision deletion override and distillation status survive re-entry',
      () async {
        Map<String, dynamic>? persisted;
        final manager = TaskManager.forTesting(
          saveTask: (taskMap) async {
            persisted = Map<String, dynamic>.from(taskMap);
          },
        );
        manager.addTask(
          ImportTask(
            id: 'synthetic-review',
            title: 'Synthetic review',
            status: TaskStatus.pendingReview,
            parsedData: <Map<String, dynamic>>[
              <String, dynamic>{
                TaskManager.keyReviewItemId: 'item-a',
                'type': 3,
                'content': 'Synthetic item A',
                'standard_answer': '',
              },
              <String, dynamic>{
                TaskManager.keyReviewItemId: 'item-b',
                'type': 3,
                'content': 'Synthetic item B',
                'standard_answer': '',
              },
            ],
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final result = await manager.saveReviewDraft(
          'synthetic-review',
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              TaskManager.keyReviewItemId: 'item-a',
              'type': 3,
              'content': 'Synthetic item A edited',
              'standard_answer': 'synthetic-result',
              'raw_explanation': 'synthetic raw provenance',
              '_explanation_override': 'keep',
              TaskManager.keyAnswerDistillationStatus: 'local_extracted',
            },
          ],
          explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
        );

        expect(result.status, ReviewDraftSaveStatus.saved);
        expect(result.revision, 1);
        expect(persisted, isNotNull);

        final restored = ImportTask.fromMap(persisted!);
        expect(restored.parsedData, hasLength(1));
        expect(
          restored.parsedData!.single[TaskManager.keyReviewItemId],
          'item-a',
        );
        expect(
          restored.parsedData!
              .where(
                (question) => question[TaskManager.keyReviewItemId] == 'item-b',
              )
              .toList(),
          isEmpty,
        );
        expect(
          restored.parsedData!.single['_explanation_override'],
          'keep',
        );
        expect(
          restored.parsedData!.single[TaskManager.keyAnswerDistillationStatus],
          'local_extracted',
        );
        expect(
          restored.diagnostics![TaskManager.keyExplanationRetentionMode],
          ExplanationRetentionMode.allQuestionTypes.name,
        );
        expect(
          restored.diagnostics![TaskManager.keyReviewDraftRevision],
          1,
        );
      },
    );
  });

  group('legacy question row characterization', () {
    test('JSON options and independent explanation remain readable', () {
      final row = <String, dynamic>{
        'id': 'synthetic-question',
        'type': 0,
        'content': 'Synthetic prompt',
        'options': jsonEncode(const <String>['A', 'B']),
        'standard_answer': 'A|||legacy fallback explanation',
        'explanation': 'independent explanation',
        'raw_explanation': 'raw provenance marker',
        'created_at': 1,
        'bank_name': 'Synthetic bank',
      };

      final question = Question.fromMap(row);
      final draft = QuestionDraft.fromMap(
        <String, dynamic>{...row, 'standard_answer': 'A'},
      );

      expect(question.answer, 'A');
      expect(question.explanation, 'independent explanation');
      expect(question.rawExplanation, 'raw provenance marker');
      expect(draft.options, const <String>['A', 'B']);
      expect(draft.rawExplanation, 'raw provenance marker');
    });

    test('answer delimiter explanation remains a V1 fallback', () {
      final question = Question.fromMap(<String, dynamic>{
        'id': 'synthetic-fallback',
        'type': 3,
        'content': 'Synthetic prompt',
        'options': '[]',
        'standard_answer': 'result|||legacy fallback explanation',
        'explanation': '',
        'raw_explanation': 'raw provenance marker',
        'created_at': 1,
        'bank_name': 'Synthetic bank',
      });

      expect(question.answer, 'result');
      expect(question.explanation, 'legacy fallback explanation');
      expect(question.rawExplanation, 'raw provenance marker');
    });
  });
}
