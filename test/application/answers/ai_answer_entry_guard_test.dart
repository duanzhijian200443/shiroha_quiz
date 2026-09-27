import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_entry_guard.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';

RichContent _text(String text) => RichContent(nodes: [TextNode(text)]);

StudyQuestionReviewState _review() => const StudyQuestionReviewState(
      due: false,
      lapseCount: 0,
      difficulty: 0,
      lastLapseTime: null,
    );

TypedStudyQuestionRead _typed(String questionId) => TypedStudyQuestionRead(
      questionId: questionId,
      bankName: 'bank_math',
      createdAt: 1,
      draft: QuestionDraftV2(
        questionId: questionId,
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: _text('solve for x'),
      ),
      review: _review(),
    );

LegacyStudyQuestionRead _legacy(String questionId) => LegacyStudyQuestionRead(
      questionId: questionId,
      bankName: 'bank_math',
      createdAt: 1,
      stemText: 'solve for x',
      optionsText: '[]',
      answerText: '',
      explanationText: null,
      legacyType: 1,
      review: _review(),
    );

final class _RoutePort extends Fake implements StudyQuestionQueryPort {
  _RoutePort({this.read, this.failure});

  final StudyQuestionRead? read;
  final StudyQueryRepositoryFailure? failure;
  final List<String> detailCalls = <String>[];
  final List<int> nowCalls = <int>[];

  @override
  Future<StudyQuestionRead?> getStudyQuestionDetail(
    String questionId, {
    required int nowUnixSeconds,
  }) async {
    detailCalls.add(questionId);
    nowCalls.add(nowUnixSeconds);
    final failure = this.failure;
    if (failure != null) throw StudyQueryRepositoryException(failure);
    return read;
  }
}

DateTime _clock() => DateTime.utc(2026, 9, 27, 12);

AiAnswerEntryGuard _guard(_RoutePort port) =>
    AiAnswerEntryGuard(questionPort: port, clock: _clock);

void main() {
  group('ANSWER-ENTRY-GUARD routing decision', () {
    test('typed persisted identity routes away from the legacy entry',
        () async {
      final port = _RoutePort(read: _typed('q_typed_1'));

      final route = await _guard(port).routeFor(storageId: 'q_typed_1');

      expect(route, AiAnswerEntryRoute.typed);
      expect(port.detailCalls, ['q_typed_1']);
    });

    test('legacy persisted identity keeps the legacy entry usable', () async {
      final port = _RoutePort(read: _legacy('q_legacy_1'));

      final route = await _guard(port).routeFor(storageId: 'q_legacy_1');

      expect(route, AiAnswerEntryRoute.legacy);
      expect(port.detailCalls, ['q_legacy_1']);
    });

    test('classification reads through the injected clock', () async {
      final port = _RoutePort(read: _legacy('q_legacy_1'));

      await _guard(port).routeFor(storageId: 'q_legacy_1');

      expect(
        port.nowCalls.single,
        DateTime.utc(2026, 9, 27, 12).millisecondsSinceEpoch ~/ 1000,
      );
    });

    test('missing question fails closed instead of defaulting to legacy',
        () async {
      final port = _RoutePort(read: null);

      final route = await _guard(port).routeFor(storageId: 'q_absent');

      expect(route, AiAnswerEntryRoute.unavailable);
      expect(port.detailCalls, ['q_absent']);
    });

    test('corrupt typed sidecar fails closed', () async {
      final port = _RoutePort(
        failure: StudyQueryRepositoryFailure.corruptPayload,
      );

      final route = await _guard(port).routeFor(storageId: 'q_typed_1');

      expect(route, AiAnswerEntryRoute.unavailable);
    });

    test('unavailable store fails closed', () async {
      final port = _RoutePort(failure: StudyQueryRepositoryFailure.unavailable);

      final route = await _guard(port).routeFor(storageId: 'q_legacy_1');

      expect(route, AiAnswerEntryRoute.unavailable);
    });

    test('blank storageId fails closed without any read', () async {
      final port = _RoutePort(read: _legacy('q_legacy_1'));

      expect(
        await _guard(port).routeFor(storageId: ''),
        AiAnswerEntryRoute.unavailable,
      );
      expect(
        await _guard(port).routeFor(storageId: '   '),
        AiAnswerEntryRoute.unavailable,
      );
      expect(port.detailCalls, isEmpty);
    });

    test('storageId is trimmed to the real persisted identity', () async {
      final port = _RoutePort(read: _typed('q_typed_1'));

      final route = await _guard(port).routeFor(storageId: '  q_typed_1\n');

      expect(route, AiAnswerEntryRoute.typed);
      expect(port.detailCalls, ['q_typed_1']);
    });
  });
}
