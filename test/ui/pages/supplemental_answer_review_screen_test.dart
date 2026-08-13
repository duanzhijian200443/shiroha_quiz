import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_command.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_failure.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_matcher.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_review_session.dart';
import 'package:shiroha_quiz/application/supplemental_answers/target_question_snapshot_service.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_match_record.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_fragment.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_scope.dart';
import 'package:shiroha_quiz/ui/pages/supplemental_answer_review_screen.dart';

const _artifact = SupplementalArtifactContext(
  supplementalFileId: 'file_001',
  artifactId: 'artifact_001',
  artifactRevision: 1,
);

void main() {
  testWidgets('renders fill candidate and confirms through the command',
      (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final session = _session(
      targets: [
        _target('q_1', number: 1),
        _target('q_2', number: 2),
      ],
      fragments: [
        _fragment('frag_1', main: '1', answer: 'x = 1'),
        _fragment('frag_2', main: '2', answer: 'x = 2'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SupplementalAnswerReviewScreen(
          session: session,
          confirmCommand: command,
        ),
      ),
    );

    expect(find.text('可填写答案'), findsOneWidget);
    expect(find.text('x = 1'), findsOneWidget);
    expect(find.text('x = 2'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(
      find.widgetWithText(FilledButton, '确认填写').first,
    );
    await tester.pumpAndSettle();

    expect(port.confirmed, hasLength(1));
    expect(port.confirmed.single.candidateId, 'cand_frag_1_q_1');
    expect(find.text('已写入'), findsOneWidget);
  });

  testWidgets('conflict requires two explicit replace steps', (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final session = _session(
      targets: [
        _target(
          'q_1',
          number: 1,
          answer: ContentAnswer(content: _text('x = 9')),
        ),
      ],
      fragments: [
        _fragment('frag_1', main: '1', answer: 'x = 1'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SupplementalAnswerReviewScreen(
          session: session,
          confirmCommand: command,
        ),
      ),
    );

    // First explicit action arms the per-question replace review.
    await tester.tap(find.widgetWithText(FilledButton, '确认替换'));
    await tester.pump();
    expect(port.confirmed, isEmpty);
    expect(find.text('二次确认替换'), findsOneWidget);

    // Second explicit action is the reconfirmation that commits.
    await tester.tap(find.widgetWithText(FilledButton, '二次确认替换'));
    await tester.pumpAndSettle();
    expect(port.confirmed, hasLength(1));
    expect(
      port.confirmed.single.writeIntent,
      CandidateWriteIntent.replace,
    );
    expect(find.text('已替换'), findsOneWidget);
  });

  testWidgets('reject is terminal with zero mutation', (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final session = _session(
      targets: [
        _target('q_1', number: 1),
      ],
      fragments: [
        _fragment('frag_1', main: '1', answer: 'x = 1'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SupplementalAnswerReviewScreen(
          session: session,
          confirmCommand: command,
        ),
      ),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, '拒绝'));
    await tester.pump();

    expect(find.text('已拒绝'), findsOneWidget);
    expect(port.confirmed, isEmpty);
  });

  testWidgets('stale target failure shows a fixed safe message',
      (tester) async {
    final port = _FakePersistencePort(
      error: const SupplementalAnswerException(
        SupplementalAnswerFailure.staleTarget,
      ),
    );
    final command = _command(port);
    final session = _session(
      targets: [
        _target('q_1', number: 1),
      ],
      fragments: [
        _fragment('frag_1', main: '1', answer: 'x = 1'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SupplementalAnswerReviewScreen(
          session: session,
          confirmCommand: command,
        ),
      ),
    );

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '确认填写'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已变化'), findsOneWidget);
    expect(port.confirmed, isEmpty);
  });

  testWidgets('ambiguous and unmatched records render as non-writable',
      (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final session = _session(
      targets: [
        _target('q_1', number: 1),
        _target('q_2', number: 1),
      ],
      fragments: [
        _fragment('frag_1', main: '1', answer: 'x = 1'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SupplementalAnswerReviewScreen(
          session: session,
          confirmCommand: command,
        ),
      ),
    );

    expect(find.text('不可写入项'), findsOneWidget);
    expect(find.textContaining('ambiguous'), findsOneWidget);
  });
}

SupplementalAnswerReviewSession _session({
  required List<AnswerTargetReference> targets,
  required List<SupplementalAnswerFragment> fragments,
}) {
  const matcher = SupplementalAnswerMatcher();
  final snapshot = TargetQuestionSnapshot(
    targets: targets,
    reports: const [],
  );
  final result = matcher.match(
    fragments: fragments,
    snapshot: snapshot,
    artifact: _artifact,
  );
  return SupplementalAnswerReviewSession(
    request: SupplementalAnswerMatchRequest(
      targetScope: const QuestionBankScope(bankName: 'bank_math'),
      supplementalFileId: 'file_001',
    ),
    snapshot: snapshot,
    matchResult: result,
  );
}

AnswerTargetReference _target(
  String storageId, {
  required int number,
  QuestionAnswer? answer,
}) {
  return AnswerTargetReference(
    storageId: storageId,
    bankName: 'bank_math',
    draft: QuestionDraftV2(
      questionId: storageId,
      kind: QuestionKind.shortAnswer,
      questionNumber: number,
      stem: _text('stem $number'),
      answer: answer,
    ),
  );
}

SupplementalAnswerFragment _fragment(
  String fragmentId, {
  required String main,
  required String answer,
}) {
  return SupplementalAnswerFragment(
    fragmentId: fragmentId,
    normalizedMainNumber: main,
    answerContent: _text(answer),
    sourceRefs: [
      SourceRef.document(sourceId: 'artifact_001'),
    ],
    sequencePosition: const SupplementalSequencePosition(
      partIndex: 0,
      continuationOrdinal: 0,
    ),
  );
}

SupplementalAnswerConfirmCommand _command(_FakePersistencePort port) {
  return SupplementalAnswerConfirmCommand(
    artifactPort: _StaticArtifactPort(),
    persistencePort: port,
  );
}

class _StaticArtifactPort implements ParsedArtifactLifecyclePort {
  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    return ParsedArtifactSnapshot(
      artifact: ParsedArtifact(
        fileId: 'file_001',
        artifactId: 'artifact_001',
        revision: 1,
        payloadSchemaVersion: 1,
      ),
      sourceDocument: SourceDocument(
        sourceId: 'artifact_001',
        parts: const [],
      ),
    );
  }

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ParsedArtifactEnsureResult> reparseArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
    required int expectedRevision,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> removeCurrentArtifact({
    required String fileId,
    required int expectedRevision,
  }) {
    throw UnimplementedError();
  }
}

class _FakePersistencePort implements SupplementalAnswerPersistencePort {
  _FakePersistencePort({this.error});

  final SupplementalAnswerException? error;
  final List<AnswerCandidate> confirmed = <AnswerCandidate>[];

  @override
  Future<void> confirmCandidate(AnswerCandidate candidate) async {
    final failure = error;
    if (failure != null) throw failure;
    confirmed.add(candidate);
  }
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}
