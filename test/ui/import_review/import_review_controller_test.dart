import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_distillation_service.dart';
import 'package:shiroha_quiz/services/import_review/import_review_filter.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/import_review/import_review_controller.dart';

/// Controller-level regressions for the presentation split (ARCH-DEBT-02).
///
/// The review widgets now render only the published view state and forward
/// events back to the controller, so these tests lock the controller
/// transitions those widgets rely on without going through the widget tree.
class _FakeDistiller implements SubjectiveAnswerDistiller {
  _FakeDistiller({this.pending});

  final Completer<SubjectiveAnswerDistillationResult>? pending;
  int callCount = 0;

  @override
  Future<SubjectiveAnswerDistillationResult> distill({
    required int questionNumber,
    required QuestionDraft question,
    required bool isStemOnly,
    Duration timeout = const Duration(seconds: 30),
  }) {
    callCount++;
    return pending?.future ??
        Future<SubjectiveAnswerDistillationResult>.value(
          const SubjectiveAnswerDistillationResult.applied('Distilled answer'),
        );
  }
}

class _RecordingEffects {
  final List<String> messages = <String>[];
  final List<String> errors = <String>[];

  ImportReviewEffects build() {
    return ImportReviewEffects(
      showMessage: messages.add,
      showError: errors.add,
      confirmRepairProposal: (proposal) async => false,
      showCommitSuccess: (report, bankName, folderName) {},
    );
  }
}

Map<String, dynamic> _choiceQuestion(
  int number, {
  required String answer,
}) {
  return <String, dynamic>{
    'q_num': number,
    'question_number': number,
    'type': 0,
    'content': 'Synthetic choice question $number',
    'options': const <String>['A', 'B'],
    'standard_answer': answer,
    'explanation': '',
    'raw_explanation': '',
  };
}

Map<String, dynamic> _explainedChoiceQuestion(
  int number, {
  required String answer,
}) {
  return <String, dynamic>{
    'q_num': number,
    'question_number': number,
    'type': 0,
    'content': 'Synthetic choice question $number',
    'options': const <String>['A', 'B'],
    'standard_answer': answer,
    'explanation': 'Synthetic explanation $number',
    'raw_explanation': 'Synthetic raw explanation $number',
  };
}

Map<String, dynamic> _subjectiveQuestion(int number) {
  return <String, dynamic>{
    'q_num': number,
    'question_number': number,
    'type': 3,
    'content': 'Synthetic subjective question $number',
    'options': const <String>[],
    'standard_answer': '',
    'explanation': 'Synthetic explanation $number',
    'raw_explanation': 'Synthetic raw explanation $number',
  };
}

ImportReviewController _buildController(
  List<Map<String, dynamic>> questions, {
  required ImportReviewEffects effects,
  SubjectiveAnswerDistiller? answerDistiller,
}) {
  return ImportReviewController(
    parsedQuestions: questions,
    effects: effects,
    answerDistiller: answerDistiller,
    taskManager: TaskManager.forTesting(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('filter and sort transitions republish the visible projection', () {
    final recorder = _RecordingEffects();
    final controller = _buildController(
      [
        _choiceQuestion(1, answer: 'A'),
        _choiceQuestion(2, answer: ''),
      ],
      effects: recorder.build(),
    );
    addTearDown(controller.dispose);

    controller.initialize();

    expect(controller.state.allItems, hasLength(2));
    expect(controller.state.visibleItems, hasLength(2));
    expect(controller.state.activeFilter, ImportReviewFilter.all);
    expect(controller.state.activeSort, ImportReviewSort.originalOrder);
    expect(controller.filterCounts[ImportReviewFilter.errorsOnly], 1);
    expect(controller.filterCounts[ImportReviewFilter.missingAnswer], 1);

    controller.enterSelectionMode();
    controller.toggleSelection(controller.state.allItems.first);
    expect(controller.state.selectionMode, isTrue);
    expect(controller.state.selectedOriginalIndices, <int>{0});

    controller.setFilter(ImportReviewFilter.missingAnswer);

    expect(controller.state.activeFilter, ImportReviewFilter.missingAnswer);
    expect(controller.state.visibleItems, hasLength(1));
    expect(controller.state.visibleItems.single.item.originalIndex, 1);
    // Changing the filter leaves selection mode, as the batch bar expects.
    expect(controller.state.selectionMode, isFalse);
    expect(controller.state.selectedOriginalIndices, isEmpty);

    controller.setSort(ImportReviewSort.riskFirst);

    expect(controller.state.activeSort, ImportReviewSort.riskFirst);
    expect(controller.state.visibleItems, hasLength(1));
    expect(controller.state.visibleItems.single.item.originalIndex, 1);
  });

  test('selection mode publishes the selection and batch delete drops it', () {
    final recorder = _RecordingEffects();
    final controller = _buildController(
      [
        _choiceQuestion(1, answer: 'A'),
        _choiceQuestion(2, answer: 'B'),
        _choiceQuestion(3, answer: 'A'),
      ],
      effects: recorder.build(),
    );
    addTearDown(controller.dispose);

    controller.initialize();
    controller.enterSelectionMode();
    controller.selectAllVisible();

    expect(controller.state.selectionMode, isTrue);
    expect(controller.state.selectedOriginalIndices, <int>{0, 1, 2});

    controller.toggleSelection(controller.state.allItems[1]);
    expect(controller.state.selectedOriginalIndices, <int>{0, 2});

    controller.deleteSelected();

    expect(
      controller.state.allItems
          .map((item) => item.originalIndex)
          .toList(growable: false),
      // Only the two selected items are dropped; the untouched one stays.
      <int>[1],
    );
    expect(controller.state.selectionMode, isFalse);
    expect(controller.state.selectedOriginalIndices, isEmpty);
  });

  test('distillation publishes in-flight state and applies the answer',
      () async {
    final pending = Completer<SubjectiveAnswerDistillationResult>();
    final distiller = _FakeDistiller(pending: pending);
    final recorder = _RecordingEffects();
    final controller = _buildController(
      [_subjectiveQuestion(1)],
      effects: recorder.build(),
      answerDistiller: distiller,
    );
    addTearDown(controller.dispose);

    controller.initialize();

    expect(controller.answerDistillationCandidateCount, 1);
    final item = controller.state.allItems.single;
    expect(controller.isAnswerDistillationCandidate(item), isTrue);

    final operation = controller.distillSingleAnswer(item);
    await Future<void>.delayed(Duration.zero);

    expect(distiller.callCount, 1);
    expect(controller.state.isDistillingAnswers, isTrue);
    expect(controller.state.answerDistillationTotalCount, 1);
    expect(controller.state.activeAnswerDistillationIndex, 0);
    expect(controller.state.answerDistillationCancellationRequested, isFalse);

    controller.cancelAnswerDistillation();
    expect(controller.state.answerDistillationCancellationRequested, isTrue);

    pending.complete(
      const SubjectiveAnswerDistillationResult.applied('Distilled answer'),
    );
    await operation;

    expect(controller.state.isDistillingAnswers, isFalse);
    expect(controller.state.activeAnswerDistillationIndex, isNull);
    expect(controller.state.answerDistillationCompletedCount, 1);
    expect(
      controller.state.allItems.single.draft.standardAnswer,
      'Distilled answer',
    );
    expect(controller.state.answerDistillationStatuses[0], 'ai_applied');
    expect(recorder.messages, isNotEmpty);
    expect(recorder.errors, isEmpty);
  });

  test('per-question explanation override is published through the state', () {
    final recorder = _RecordingEffects();
    final controller = _buildController(
      [_explainedChoiceQuestion(1, answer: 'A')],
      effects: recorder.build(),
    );
    addTearDown(controller.dispose);

    controller.initialize();

    // Compatibility default: objective explanations are not retained.
    expect(
      controller
          .isQuestionExplanationRetained(controller.state.allItems.single),
      isFalse,
    );

    controller.setQuestionExplanationRetention(
      controller.state.allItems.single,
      true,
    );
    expect(
      controller
          .isQuestionExplanationRetained(controller.state.allItems.single),
      isTrue,
    );

    controller.setQuestionExplanationRetention(
      controller.state.allItems.single,
      false,
    );
    expect(
      controller
          .isQuestionExplanationRetained(controller.state.allItems.single),
      isFalse,
    );
  });
}
