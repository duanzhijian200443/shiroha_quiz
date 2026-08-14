import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  group('SupplementalAnswerOrigin construction invariants', () {
    test('freezes bounded ids, positive revision, bound ordered refs, evidence',
        () {
      final origin = _supplemental(
        artifactRevision: 2,
        evidence: const [MatchEvidenceCode.uniqueMainNumber],
      );
      expect(origin.supplementalFileId, 'file_001');
      expect(origin.artifactId, 'artifact_001');
      expect(origin.artifactRevision, 2);
      expect(origin.supplementalSourceRefs, hasLength(1));
      expect(origin.supplementalSourceRefs.single.sourceId, 'artifact_001');
      expect(
        origin.matchEvidence,
        const [MatchEvidenceCode.uniqueMainNumber],
      );
    });

    test('rejects invalid supplementalFileId', () {
      expect(
        () => _supplemental(supplementalFileId: 'has space'),
        throwsFormatException,
      );
      expect(
        () => _supplemental(supplementalFileId: ''),
        throwsFormatException,
      );
    });

    test('rejects invalid artifactId', () {
      expect(
        () => _supplemental(artifactId: 'bad/artifact'),
        throwsFormatException,
      );
    });

    test('rejects non-positive artifact revision', () {
      expect(
        () => _supplemental(artifactRevision: 0),
        throwsFormatException,
      );
      expect(
        () => _supplemental(artifactRevision: -1),
        throwsFormatException,
      );
    });

    test('rejects empty source refs', () {
      expect(
        () => _supplemental(sourceRefs: const <SourceRef>[]),
        throwsFormatException,
      );
    });

    test('rejects source refs that leave the bound artifact', () {
      expect(
        () => _supplemental(
          sourceRefs: [
            SourceRef.document(sourceId: 'artifact_other'),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => _supplemental(
          sourceRefs: [
            SourceRef.document(sourceId: 'artifact_001'),
            SourceRef.document(sourceId: 'artifact_other'),
          ],
        ),
        throwsFormatException,
      );
    });

    test('defensively copies both lists', () {
      final refs = [
        SourceRef.document(sourceId: 'artifact_001'),
        SourceRef.document(sourceId: 'artifact_001'),
      ];
      final evidence = [MatchEvidenceCode.uniqueMainNumber];
      final origin = _supplemental(
        sourceRefs: refs,
        evidence: evidence,
      );
      refs.add(SourceRef.document(sourceId: 'artifact_001'));
      evidence.add(MatchEvidenceCode.noLocator);
      expect(origin.supplementalSourceRefs, hasLength(2));
      expect(origin.matchEvidence, hasLength(1));
      expect(
        () => origin.supplementalSourceRefs.add(
          SourceRef.document(sourceId: 'artifact_001'),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => origin.matchEvidence.add(MatchEvidenceCode.noLocator),
        throwsUnsupportedError,
      );
    });
  });

  group('AiAnswerOrigin minimal seam', () {
    test('freezes bounded generation provenance in UTC', () {
      final origin = AiAnswerOrigin(
        generationId: 'gen_001',
        providerProfileId: 'profile_alpha',
        generatedAtUtc: DateTime.utc(2026, 8, 13, 12),
      );
      expect(origin.generationId, 'gen_001');
      expect(origin.providerProfileId, 'profile_alpha');
      expect(origin.generatedAtUtc.isUtc, isTrue);
    });

    test('rejects invalid bounded identities and non-UTC instants', () {
      expect(
        () => AiAnswerOrigin(
          generationId: 'bad gen',
          providerProfileId: 'profile_alpha',
          generatedAtUtc: DateTime.utc(2026),
        ),
        throwsFormatException,
      );
      expect(
        () => AiAnswerOrigin(
          generationId: 'gen_001',
          providerProfileId: 'bad profile',
          generatedAtUtc: DateTime.utc(2026),
        ),
        throwsFormatException,
      );
      expect(
        () => AiAnswerOrigin(
          generationId: 'gen_001',
          providerProfileId: 'profile_alpha',
          generatedAtUtc: DateTime(2026, 8, 13),
        ),
        throwsFormatException,
      );
    });

    test('has stable value semantics', () {
      final left = AiAnswerOrigin(
        generationId: 'gen_001',
        providerProfileId: 'profile_alpha',
        generatedAtUtc: DateTime.utc(2026, 8, 13, 12),
      );
      final right = AiAnswerOrigin(
        generationId: 'gen_001',
        providerProfileId: 'profile_alpha',
        generatedAtUtc: DateTime.utc(2026, 8, 13, 12),
      );
      final differentInstant = AiAnswerOrigin(
        generationId: 'gen_001',
        providerProfileId: 'profile_alpha',
        generatedAtUtc: DateTime.utc(2026, 8, 13, 13),
      );
      expect(left, right);
      expect(left.hashCode, right.hashCode);
      expect(left == differentInstant, isFalse);
      expect(
        left ==
            AiAnswerOrigin(
              generationId: 'gen_002',
              providerProfileId: 'profile_alpha',
              generatedAtUtc: DateTime.utc(2026, 8, 13, 12),
            ),
        isFalse,
      );
    });
  });

  group('AnswerCandidate common value semantics', () {
    test('binds target, answer, intent and origin', () {
      final draft = _draft();
      final candidate = _candidate(draft);
      expect(candidate.candidateId, 'candidate_001');
      expect(candidate.targetStorageId, 'question_001');
      expect(candidate.targetBankName, 'bank_math');
      expect(candidate.expectedDraft, draft);
      expect(candidate.answer, ContentAnswer(content: _text('x = 2')));
      final explanation = candidate.reviewOnlyExplanation!;
      expect(explanation.nodes, hasLength(1));
      expect((explanation.nodes.single as TextNode).text, 'explanation');
      expect(candidate.writeIntent, CandidateWriteIntent.fill);
      expect(candidate.origin, isA<SupplementalAnswerOrigin>());
    });

    test('rejects invalid candidate ids and target ids', () {
      expect(
        () => _candidate(
          _draft(),
          candidateId: 'bad candidate',
        ),
        throwsFormatException,
      );
      expect(
        () => _candidate(
          _draft(),
          targetStorageId: 'bad target',
        ),
        throwsFormatException,
      );
    });

    test('same common fields and same origin are equal', () {
      final draft = _draft();
      expect(_candidate(draft), _candidate(draft));
      expect(_candidate(draft).hashCode, _candidate(draft).hashCode);
    });

    test('different producer origin type is never equal', () {
      final draft = _draft();
      final supplemental = _candidate(draft);
      final ai = AnswerCandidate(
        candidateId: supplemental.candidateId,
        targetStorageId: supplemental.targetStorageId,
        targetBankName: supplemental.targetBankName,
        expectedDraft: draft,
        answer: supplemental.answer,
        reviewOnlyExplanation: supplemental.reviewOnlyExplanation,
        writeIntent: supplemental.writeIntent,
        origin: AiAnswerOrigin(
          generationId: 'gen_001',
          providerProfileId: 'profile_alpha',
          generatedAtUtc: DateTime.utc(2026, 8, 13, 12),
        ),
      );
      expect(supplemental == ai, isFalse);
      expect(supplemental.hashCode == ai.hashCode, isFalse);
    });

    test('common field drift changes equality and hash', () {
      final draft = _draft();
      final base = _candidate(draft);
      AnswerCandidate variant(QuestionDraftV2 expectedDraft) {
        return AnswerCandidate(
          candidateId: base.candidateId,
          targetStorageId: base.targetStorageId,
          targetBankName: base.targetBankName,
          expectedDraft: expectedDraft,
          answer: base.answer,
          reviewOnlyExplanation: base.reviewOnlyExplanation,
          writeIntent: base.writeIntent,
          origin: _supplemental(),
        );
      }

      expect(base == variant(draft), isTrue);
      expect(
        base ==
            variant(
              QuestionDraftV2(
                questionId: 'question_001',
                kind: QuestionKind.shortAnswer,
                questionNumber: 1,
                stem: _text('different stem'),
              ),
            ),
        isFalse,
      );
    });
  });

  group('Supplemental origin drives candidate equality', () {
    test('different artifactId is never equal', () {
      final draft = _draft();
      expect(
        _candidate(draft) == _candidate(draft, artifactId: 'artifact_002'),
        isFalse,
      );
    });

    test('different artifact revision is never equal', () {
      final draft = _draft();
      expect(
        _candidate(draft) == _candidate(draft, artifactRevision: 3),
        isFalse,
      );
    });

    test('different source refs are never equal', () {
      final draft = _draft();
      expect(
        _candidate(draft) ==
            _candidate(
              draft,
              sourceRefs: [
                SourceRef.document(sourceId: 'artifact_001'),
                SourceRef.document(sourceId: 'artifact_001'),
              ],
            ),
        isFalse,
      );
    });

    test('different match evidence is never equal', () {
      final draft = _draft();
      expect(
        _candidate(draft) ==
            _candidate(
              draft,
              evidence: const [MatchEvidenceCode.duplicateLocator],
            ),
        isFalse,
      );
    });

    test('hash agrees with equality across all origin fields', () {
      final draft = _draft();
      final base = _candidate(draft);
      expect(
        base.hashCode == _candidate(draft, artifactId: 'artifact_002').hashCode,
        isFalse,
      );
      expect(
        base.hashCode == _candidate(draft, artifactRevision: 3).hashCode,
        isFalse,
      );
      expect(
        base.hashCode ==
            _candidate(
              draft,
              sourceRefs: [
                SourceRef.document(sourceId: 'artifact_001'),
                SourceRef.document(sourceId: 'artifact_001'),
              ],
            ).hashCode,
        isFalse,
      );
      expect(
        base.hashCode ==
            _candidate(
              draft,
              evidence: const [MatchEvidenceCode.duplicateLocator],
            ).hashCode,
        isFalse,
      );
    });
  });
}

SupplementalAnswerOrigin _supplemental({
  String supplementalFileId = 'file_001',
  String artifactId = 'artifact_001',
  int artifactRevision = 1,
  List<SourceRef>? sourceRefs,
  List<MatchEvidenceCode> evidence = const [
    MatchEvidenceCode.uniqueMainNumber,
  ],
}) {
  return SupplementalAnswerOrigin(
    supplementalFileId: supplementalFileId,
    artifactId: artifactId,
    artifactRevision: artifactRevision,
    supplementalSourceRefs:
        sourceRefs ?? [SourceRef.document(sourceId: artifactId)],
    matchEvidence: evidence,
  );
}

AnswerCandidate _candidate(
  QuestionDraftV2 draft, {
  String candidateId = 'candidate_001',
  String targetStorageId = 'question_001',
  String targetBankName = 'bank_math',
  String artifactId = 'artifact_001',
  int artifactRevision = 1,
  List<SourceRef>? sourceRefs,
  List<MatchEvidenceCode> evidence = const [
    MatchEvidenceCode.uniqueMainNumber,
  ],
}) {
  return AnswerCandidate(
    candidateId: candidateId,
    targetStorageId: targetStorageId,
    targetBankName: targetBankName,
    expectedDraft: draft,
    answer: ContentAnswer(content: _text('x = 2')),
    reviewOnlyExplanation: _text('explanation'),
    writeIntent: CandidateWriteIntent.fill,
    origin: _supplemental(
      artifactId: artifactId,
      artifactRevision: artifactRevision,
      sourceRefs: sourceRefs,
      evidence: evidence,
    ),
  );
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
