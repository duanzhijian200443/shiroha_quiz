import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answer_completion/answer_completion_query.dart';
import 'package:shiroha_quiz/application/answer_completion/answer_completion_supplemental.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_failure.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_review_session.dart';
import 'package:shiroha_quiz/domain/answer_completion/imported_question_set.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_match_record.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_scope.dart';

RichContent _text(String s) => RichContent(nodes: [TextNode(s)]);
AnswerCompletionMember _member(String id, int number, {String? answer}) =>
    AnswerCompletionMember.typed(
        storageId: id,
        typedDraft: QuestionDraftV2(
            questionId: 'draft-$id',
            questionNumber: number,
            kind: QuestionKind.shortAnswer,
            stem: _text('Synthetic stem'),
            answer:
                answer == null ? null : ContentAnswer(content: _text(answer))));
AnswerCompletionSet _set(List<AnswerCompletionMember> members,
        {bool other = false}) =>
    AnswerCompletionSet(
        set: ImportedQuestionSet(
            setId: other
                ? '11111111-1111-4111-8111-111111111112'
                : '11111111-1111-4111-8111-111111111111',
            bankName: 'bank',
            displayName: 'synthetic.pdf',
            createdAt: 1),
        provenance: AnswerCompletionProvenance.none,
        members: members);

class _Query implements AnswerCompletionQuery {
  _Query(this.read);
  AnswerCompletionRead read;
  @override
  Future<AnswerCompletionRead> readBank(String bankName) async => read;
}

class _Catalog extends Fake implements LibraryFileRepositoryPort {}

class _Ingestion extends Fake implements FileIngestionPort {}

class _Artifacts extends Fake implements ParsedArtifactLifecyclePort {
  int calls = 0;
  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    calls++;
    return ParsedArtifactSnapshot(
        artifact: ParsedArtifact(
            fileId: fileId,
            artifactId: 'artifact',
            revision: 1,
            payloadSchemaVersion: 1),
        sourceDocument: SourceDocument(sourceId: 'artifact', parts: [
          for (var i = 1; i <= 3; i++)
            SourceContentPart(
                sourceRef: SourceRef.at(
                    sourceId: 'artifact',
                    point: SourcePoint.block(
                        pageNumber: 1, blockId: 'block-$i', readingOrder: i)),
                content: _text('$i. answer-$i'),
                role: SourceContentRole.answerLike),
        ]));
  }
}

void main() {
  test(
      'full ordered set keeps noOp/fill/conflict and isolates another Q1 in same bank',
      () async {
    final selected = _set([
      _member('q3', 3, answer: 'different'),
      _member('q1', 1, answer: 'answer-1'),
      _member('q2', 2)
    ]);
    final query = _Query(AnswerCompletionSnapshot(sets: [
      selected,
      _set([_member('other-q1', 1)], other: true)
    ], ungrouped: []));
    final binding = AnswerCompletionSupplementalService(
            query: query,
            fileCatalog: _Catalog(),
            artifactPort: _Artifacts(),
            ingestion: _Ingestion())
        .bind(selected);
    expect(binding.scope, isA<ExplicitQuestionScope>());
    expect(binding.scope.storageIds, ['q3', 'q1', 'q2']);
    final session = await binding.activation
        .startSession(targetScope: binding.scope, supplementalFileId: 'file');
    expect(
        session.snapshot.targets.map((t) => t.storageId), ['q3', 'q1', 'q2']);
    expect(session.snapshot.reports, isEmpty);
    final candidates = {
      for (final record in session.records)
        if (record.candidate case final c?) c.targetStorageId: c
    };
    expect(candidates.keys.toSet(), {'q1', 'q2', 'q3'});
    expect(candidates['q1']!.writeIntent, CandidateWriteIntent.noOp);
    expect(candidates['q2']!.writeIntent, CandidateWriteIntent.fill);
    expect(candidates['q3']!.writeIntent, CandidateWriteIntent.replace);
    expect(() => session.confirmFill(candidates['q3']!.candidateId),
        throwsA(isA<SupplementalAnswerReviewException>()));
    expect(() => session.confirmReplace(candidates['q3']!.candidateId),
        throwsA(isA<SupplementalAnswerReviewException>()));
    final armed = session.selectForReplace(candidates['q3']!.candidateId);
    expect(
        armed
            .confirmReplace(candidates['q3']!.candidateId)
            .confirmation
            .candidate,
        candidates['q3']);
  });

  test('answered duplicate locator remains ambiguity evidence', () async {
    final selected = _set(
        [_member('answered', 1, answer: 'answer-1'), _member('missing', 1)]);
    final query =
        _Query(AnswerCompletionSnapshot(sets: [selected], ungrouped: []));
    final binding = AnswerCompletionSupplementalService(
            query: query,
            fileCatalog: _Catalog(),
            artifactPort: _Artifacts(),
            ingestion: _Ingestion())
        .bind(selected);
    final session = await binding.activation
        .startSession(targetScope: binding.scope, supplementalFileId: 'file');
    expect(session.records.first.disposition, AnswerMatchDisposition.ambiguous);
    expect(session.records.first.candidate, isNull);
    expect(session.snapshot.targets, hasLength(2));
  });

  for (final drift in [
    'deleted',
    'moved',
    'reordered',
    'legacy',
    'corrupt',
    'unavailable'
  ]) {
    test(
        '$drift while picker is open fails before artifact read; never shrinks',
        () async {
      final selected = _set([_member('q1', 1), _member('q2', 2)]);
      final query =
          _Query(AnswerCompletionSnapshot(sets: [selected], ungrouped: []));
      final artifacts = _Artifacts();
      final binding = AnswerCompletionSupplementalService(
              query: query,
              fileCatalog: _Catalog(),
              artifactPort: artifacts,
              ingestion: _Ingestion())
          .bind(selected);
      query.read = drift == 'unavailable'
          ? const AnswerCompletionQueryUnavailable()
          : AnswerCompletionSnapshot(sets: [
              _set(switch (drift) {
                'deleted' || 'moved' => [_member('q1', 1)],
                'reordered' => [_member('q2', 2), _member('q1', 1)],
                'legacy' => [
                    _member('q1', 1),
                    const AnswerCompletionMember.legacy('q2')
                  ],
                _ => [
                    _member('q1', 1),
                    const AnswerCompletionMember.corrupt('q2')
                  ],
              })
            ], ungrouped: []);
      await expectLater(
          binding.activation.startSession(
              targetScope: binding.scope, supplementalFileId: 'file'),
          throwsA(isA<SupplementalAnswerException>().having((e) => e.failure,
              'safe failure', SupplementalAnswerFailure.targetUnavailable)));
      expect(artifacts.calls, 0);
    });
  }

  test('empty/mixed/ineligible set cannot bind; caller cannot substitute scope',
      () async {
    final selected = _set([_member('q1', 1)]);
    final query =
        _Query(AnswerCompletionSnapshot(sets: [selected], ungrouped: []));
    final artifacts = _Artifacts();
    final service = AnswerCompletionSupplementalService(
        query: query,
        fileCatalog: _Catalog(),
        artifactPort: artifacts,
        ingestion: _Ingestion());
    for (final members in <List<AnswerCompletionMember>>[
      [],
      [const AnswerCompletionMember.legacy('q1')],
      [_member('q1', 1), const AnswerCompletionMember.corrupt('q2')]
    ]) {
      expect(() => service.bind(_set(members)),
          throwsA(isA<SupplementalAnswerException>()));
    }
    final binding = service.bind(selected);
    for (final scope in [
      const QuestionBankScope(bankName: 'bank'),
      ExplicitQuestionScope(storageIds: ['other'])
    ]) {
      await expectLater(
          binding.activation
              .startSession(targetScope: scope, supplementalFileId: 'file'),
          throwsA(isA<SupplementalAnswerException>()));
    }
    expect(artifacts.calls, 0);
  });
}
