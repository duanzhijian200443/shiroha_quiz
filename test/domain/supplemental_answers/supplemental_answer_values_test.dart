import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_match_record.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_fragment.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_scope.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/target_coverage.dart';

void main() {
  group('SupplementalAnswerMatchRequest', () {
    test('freezes one explicit scope plus one supplemental file', () {
      final request = SupplementalAnswerMatchRequest(
        targetScope: const QuestionBankScope(bankName: 'bank_math'),
        supplementalFileId: 'file_001',
      );
      expect(request.supplementalFileId, 'file_001');
      expect(
        request.targetScope,
        const QuestionBankScope(bankName: 'bank_math'),
      );
      expect(
        request,
        SupplementalAnswerMatchRequest(
          targetScope: const QuestionBankScope(bankName: 'bank_math'),
          supplementalFileId: 'file_001',
        ),
      );
    });

    test('explicit scope preserves caller order and rejects empty subsets', () {
      final scope = ExplicitQuestionScope(
        storageIds: ['q_2', 'q_1', 'q_3'],
      );
      expect(scope.storageIds, ['q_2', 'q_1', 'q_3']);
      expect(
        () => ExplicitQuestionScope(storageIds: const <String>[]),
        throwsFormatException,
      );
    });
  });

  group('SupplementalAnswerFragment', () {
    test('requires non-empty answer content and single-source refs', () {
      final fragment = SupplementalAnswerFragment(
        fragmentId: 'fragment_001',
        normalizedMainNumber: '1',
        normalizedSubquestion: '2',
        answerContent: _text('x = 2'),
        explanationContent: _text('explanation'),
        headingContext: [_text('answer section')],
        sourceRefs: [
          SourceRef.at(
            sourceId: 'artifact_001',
            point: SourcePoint.page(pageNumber: 1),
          ),
        ],
        sequencePosition: const SupplementalSequencePosition(
          partIndex: 0,
          continuationOrdinal: 0,
        ),
        stemContext: _text('solve x'),
      );
      expect(fragment.normalizedMainNumber, '1');
      expect(fragment.normalizedSubquestion, '2');
      expect(fragment.sourceRefs.single.sourceId, 'artifact_001');

      expect(
        () => SupplementalAnswerFragment(
          fragmentId: 'fragment_empty',
          answerContent: RichContent(nodes: const <ContentNode>[]),
          sourceRefs: [
            SourceRef.document(sourceId: 'artifact_001'),
          ],
          sequencePosition: const SupplementalSequencePosition(
            partIndex: 0,
            continuationOrdinal: 0,
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => SupplementalAnswerFragment(
          fragmentId: 'fragment_mixed',
          answerContent: _text('x = 2'),
          sourceRefs: [
            SourceRef.document(sourceId: 'artifact_001'),
            SourceRef.document(sourceId: 'artifact_002'),
          ],
          sequencePosition: const SupplementalSequencePosition(
            partIndex: 0,
            continuationOrdinal: 0,
          ),
        ),
        throwsFormatException,
      );
    });
  });

  group('AnswerCandidate', () {
    test('binds target, typed answer, and a Supplemental origin', () {
      final draft = _draft();
      final candidate = AnswerCandidate(
        candidateId: 'candidate_001',
        targetStorageId: 'question_001',
        targetBankName: 'bank_math',
        expectedDraft: draft,
        answer: ContentAnswer(content: _text('x = 2')),
        writeIntent: CandidateWriteIntent.fill,
        origin: SupplementalAnswerOrigin(
          supplementalFileId: 'file_001',
          artifactId: 'artifact_001',
          artifactRevision: 2,
          supplementalSourceRefs: [
            SourceRef.document(sourceId: 'artifact_001'),
          ],
          matchEvidence: const [MatchEvidenceCode.uniqueMainNumber],
        ),
      );
      expect(candidate.targetStorageId, 'question_001');
      expect(candidate.writeIntent, CandidateWriteIntent.fill);
      final origin = candidate.origin as SupplementalAnswerOrigin;
      expect(origin.supplementalFileId, 'file_001');
      expect(origin.artifactId, 'artifact_001');
      expect(origin.artifactRevision, 2);
      expect(
        candidate,
        AnswerCandidate(
          candidateId: 'candidate_001',
          targetStorageId: 'question_001',
          targetBankName: 'bank_math',
          expectedDraft: draft,
          answer: ContentAnswer(content: _text('x = 2')),
          writeIntent: CandidateWriteIntent.fill,
          origin: SupplementalAnswerOrigin(
            supplementalFileId: 'file_001',
            artifactId: 'artifact_001',
            artifactRevision: 2,
            supplementalSourceRefs: [
              SourceRef.document(sourceId: 'artifact_001'),
            ],
            matchEvidence: const [MatchEvidenceCode.uniqueMainNumber],
          ),
        ),
      );
    });

    test('Supplemental origin rejects refs that leave the bound artifact', () {
      expect(
        () => SupplementalAnswerOrigin(
          supplementalFileId: 'file_001',
          artifactId: 'artifact_001',
          artifactRevision: 1,
          supplementalSourceRefs: [
            SourceRef.document(sourceId: 'artifact_other'),
          ],
          matchEvidence: const [MatchEvidenceCode.uniqueMainNumber],
        ),
        throwsFormatException,
      );
    });

    test('Supplemental origin rejects non-positive artifact revision', () {
      expect(
        () => SupplementalAnswerOrigin(
          supplementalFileId: 'file_001',
          artifactId: 'artifact_001',
          artifactRevision: 0,
          supplementalSourceRefs: [
            SourceRef.document(sourceId: 'artifact_001'),
          ],
          matchEvidence: const [MatchEvidenceCode.uniqueMainNumber],
        ),
        throwsFormatException,
      );
    });
  });

  group('AnswerMatchRecord and TargetCoverage', () {
    test('matched record carries deterministic certainty', () {
      final record = AnswerMatchRecord(
        fragmentId: 'fragment_001',
        disposition: AnswerMatchDisposition.matched,
        certainty: MatchCertainty.deterministic,
        evidence: const [MatchEvidenceCode.uniqueMainNumber],
      );
      expect(record.disposition, AnswerMatchDisposition.matched);
      expect(record.certainty, MatchCertainty.deterministic);
      expect(record.candidate, isNull);
    });

    test('uncovered is target-side and distinct from unmatched', () {
      final coverage = TargetCoverage(
        storageId: 'question_001',
        bankName: 'bank_math',
        status: TargetCoverageStatus.uncovered,
      );
      expect(coverage.status, TargetCoverageStatus.uncovered);
      expect(
        coverage,
        TargetCoverage(
          storageId: 'question_001',
          bankName: 'bank_math',
          status: TargetCoverageStatus.uncovered,
        ),
      );
      expect(coverage.status.name, 'uncovered');
      expect(AnswerMatchDisposition.unmatched.name, 'unmatched');
    });
  });
}

QuestionDraftV2 _draft() {
  return QuestionDraftV2(
    questionId: 'question_001',
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: _text('solve x'),
    sourceRefs: [
      SourceRef.document(sourceId: 'artifact_001'),
    ],
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}
