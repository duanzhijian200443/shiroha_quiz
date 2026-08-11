import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/safe_write/typed_answer_command.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';

QuestionDraftV2 _draft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'w0_t1_command_q',
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: RichContent(nodes: <ContentNode>[TextNode('Stem.')]),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'opt_a',
        label: 'A',
        content: RichContent(nodes: <ContentNode>[TextNode('first')]),
      ),
    ],
    answer: answer,
  );
}

class _RecordingPort implements TypedAnswerPersistencePort {
  final calls = <(String, QuestionDraftV2, QuestionAnswer?)>[];
  Object? error;

  @override
  Future<void> updateTypedAnswer({
    required String storageId,
    required QuestionDraftV2 expectedDraft,
    required QuestionAnswer? newAnswer,
  }) async {
    calls.add((storageId, expectedDraft, newAnswer));
    final failure = error;
    if (failure != null) throw failure;
  }
}

void main() {
  test('forwards the exact storage id, expected draft, and new answer',
      () async {
    final port = _RecordingPort();
    final command = TypedAnswerCommand(port);
    final draft = _draft();
    final answer = ChoiceAnswer(optionIds: <String>['opt_a']);

    await command.updateTypedAnswer(
      storageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
      expectedDraft: draft,
      newAnswer: answer,
    );

    expect(port.calls, hasLength(1));
    final call = port.calls.single;
    expect(call.$1, 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b');
    expect(call.$2, draft);
    expect(call.$3, answer);
  });

  test('forwarding a null answer keeps the manual clear semantics', () async {
    final port = _RecordingPort();
    final command = TypedAnswerCommand(port);

    await command.updateTypedAnswer(
      storageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
      expectedDraft: _draft(),
      newAnswer: null,
    );

    expect(port.calls.single.$3, isNull);
  });

  test('propagates port failures without swallowing them', () async {
    final port = _RecordingPort()..error = StateError('synthetic port failure');
    final command = TypedAnswerCommand(port);

    await expectLater(
      command.updateTypedAnswer(
        storageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
        expectedDraft: _draft(),
        newAnswer: null,
      ),
      throwsA(isA<StateError>()),
    );
  });
}
