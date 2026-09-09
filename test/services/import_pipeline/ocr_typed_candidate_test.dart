// R7B unit contract for the shadow typed candidate contract, batch builder
// and all-or-nothing final gate. Synthetic fixtures only; the harness has no
// Provider, Replay, network, database, UI, filesystem or application call
// site, so Provider calls are 0 by construction.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/content/rich_content_limits.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_extractor.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_entry.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_merger.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';

const _sourceUuid = '11111111-1111-4111-8111-111111111111';
const _questionUuidA = '22222222-2222-4222-8222-222222222222';
const _questionUuidB = '33333333-3333-4333-8333-333333333333';
const _reviewUuidA = '44444444-4444-4444-8444-444444444444';
const _reviewUuidB = '55555555-5555-4555-8555-555555555555';

const _regionizer = OcrQuestionRegionizer();
const _assembler = OcrQuestionAssembler();

void main() {
  group('fixed reason serialization', () {
    test('every failure maps to exactly one fixed lower_snake_case reason', () {
      expect(
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.unsupportedStructure,
        ),
        'typed_candidate_unsupported_structure',
      );
      expect(
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.projectionUnsupported,
        ),
        'typed_candidate_projection_unsupported',
      );
      expect(
        ocrTypedCandidateFailureReason(OcrTypedCandidateFailure.repairApplied),
        'typed_candidate_repair_applied',
      );
      expect(
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.projectionMismatch,
        ),
        'typed_candidate_projection_mismatch',
      );
      expect(
        ocrTypedCandidateFailureReason(OcrTypedCandidateFailure.countMismatch),
        'typed_candidate_count_mismatch',
      );
      expect(
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.identityMismatch,
        ),
        'typed_candidate_identity_mismatch',
      );
      expect(
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.baselineInvalid,
        ),
        'typed_candidate_baseline_invalid',
      );
      expect(
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.rawExplanationDiverged,
        ),
        'typed_candidate_raw_explanation_diverged',
      );
      expect(
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.snapshotInvalid,
        ),
        'typed_candidate_snapshot_invalid',
      );
      expect(
        ocrTypedCandidateFailureReason(OcrTypedCandidateFailure.notSingleFile),
        'typed_candidate_not_single_file',
      );
      expect(
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.internalError,
        ),
        'typed_candidate_internal_error',
      );
      for (final failure in OcrTypedCandidateFailure.values) {
        final reason = ocrTypedCandidateFailureReason(failure);
        expect(isValidImportStorageReason(reason), isTrue,
            reason: 'reason for $failure must be a bounded scalar');
      }
    });
  });

  group('candidate generation', () {
    test('a supported single-file document yields one typed candidate', () {
      final document = _shortAnswerDocument();
      final regionized = _regionizer.regionize(document);
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: _legacyQuestions(regionized.regions),
        uuidV4Factory: _uuidSequence(),
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      final candidate = batch.candidates.single;
      expect(candidate.questionNumber, 1);
      expect(candidate.reviewItemId, _reviewUuidA);
      expect(candidate.questionId, _questionUuidA);
      expect(candidate.draft.questionId, candidate.questionId);
      expect(candidate.draft.questionNumber, 1);
      expect(isCanonicalUuidV4(candidate.reviewItemId), isTrue);
      expect(isCanonicalUuidV4(candidate.questionId), isTrue);
      expect(
        isCanonicalUuidV4(candidate.draft.sourceRefs.first.sourceId),
        isTrue,
      );
      expect(candidate.draft.sourceRefs.first.displayLabel, isNull);
      expect(
        candidate.projectedLegacy,
        LegacyReviewBaseline(
          type: 3,
          questionNumber: 1,
          content: 'Synthetic prompt marker 1.',
          options: const <String>[],
          standardAnswer: 'synthetic-result-1',
          explanation: 'Synthetic explanation 1',
        ),
      );
      expect(candidate.sourcePageIndices, <int>[1]);
      expect(
        candidate.sourceBlockIds,
        <String>['q_1', 'answer_1', 'explanation_1'],
      );
    });

    test('multiple questions produce unique canonical identities', () {
      final document = _twoQuestionDocument();
      final regionized = _regionizer.regionize(document);
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: _legacyQuestions(regionized.regions),
        uuidV4Factory: _uuidSequence(),
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(2));
      expect(
        batch.candidates.map((candidate) => candidate.reviewItemId).toSet(),
        hasLength(2),
      );
      expect(
        batch.candidates.map((candidate) => candidate.questionId).toSet(),
        hasLength(2),
      );
      expect(
        batch.candidates.map((candidate) => candidate.questionNumber).toList(),
        <int>[1, 2],
      );
      for (final candidate in batch.candidates) {
        expect(isCanonicalUuidV4(candidate.reviewItemId), isTrue);
        expect(isCanonicalUuidV4(candidate.questionId), isTrue);
        expect(candidate.draft.questionId, candidate.questionId);
      }
    });

    test('reference-answer merged regions can generate candidates', () {
      final document = _referenceAnswerDocument();
      final regionized = _regionizer.regionize(document);
      final index = const ReferenceAnswerExtractor().extract(
        document,
        regionized.regions,
      );
      final merged = const ReferenceAnswerMerger().merge(
        regionized.regions,
        index,
      );
      expect(merged, hasLength(2));
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: merged,
        legacyQuestions: _legacyQuestions(merged),
        uuidV4Factory: _uuidSequence(),
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(2));
      final candidate = batch.candidates.first;
      expect(
        candidate.draft.issues.map((issue) => issue.code),
        contains('reference_answer_attached'),
        reason: 'typed issues are preserved on the candidate draft',
      );
      expect(candidate.draft.sourceRefs, hasLength(3),
          reason: 'typed source refs are preserved on the candidate draft');
    });

    test(
        'conflicting multi-block reference evidence preserves local answer '
        'and reaches typedV2', () {
      final document = _document(
        'q21_reference_ownership.pdf',
        <OcrPage>[
          OcrPage(
            pageIndex: 1,
            blocks: <OcrBlock>[
              _block('question_block', 1, 0, 'Synthetic prompt marker 21.'),
              _block('local_answer', 1, 1, 'Local authoritative answer'),
            ],
          ),
          OcrPage(
            pageIndex: 2,
            blocks: <OcrBlock>[
              _block('reference_block_1', 2, 0, 'Reference evidence one'),
              _block('reference_block_2', 2, 1, 'Reference evidence two'),
              _block('reference_block_3', 2, 2, 'Reference evidence three'),
            ],
          ),
        ],
      );
      final merged = const ReferenceAnswerMerger().merge(
        const <OcrQuestionRegion>[
          OcrQuestionRegion(
            number: 21,
            stemParts: <String>['Synthetic prompt marker 21.'],
            answerParts: <String>['Local authoritative answer'],
            explanationParts: <String>[],
            sourcePageIndices: <int>[1],
            sourceBlockIds: <String>['question_block', 'local_answer'],
            diagnostics: <String>[],
            declaredKind: TextQuestionKind.subjective,
            ownedSources: <OcrQuestionRegionSource>[
              OcrQuestionRegionSource(
                blockId: 'question_block',
                field: OcrRegionField.stem,
                text: 'Synthetic prompt marker 21.',
              ),
              OcrQuestionRegionSource(
                blockId: 'local_answer',
                field: OcrRegionField.answer,
                text: 'Local authoritative answer',
              ),
            ],
          ),
        ],
        ReferenceAnswerIndex(
          entries: <int, ReferenceAnswerEntry>{
            21: ReferenceAnswerEntry(
              questionNumber: 21,
              answerText: 'Different reference answer',
              sourcePageIndices: <int>[2],
              sourceBlockIds: <String>[
                'reference_block_1',
                'reference_block_2',
                'reference_block_3',
              ],
              patternKind: 'explicit_numbered',
            ),
          },
          conflictedNumbers: <int>{},
          diagnostics: <String, dynamic>{},
        ),
      ).single;
      final legacyQuestions = _legacyQuestions(<OcrQuestionRegion>[merged]);
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: <OcrQuestionRegion>[merged],
        legacyQuestions: legacyQuestions,
        uuidV4Factory: _uuidSequence(),
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      expect(
        batch.candidates.single.projectedLegacy.standardAnswer,
        legacyQuestions.single['standard_answer'],
      );
      expect(
        batch.candidates.single.sourceBlockIds,
        const <String>[
          'question_block',
          'local_answer',
          'reference_block_1',
          'reference_block_2',
          'reference_block_3',
        ],
      );

      final result = applyOcrTypedCandidateGate(
        batch: batch,
        finalQuestions: legacyQuestions,
        singleFile: true,
      );
      expect(result.route, ImportStorageRoute.typedV2, reason: result.reason);
      expect(result.reason, ocrTypedCandidateReadyReason);
    });

    test('attached multi-block reference answer is materialized exactly once',
        () {
      final document = _document(
        'attached_reference_ownership.pdf',
        <OcrPage>[
          OcrPage(
            pageIndex: 1,
            blocks: <OcrBlock>[
              _block('question_block', 1, 0, 'Synthetic prompt marker 22.'),
            ],
          ),
          OcrPage(
            pageIndex: 2,
            blocks: <OcrBlock>[
              _block('reference_block_1', 2, 0, 'Reference evidence one'),
              _block('reference_block_2', 2, 1, 'Reference evidence two'),
              _block('reference_block_3', 2, 2, 'Reference evidence three'),
            ],
          ),
        ],
      );
      final merged = const ReferenceAnswerMerger().merge(
        const <OcrQuestionRegion>[
          OcrQuestionRegion(
            number: 22,
            stemParts: <String>['Synthetic prompt marker 22.'],
            answerParts: <String>[],
            explanationParts: <String>[],
            sourcePageIndices: <int>[1],
            sourceBlockIds: <String>['question_block'],
            diagnostics: <String>['missing_answer'],
            declaredKind: TextQuestionKind.subjective,
            ownedSources: <OcrQuestionRegionSource>[
              OcrQuestionRegionSource(
                blockId: 'question_block',
                field: OcrRegionField.stem,
                text: 'Synthetic prompt marker 22.',
              ),
            ],
          ),
        ],
        ReferenceAnswerIndex(
          entries: <int, ReferenceAnswerEntry>{
            22: ReferenceAnswerEntry(
              questionNumber: 22,
              answerText: 'Authoritative reference answer',
              sourcePageIndices: <int>[2],
              sourceBlockIds: <String>[
                'reference_block_1',
                'reference_block_2',
                'reference_block_3',
              ],
              patternKind: 'explicit_numbered',
            ),
          },
          conflictedNumbers: <int>{},
          diagnostics: <String, dynamic>{},
        ),
      ).single;
      final legacyQuestions = _legacyQuestions(<OcrQuestionRegion>[merged]);
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: <OcrQuestionRegion>[merged],
        legacyQuestions: legacyQuestions,
        uuidV4Factory: _uuidSequence(),
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      expect(
        batch.candidates.single.projectedLegacy.standardAnswer,
        'Authoritative reference answer',
      );
      expect(
        batch.candidates.single.projectedLegacy.standardAnswer,
        legacyQuestions.single['standard_answer'],
      );
      expect(
        batch.candidates.single.sourceBlockIds,
        const <String>[
          'question_block',
          'reference_block_1',
          'reference_block_2',
          'reference_block_3',
        ],
      );

      final result = applyOcrTypedCandidateGate(
        batch: batch,
        finalQuestions: legacyQuestions,
        singleFile: true,
      );
      expect(result.route, ImportStorageRoute.typedV2, reason: result.reason);
      expect(result.reason, ocrTypedCandidateReadyReason);
    });

    test('ASCII choice production chain reaches typedV2 under allQuestionTypes',
        () {
      final document = _asciiChoiceDocument();
      final region = _asciiChoiceRegion();
      final finalQuestion = const ImportQuestionFieldPolicy().applyToMap(
        _assembler.assemble(region).question,
        mode: ExplanationRetentionMode.allQuestionTypes,
      );
      final finalQuestions = <Map<String, dynamic>>[finalQuestion];

      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: <OcrQuestionRegion>[region],
        legacyQuestions: finalQuestions,
        uuidV4Factory: _uuidSequence(),
        explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      final candidate = batch.candidates.single;
      expect(finalQuestion['raw_explanation'], isNotEmpty);
      expect(finalQuestion['explanation'], isNotEmpty);
      expect(candidate.draft.options, hasLength(4));
      expect(candidate.draft.explanation, isNotNull);
      expect(candidate.projectedLegacy.options, <String>[
        'A. 甲',
        'B. 乙',
        'C. 丙',
        'D. 丁',
      ]);
      expect(candidate.projectedLegacy.content, finalQuestion['content']);
      expect(candidate.projectedLegacy.explanation, isNotEmpty);

      final result = applyOcrTypedCandidateGate(
        batch: batch,
        finalQuestions: finalQuestions,
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.typedV2, reason: result.reason);
      expect(result.reason, ocrTypedCandidateReadyReason);
    });

    test('ai_repair_applied makes the whole batch ineligible', () {
      final document = _shortAnswerDocument();
      final regionized = _regionizer.regionize(document);
      final repaired = <String, dynamic>{
        ..._legacyQuestions(regionized.regions).single,
        'diagnostics': <String>['ai_repair_applied'],
      };
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: <Map<String, dynamic>>[repaired],
        uuidV4Factory: _uuidSequence(),
      );

      expect(batch.candidates, isEmpty);
      expect(batch.failure, OcrTypedCandidateFailure.repairApplied);
    });

    test('repair attempted but unchanged is not a batch failure', () {
      final document = _shortAnswerDocument();
      final regionized = _regionizer.regionize(document);
      final unchanged = <String, dynamic>{
        ..._legacyQuestions(regionized.regions).single,
        'diagnostics': <String>['repair_failed'],
      };
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: <Map<String, dynamic>>[unchanged],
        uuidV4Factory: _uuidSequence(),
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
    });

    test('table structure makes the whole batch ineligible', () {
      final document = _tableDocument();
      final regionized = _regionizer.regionize(document);
      expect(regionized.regions, hasLength(1));
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: _legacyQuestions(regionized.regions),
        uuidV4Factory: _uuidSequence(),
      );

      expect(batch.candidates, isEmpty);
      expect(
        batch.failure,
        OcrTypedCandidateFailure.unsupportedStructure,
      );
    });

    test('merged explanation table keeps parity and reaches typedV2', () {
      final document = _mergedExplanationTableDocument();
      final region = _mergedExplanationTableRegion();
      expect(
        region.ownedSources
            .where((source) => source.blockId == 'explanation_table')
            .single
            .field,
        OcrRegionField.explanation,
      );
      final legacyQuestions = _legacyQuestions(<OcrQuestionRegion>[region]);
      expect(
        legacyQuestions.single['explanation'],
        'A | | B\n | | C',
      );

      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: <OcrQuestionRegion>[region],
        legacyQuestions: legacyQuestions,
        uuidV4Factory: _uuidSequence(),
      );
      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      final table =
          batch.candidates.single.draft.explanation!.nodes.single as TableNode;
      expect(table.structure.rows.first.cells.first.rowSpan, 2);
      expect(table.structure.rows.first.cells.first.columnSpan, 2);
      expect(
        batch.candidates.single.projectedLegacy.explanation,
        legacyQuestions.single['explanation'],
      );

      final result = applyOcrTypedCandidateGate(
        batch: batch,
        finalQuestions: legacyQuestions,
        singleFile: true,
      );
      expect(
        result.route,
        ImportStorageRoute.typedV2,
        reason: result.reason,
      );
      expect(result.reason, ocrTypedCandidateReadyReason);
      expect(
        result.questions.single['explanation'],
        'A | | B\n | | C',
      );
    });

    test('image and unknown structures make the whole batch ineligible', () {
      for (final type in <String>['image', 'chart']) {
        final document = _unsupportedTypeDocument(type);
        final regionized = _regionizer.regionize(document);
        final batch = buildOcrTypedCandidateBatch(
          document: document,
          regions: regionized.regions,
          legacyQuestions: _legacyQuestions(regionized.regions),
          uuidV4Factory: _uuidSequence(),
        );
        expect(batch.candidates, isEmpty, reason: 'block type $type');
        expect(
          batch.failure,
          OcrTypedCandidateFailure.unsupportedStructure,
          reason: 'block type $type',
        );
      }
    });

    test('unrelated unsupported blocks do not poison an owned typed region',
        () {
      final document = _document(
        'r7b_synthetic_unrelated_structure.pdf',
        <OcrPage>[
          OcrPage(
            pageIndex: 1,
            blocks: <OcrBlock>[
              _block(
                'unrelated_image',
                1,
                0,
                'decorative figure outside the questions',
                type: 'image',
              ),
              _block('section', 1, 1, '三、解答题'),
              _block('q_1', 1, 2, '1. Synthetic prompt marker 1.'),
              _block('answer_1', 1, 3, '答案：synthetic-result-1'),
              _block('explanation_1', 1, 4, '解析：Synthetic explanation 1'),
            ],
          ),
        ],
      );
      final regionized = _regionizer.regionize(document);
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: _legacyQuestions(regionized.regions),
        uuidV4Factory: _uuidSequence(),
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      expect(
        batch.candidates.single.sourceBlockIds,
        isNot(contains('unrelated_image')),
      );
    });

    test('candidate generation failure maps to a fixed failure only', () {
      final document = _shortAnswerDocument();
      final regionized = _regionizer.regionize(document);
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: _legacyQuestions(regionized.regions),
        uuidV4Factory: () => throw StateError('synthetic uuid failure'),
      );

      expect(batch.candidates, isEmpty);
      expect(batch.failure, OcrTypedCandidateFailure.internalError);
    });

    test('candidate collections are defensive copies', () {
      final document = _shortAnswerDocument();
      final regionized = _regionizer.regionize(document);
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: _legacyQuestions(regionized.regions),
        uuidV4Factory: _uuidSequence(),
      );
      final candidate = batch.candidates.single;

      expect(
        () => candidate.sourcePageIndices.add(99),
        throwsUnsupportedError,
      );
      expect(() => candidate.sourceBlockIds.add('x'), throwsUnsupportedError);
      expect(() => batch.candidates.add(candidate), throwsUnsupportedError);
    });
  });

  group('all-or-nothing gate', () {
    test('historical tasks without a route decode as legacyV1', () {
      expect(decodeImportStorageRoute(null), ImportStorageRoute.legacyV1);
      expect(decodeImportStorageRoute('legacyV1'), ImportStorageRoute.legacyV1);
    });

    test('an eligible batch attaches an envelope to every question', () {
      final candidates = <OcrTypedCandidate>[
        _candidate(
          questionNumber: 1,
          questionId: _questionUuidA,
          reviewItemId: _reviewUuidA,
        ),
      ];
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(candidates: candidates),
        finalQuestions: [_finalQuestion(number: 1)],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.typedV2);
      expect(result.reason, 'typed_candidate_ready');
      expect(result.questions, hasLength(1));
      final envelope = result.questions.single[TypedReviewSnapshotCodec.mapKey];
      expect(envelope, isA<Map<String, Object?>>());
      final decoded = const TypedReviewSnapshotCodec().decodeRequired(envelope);
      expect(decoded.reviewItemId, _reviewUuidA);
      expect(decoded.questionId, _questionUuidA);
      expect(
        decoded.baselineLegacy,
        _finalBaseline(number: 1),
      );
    });

    test('text-only parity remains eligible for every persisted type', () {
      final cases = <({
        QuestionKind kind,
        int type,
        List<QuestionOption> options,
        QuestionAnswer answer,
        List<String> legacyOptions,
        String legacyAnswer,
      })>[
        (
          kind: QuestionKind.singleChoice,
          type: 0,
          options: <QuestionOption>[
            QuestionOption(
              optionId: 'A',
              label: 'A',
              content: RichContent(
                nodes: <ContentNode>[const TextNode('Alpha')],
              ),
            ),
            QuestionOption(
              optionId: 'B',
              label: 'B',
              content: RichContent(
                nodes: <ContentNode>[const TextNode('Beta')],
              ),
            ),
          ],
          answer: ChoiceAnswer(optionIds: const <String>['A']),
          legacyOptions: <String>['A. Alpha', 'B. Beta'],
          legacyAnswer: 'A',
        ),
        (
          kind: QuestionKind.fillBlank,
          type: 2,
          options: <QuestionOption>[],
          answer: ContentAnswer(
            content: RichContent(
              nodes: <ContentNode>[const TextNode('synthetic-result-1')],
            ),
          ),
          legacyOptions: <String>[],
          legacyAnswer: 'synthetic-result-1',
        ),
        (
          kind: QuestionKind.shortAnswer,
          type: 3,
          options: <QuestionOption>[],
          answer: ContentAnswer(
            content: RichContent(
              nodes: <ContentNode>[const TextNode('synthetic-result-1')],
            ),
          ),
          legacyOptions: <String>[],
          legacyAnswer: 'synthetic-result-1',
        ),
      ];

      for (final fixture in cases) {
        final draft = QuestionDraftV2(
          questionId: _questionUuidA,
          kind: fixture.kind,
          questionNumber: 1,
          stem: RichContent(
            nodes: <ContentNode>[
              const TextNode('Synthetic prompt marker 1.'),
            ],
          ),
          options: fixture.options,
          answer: fixture.answer,
          explanation: RichContent(
            nodes: <ContentNode>[const TextNode('Synthetic explanation 1')],
          ),
        );
        final baseline = LegacyReviewBaseline(
          type: fixture.type,
          questionNumber: 1,
          content: 'Synthetic prompt marker 1.',
          options: fixture.legacyOptions,
          standardAnswer: fixture.legacyAnswer,
          explanation: 'Synthetic explanation 1',
        );
        final question = _finalQuestion(number: 1)
          ..['type'] = fixture.type
          ..['options'] = fixture.legacyOptions
          ..['standard_answer'] = fixture.legacyAnswer;
        final result = applyOcrTypedCandidateGate(
          batch: OcrTypedCandidateBatch(
            candidates: <OcrTypedCandidate>[
              _candidate(
                questionNumber: 1,
                questionId: _questionUuidA,
                reviewItemId: _reviewUuidA,
                draft: draft,
                projectedLegacy: baseline,
              ),
            ],
          ),
          finalQuestions: <Map<String, dynamic>>[question],
          singleFile: true,
        );

        expect(result.route, ImportStorageRoute.typedV2,
            reason: 'persisted type ${fixture.type}');
        expect(result.reason, ocrTypedCandidateReadyReason);
      }
    });

    test('multi-file requests never attach envelopes', () {
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
          ],
        ),
        finalQuestions: [_finalQuestion(number: 1)],
        singleFile: false,
      );

      expect(result.route, ImportStorageRoute.legacyV1);
      expect(result.reason, 'typed_candidate_not_single_file');
      expect(
        result.questions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
        isFalse,
      );
    });

    test('batch failure removes every envelope with its fixed reason', () {
      for (final failure in OcrTypedCandidateFailure.values) {
        final result = applyOcrTypedCandidateGate(
          batch: OcrTypedCandidateBatch(
            candidates: <OcrTypedCandidate>[],
            failure: failure,
          ),
          finalQuestions: [_finalQuestion(number: 1)],
          singleFile: true,
        );
        expect(result.route, ImportStorageRoute.legacyV1);
        expect(
          result.reason,
          ocrTypedCandidateFailureReason(failure),
        );
        expect(
          result.questions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
          isFalse,
        );
      }
    });

    test('count mismatch removes every envelope', () {
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[
          _finalQuestion(number: 1),
          _finalQuestion(number: 2),
        ],
        singleFile: true,
      );

      expect(result.reason, 'typed_candidate_count_mismatch');
      expect(
        result.questions.every(
          (question) => !question.containsKey(TypedReviewSnapshotCodec.mapKey),
        ),
        isTrue,
      );
    });

    test('duplicate or missing question numbers fail identity', () {
      final candidates = <OcrTypedCandidate>[
        _candidate(
          questionNumber: 1,
          questionId: _questionUuidA,
          reviewItemId: _reviewUuidA,
        ),
        _candidate(
          questionNumber: 2,
          questionId: _questionUuidB,
          reviewItemId: _reviewUuidB,
        ),
      ];
      final duplicateNumbers = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(candidates: candidates),
        finalQuestions: <Map<String, dynamic>>[
          _finalQuestion(number: 1),
          _finalQuestion(number: 1),
        ],
        singleFile: true,
      );
      expect(duplicateNumbers.reason, 'typed_candidate_identity_mismatch');

      final missingNumber = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(candidates: candidates),
        finalQuestions: <Map<String, dynamic>>[
          _finalQuestion(number: 1),
          _finalQuestion(number: 3),
        ],
        singleFile: true,
      );
      expect(missingNumber.reason, 'typed_candidate_identity_mismatch');
    });

    test('non-canonical or duplicate candidate ids fail identity', () {
      final nonCanonical = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: 'not-a-uuid',
              reviewItemId: _reviewUuidA,
            ),
          ],
        ),
        finalQuestions: [_finalQuestion(number: 1)],
        singleFile: true,
      );
      expect(nonCanonical.reason, 'typed_candidate_identity_mismatch');

      final duplicateIds = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
            _candidate(
              questionNumber: 2,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidB,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[
          _finalQuestion(number: 1),
          _finalQuestion(number: 2),
        ],
        singleFile: true,
      );
      expect(duplicateIds.reason, 'typed_candidate_identity_mismatch');
    });

    test('baseline shape anomalies fail the whole batch', () {
      final badType = _finalQuestion(number: 1)..['type'] = 1;
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[badType],
        singleFile: true,
      );
      expect(result.reason, 'typed_candidate_baseline_invalid');

      final nonStringOption = _finalQuestion(number: 1)
        ..['options'] = <Object?>['A. one', 42];
      final optionResult = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[nonStringOption],
        singleFile: true,
      );
      expect(optionResult.reason, 'typed_candidate_baseline_invalid');
    });

    test('raw_explanation null, empty and equal are allowed', () {
      for (final raw in <Object?>[null, '', 'Synthetic explanation 1']) {
        final question = _finalQuestion(number: 1)..['raw_explanation'] = raw;
        final result = applyOcrTypedCandidateGate(
          batch: OcrTypedCandidateBatch(
            candidates: <OcrTypedCandidate>[
              _candidate(
                questionNumber: 1,
                questionId: _questionUuidA,
                reviewItemId: _reviewUuidA,
              ),
            ],
          ),
          finalQuestions: <Map<String, dynamic>>[question],
          singleFile: true,
        );
        expect(result.reason, 'typed_candidate_ready',
            reason: 'raw_explanation $raw must be allowed');
      }
    });

    test('raw_explanation divergence fails the whole batch', () {
      final question = _finalQuestion(number: 1)
        ..['raw_explanation'] = 'Extra information not in explanation';
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[question],
        singleFile: true,
      );

      expect(result.reason, 'typed_candidate_raw_explanation_diverged');
      expect(
        result.questions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
        isFalse,
      );
    });

    test('TextNode-only N0 parity preserves the exact final baseline', () {
      const finalExplanation =
          '\u3000 \t\r\nSynthetic explanation 1\r \t\u3000';
      final question = _finalQuestion(number: 1)
        ..['explanation'] = finalExplanation
        ..['raw_explanation'] = '\t Synthetic explanation 1 \n';
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[question],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.typedV2);
      expect(result.reason, 'typed_candidate_ready');
      expect(result.questions.single['explanation'], finalExplanation);
      final envelope = result.questions.single[TypedReviewSnapshotCodec.mapKey];
      final snapshot =
          const TypedReviewSnapshotCodec().decodeRequired(envelope);
      expect(snapshot.baselineLegacy.explanation, finalExplanation);
    });

    test('internal CRLF and LF are equivalent under the bounded N0 rule', () {
      const finalExplanation = 'line one\r\nline two';
      const projectedExplanation = 'line one\nline two';
      final candidate = _candidate(
        questionNumber: 1,
        questionId: _questionUuidA,
        reviewItemId: _reviewUuidA,
        draft: _draftWithExplanation(
          questionNumber: 1,
          questionId: _questionUuidA,
          explanation: RichContent(
            nodes: <ContentNode>[TextNode(projectedExplanation)],
          ),
        ),
        projectedLegacy: _finalBaseline(
          number: 1,
          explanation: projectedExplanation,
        ),
      );
      final question = _finalQuestion(number: 1)
        ..['explanation'] = finalExplanation
        ..['raw_explanation'] = projectedExplanation;
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[candidate],
        ),
        finalQuestions: <Map<String, dynamic>>[question],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.typedV2);
      expect(result.reason, 'typed_candidate_ready');
      expect(result.questions.single['explanation'], finalExplanation);
      final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
        result.questions.single[TypedReviewSnapshotCodec.mapKey],
      );
      expect(snapshot.baselineLegacy.explanation, finalExplanation);
    });

    test('internal LF and blank-line-count changes fail the whole batch', () {
      const cases = <List<String>>[
        <String>['line one\nline two', 'line oneline two'],
        <String>['line oneline two', 'line one\nline two'],
        <String>['line one\n\nline two', 'line one\nline two'],
      ];

      for (final pair in cases) {
        final mismatchCandidate = _candidate(
          questionNumber: 1,
          questionId: _questionUuidA,
          reviewItemId: _reviewUuidA,
          draft: _draftWithExplanation(
            questionNumber: 1,
            questionId: _questionUuidA,
            explanation: RichContent(
              nodes: <ContentNode>[TextNode(pair[1])],
            ),
          ),
          projectedLegacy: _finalBaseline(
            number: 1,
            explanation: pair[1],
          ),
        );
        final result = applyOcrTypedCandidateGate(
          batch: OcrTypedCandidateBatch(
            candidates: <OcrTypedCandidate>[
              mismatchCandidate,
              _candidate(
                questionNumber: 2,
                questionId: _questionUuidB,
                reviewItemId: _reviewUuidB,
              ),
            ],
          ),
          finalQuestions: <Map<String, dynamic>>[
            _finalQuestion(number: 1)
              ..['explanation'] = pair[0]
              ..['raw_explanation'] = null,
            _finalQuestion(number: 2),
          ],
          singleFile: true,
        );

        expect(result.route, ImportStorageRoute.legacyV1);
        expect(result.reason, 'typed_candidate_projection_mismatch');
        expect(result.questions, hasLength(2));
        expect(
          result.questions.every(
            (question) =>
                !question.containsKey(TypedReviewSnapshotCodec.mapKey),
          ),
          isTrue,
          reason: 'one explanation mismatch must clear every batch envelope',
        );
      }
    });

    test('non-empty raw and empty final explanation fail before N0', () {
      final question = _finalQuestion(number: 1)
        ..['explanation'] = ''
        ..['raw_explanation'] = '\t';
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[question],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.legacyV1);
      expect(result.reason, 'typed_candidate_raw_explanation_diverged');
    });

    test('formula-like TextNode internal spacing remains strict', () {
      final finalExplanation = r'\text{a b}';
      final projectedExplanation = r'\text{a  b}';
      final candidate = _candidate(
        questionNumber: 1,
        questionId: _questionUuidA,
        reviewItemId: _reviewUuidA,
        draft: _draftWithExplanation(
          questionNumber: 1,
          questionId: _questionUuidA,
          explanation: RichContent(
            nodes: <ContentNode>[TextNode(projectedExplanation)],
          ),
        ),
        projectedLegacy: _finalBaseline(
          number: 1,
          explanation: projectedExplanation,
        ),
      );
      final question = _finalQuestion(number: 1)
        ..['explanation'] = finalExplanation
        ..['raw_explanation'] = null;
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[candidate],
        ),
        finalQuestions: <Map<String, dynamic>>[question],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.legacyV1);
      expect(result.reason, 'typed_candidate_projection_mismatch');
    });

    test('bounded math explanation can use N0 for a boundary difference', () {
      const projectedExplanation = 'x';
      final finalExplanation = '\t$projectedExplanation\n';
      final candidate = _candidate(
        questionNumber: 1,
        questionId: _questionUuidA,
        reviewItemId: _reviewUuidA,
        draft: _draftWithExplanation(
          questionNumber: 1,
          questionId: _questionUuidA,
          explanation: RichContent(
            nodes: <ContentNode>[InlineMathNode(projectedExplanation)],
          ),
        ),
        projectedLegacy: _finalBaseline(
          number: 1,
          explanation: projectedExplanation,
        ),
      );
      final question = _finalQuestion(number: 1)
        ..['explanation'] = finalExplanation
        ..['raw_explanation'] = projectedExplanation;
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[candidate],
        ),
        finalQuestions: <Map<String, dynamic>>[question],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.typedV2);
      expect(result.reason, ocrTypedCandidateReadyReason);
      expect(result.questions.single['explanation'], finalExplanation);
    });

    test('over-limit explanation pairs do not enter N0 comparison', () {
      final overLimit = List<String>.filled(
        RichContentLimits.maxProjectionScalars + 1,
        'x',
      ).join();
      final candidate = _candidate(
        questionNumber: 1,
        questionId: _questionUuidA,
        reviewItemId: _reviewUuidA,
        projectedLegacy: _finalBaseline(
          number: 1,
          explanation: overLimit,
        ),
      );
      final question = _finalQuestion(number: 1)
        ..['explanation'] = '$overLimit\n'
        ..['raw_explanation'] = null;
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[candidate],
        ),
        finalQuestions: <Map<String, dynamic>>[question],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.legacyV1);
      expect(result.reason, 'typed_candidate_projection_mismatch');
    });

    test('projection mismatches are strict and remove every envelope', () {
      OcrTypedCandidateGateResult runWith(Map<String, dynamic> question) {
        return applyOcrTypedCandidateGate(
          batch: OcrTypedCandidateBatch(
            candidates: <OcrTypedCandidate>[
              _candidate(
                questionNumber: 1,
                questionId: _questionUuidA,
                reviewItemId: _reviewUuidA,
              ),
            ],
          ),
          finalQuestions: <Map<String, dynamic>>[question],
          singleFile: true,
        );
      }

      expect(
        runWith(_finalQuestion(number: 1)..['content'] = 'Different content')
            .reason,
        'typed_candidate_projection_mismatch',
      );
      expect(
        runWith(
          _finalQuestion(number: 1)..['standard_answer'] = 'SYNTHETIC-RESULT-1',
        ).reason,
        'typed_candidate_projection_mismatch',
        reason: 'answer case is compared strictly',
      );
      expect(
        runWith(
          _finalQuestion(number: 1)
            ..['options'] = <String>[
              'B. two',
              'A. one',
            ],
        ).reason,
        'typed_candidate_projection_mismatch',
        reason: 'option order is compared strictly',
      );
      expect(
        runWith(
          _finalQuestion(number: 1)..['source_page_indices'] = <int>[2],
        ).reason,
        'typed_candidate_projection_mismatch',
      );
      expect(
        runWith(
          _finalQuestion(number: 1)
            ..['source_block_ids'] = <String>[
              'answer_1',
              'q_1',
              'explanation_1',
            ],
        ).reason,
        'typed_candidate_projection_mismatch',
      );
    });

    test('snapshot encode/decode self-check failures remove every envelope',
        () {
      final unsafeDraft = QuestionDraftV2(
        questionId: _questionUuidA,
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: RichContent(
          nodes: <ContentNode>[
            RawFallbackNode(<Object?, Object?>{
              'type': 'raw_fallback',
              'payload': <Object?, Object?>{'path': r'C:\private\fixture.pdf'},
            }),
          ],
        ),
      );
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
              draft: unsafeDraft,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[_finalQuestion(number: 1)],
        singleFile: true,
      );

      expect(result.reason, 'typed_candidate_snapshot_invalid');
      expect(
        result.questions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
        isFalse,
      );
    });

    test('RawFallback explanation fails closed before envelope attachment', () {
      final unsafeDraft = _draftWithExplanation(
        questionNumber: 1,
        questionId: _questionUuidA,
        explanation: RichContent(
          nodes: <ContentNode>[
            RawFallbackNode(<Object?, Object?>{
              'type': 'raw_fallback',
              'payload': <Object?, Object?>{'marker': 'synthetic'},
            }),
          ],
        ),
      );
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
              draft: unsafeDraft,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[_finalQuestion(number: 1)],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.legacyV1);
      expect(result.reason, 'typed_candidate_unsupported_structure');
      expect(
        result.questions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
        isFalse,
      );
    });

    test('final sort reorder is matched by identity, never by list index', () {
      final candidates = <OcrTypedCandidate>[
        _candidate(
          questionNumber: 1,
          questionId: _questionUuidA,
          reviewItemId: _reviewUuidA,
        ),
        _candidate(
          questionNumber: 2,
          questionId: _questionUuidB,
          reviewItemId: _reviewUuidB,
        ),
      ];
      final reordered = <Map<String, dynamic>>[
        _finalQuestion(number: 2),
        _finalQuestion(number: 1),
      ];
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(candidates: candidates),
        finalQuestions: reordered,
        singleFile: true,
      );

      expect(result.reason, 'typed_candidate_ready');
      final decodedByNumber = <int, TypedReviewSnapshot>{};
      for (final question in result.questions) {
        final number = question['question_number'] as int;
        final decoded = const TypedReviewSnapshotCodec()
            .decodeRequired(question[TypedReviewSnapshotCodec.mapKey]);
        decodedByNumber[number] = decoded;
      }
      expect(decodedByNumber[1]!.reviewItemId, _reviewUuidA);
      expect(decodedByNumber[2]!.reviewItemId, _reviewUuidB);
      expect(decodedByNumber[1]!.questionId, _questionUuidA);
      expect(decodedByNumber[2]!.questionId, _questionUuidB);
    });
  });

  group('R7C activation hardening', () {
    test('ineligible results strip every pre-existing envelope', () {
      final finalQuestions = <Map<String, dynamic>>[
        <String, dynamic>{
          ..._finalQuestion(number: 1),
          TypedReviewSnapshotCodec.mapKey: <String, Object?>{
            'schemaVersion': 1,
            'route': 'typedV2',
            'reviewItemId': _reviewUuidA,
            'questionId': _questionUuidA,
            'draft': <String, Object?>{},
            'baselineLegacy': <String, Object?>{},
          },
        },
      ];
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[],
          failure: OcrTypedCandidateFailure.projectionMismatch,
        ),
        finalQuestions: finalQuestions,
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.legacyV1);
      expect(result.reason, 'typed_candidate_projection_mismatch');
      expect(result.questions, hasLength(1));
      expect(
        result.questions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
        isFalse,
      );
      expect(
        finalQuestions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
        isTrue,
        reason: 'the caller-owned input map must never be mutated in place',
      );
      expect(finalQuestions.single['content'], 'Synthetic prompt marker 1.');
    });

    test('ineligible envelope stripping never modifies the input maps', () {
      final questions = <Map<String, dynamic>>[
        _finalQuestion(number: 1),
        _finalQuestion(number: 2),
      ];
      final before = <Map<String, dynamic>>[
        Map<String, dynamic>.from(questions[0]),
        Map<String, dynamic>.from(questions[1]),
      ];
      applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[],
          failure: OcrTypedCandidateFailure.notSingleFile,
        ),
        finalQuestions: questions,
        singleFile: false,
      );
      expect(questions, before);
    });

    test('non-canonical draft source ids make the whole batch ineligible', () {
      final draft = QuestionDraftV2(
        questionId: _questionUuidA,
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: RichContent(
          nodes: <ContentNode>[TextNode('Synthetic prompt marker 1.')],
        ),
        answer: ContentAnswer(
          content: RichContent(
            nodes: <ContentNode>[TextNode('synthetic-result-1')],
          ),
        ),
        sourceRefs: <SourceRef>[
          SourceRef.document(
            sourceId: 'legacy_non_canonical_source',
            displayLabel: null,
          ),
        ],
      );
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
              draft: draft,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[
          <String, dynamic>{..._finalQuestion(number: 1)},
        ],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.legacyV1);
      expect(result.reason, 'typed_candidate_identity_mismatch');
      expect(
        result.questions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
        isFalse,
      );
      expect(
        result.reason,
        isNot(contains('legacy_non_canonical_source')),
        reason: 'the original source id must never be emitted',
      );
    });

    test('canonical draft source ids pass the eligibility gate', () {
      final draft = QuestionDraftV2(
        questionId: _questionUuidA,
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: RichContent(
          nodes: <ContentNode>[TextNode('Synthetic prompt marker 1.')],
        ),
        answer: ContentAnswer(
          content: RichContent(
            nodes: <ContentNode>[TextNode('synthetic-result-1')],
          ),
        ),
        sourceRefs: <SourceRef>[
          SourceRef.document(
            sourceId: _sourceUuid,
            displayLabel: null,
          ),
        ],
      );
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
              draft: draft,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[
          <String, dynamic>{..._finalQuestion(number: 1)},
        ],
        singleFile: true,
      );

      expect(result.reason, isNot('typed_candidate_identity_mismatch'));
      expect(
        result.questions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
        isTrue,
      );
    });

    test('strict metadata validation rejects typedV2 with a null reason', () {
      expect(
        () => validateImportStorageMetadata(
          route: ImportStorageRoute.typedV2,
          reason: null,
        ),
        throwsA(isA<TypedReviewSnapshotException>()),
      );
    });

    test('strict metadata validation rejects typedV2 with shadow_ready', () {
      expect(
        () => validateImportStorageMetadata(
          route: ImportStorageRoute.typedV2,
          reason: ocrTypedCandidateShadowReadyReason,
        ),
        throwsA(isA<TypedReviewSnapshotException>()),
      );
    });

    test('strict metadata validation accepts typedV2 with ready reason', () {
      final validated = validateImportStorageMetadata(
        route: ImportStorageRoute.typedV2,
        reason: ocrTypedCandidateReadyReason,
      );
      expect(validated.route, ImportStorageRoute.typedV2);
      expect(validated.reason, 'typed_candidate_ready');
    });

    test('strict metadata validation keeps historical legacy reasons', () {
      for (final reason in <String?>[
        null,
        ocrTypedCandidateShadowReadyReason,
        ocrTypedCandidateFailureReason(OcrTypedCandidateFailure.repairApplied),
      ]) {
        final validated = validateImportStorageMetadata(
          route: ImportStorageRoute.legacyV1,
          reason: reason,
        );
        expect(validated.route, ImportStorageRoute.legacyV1);
        expect(validated.reason, reason);
      }
    });

    group('raw explanation parity telemetry', () {
      tearDown(() {
        rawExplanationTelemetryHandlerForTesting = null;
      });

      test(
          'emits complete redacted per-question telemetry during gate evaluation',
          () {
        final telemetryEvents = <Map<String, Object?>>[];
        rawExplanationTelemetryHandlerForTesting = telemetryEvents.add;

        final candidate = _candidate(
          questionNumber: 1,
          questionId: _questionUuidA,
          reviewItemId: _reviewUuidA,
          draft: _draftWithExplanation(
            questionNumber: 1,
            questionId: _questionUuidA,
            explanation: RichContent(
              nodes: <ContentNode>[
                const TextNode('Synthetic explanation 1'),
                ImageNode(
                  sourceId: _sourceUuid,
                  localAssetId: 'img_01',
                  alternativeText: RichContent(
                    nodes: const <ContentNode>[TextNode('fig')],
                  ),
                ),
              ],
            ),
            assetRefs: <SourcedAssetRef>[
              SourcedAssetRef(
                sourceId: _sourceUuid,
                asset: AssetRef(
                  assetId: 'img_01',
                  kind: AssetKind.image,
                ),
              ),
            ],
          ),
          projectedLegacy: _finalBaseline(
            number: 1,
            explanation: 'Synthetic explanation 1\n[图片]',
          ),
        );

        final question = _finalQuestion(number: 1)
          ..['raw_explanation'] = '<p>Synthetic explanation 1</p>[图片]'
          ..['explanation'] = 'Synthetic explanation 1\n[图片]';

        applyOcrTypedCandidateGate(
          batch: OcrTypedCandidateBatch(
            candidates: <OcrTypedCandidate>[candidate],
            candidateAssetLease: ContentAssetCandidateLease(
              sourceId: _sourceUuid,
              localAssetIds: const <String>['img_01'],
            ),
          ),
          finalQuestions: <Map<String, dynamic>>[question],
          singleFile: true,
        );

        expect(telemetryEvents, hasLength(1));
        final event = telemetryEvents.single;
        expect(event['questionNumber'], 1);
        expect(event['rawPresent'], isTrue);
        expect(event['rawTypeValid'], isTrue);
        expect(event['rawEmpty'], isFalse);
        expect(event['rawEqualsFinal'], isFalse);
        expect(event['finalEmpty'], isFalse);
        expect(event['candidateExplanationPresent'], isTrue);
        expect(event['topLevelNodeKinds'], <String>['text', 'image']);
        expect(event['containsRawFallback'], isFalse);
        expect(event['rawFallbackLocation'], isNull);
        expect(event['boundedAllowed'], isTrue);
        expect(event['n0Equal'], isFalse);
        expect(event['finalizerEligible'], isTrue);
        expect(event['finalizerMatched'], isTrue);
      });

      test(
          'identifies rawFallback and its location at top-level and in table-cell',
          () {
        final telemetryEvents = <Map<String, Object?>>[];
        rawExplanationTelemetryHandlerForTesting = telemetryEvents.add;

        final candidateFallback = _candidate(
          questionNumber: 2,
          questionId: _questionUuidB,
          reviewItemId: _reviewUuidB,
          draft: _draftWithExplanation(
            questionNumber: 2,
            questionId: _questionUuidB,
            explanation: RichContent(
              nodes: <ContentNode>[
                const TextNode('Explanation'),
                RawFallbackNode(
                  const <Object?, Object?>{'type': 'unsupported_tag'},
                ),
              ],
            ),
          ),
          projectedLegacy: _finalBaseline(
            number: 2,
            explanation: 'Explanation',
          ),
        );

        final question = _finalQuestion(number: 2)
          ..['raw_explanation'] = 'Explanation'
          ..['explanation'] = 'Explanation';

        applyOcrTypedCandidateGate(
          batch: OcrTypedCandidateBatch(
            candidates: <OcrTypedCandidate>[candidateFallback],
          ),
          finalQuestions: <Map<String, dynamic>>[question],
          singleFile: true,
        );

        expect(telemetryEvents, hasLength(1));
        final event = telemetryEvents.single;
        expect(event['questionNumber'], 2);
        expect(event['topLevelNodeKinds'], <String>['text', 'rawFallback']);
        expect(event['containsRawFallback'], isTrue);
        expect(event['rawFallbackLocation'], 'top-level');
        expect(event['boundedAllowed'], isFalse);
      });
    });

    group('unsupported structure diagnostic telemetry', () {
      test(
          'records questionNumber and kindCode when candidate construction throws (Test B)',
          () {
        final emitted = <Map<String, Object?>>[];
        typedCandidateRejectionHandlerForTesting = emitted.add;
        addTearDown(() {
          typedCandidateRejectionHandlerForTesting = null;
        });

        final document = _tableDocument();
        final regionized = _regionizer.regionize(document);
        expect(regionized.regions, hasLength(1));
        final batch = buildOcrTypedCandidateBatch(
          document: document,
          regions: regionized.regions,
          legacyQuestions: _legacyQuestions(regionized.regions),
          uuidV4Factory: _uuidSequence(),
        );

        expect(batch.candidates, isEmpty);
        expect(
          batch.failure,
          OcrTypedCandidateFailure.unsupportedStructure,
        );
        expect(emitted, hasLength(1));
        final record = emitted.single;
        expect(record['questionNumber'], regionized.regions.single.number);
        expect(record['kindCode'], 'ocr_table');
        expect(record['failure'], 'unsupportedStructure');
      });

      test(
          'records questionNumber and ocr_structural_ownership when structural part is not owned',
          () {
        final emitted = <Map<String, Object?>>[];
        typedCandidateRejectionHandlerForTesting = emitted.add;
        addTearDown(() {
          typedCandidateRejectionHandlerForTesting = null;
        });

        final document = _mergedExplanationTableDocument();
        final regionized = _regionizer.regionize(document);
        expect(regionized.regions, hasLength(1));
        final unownedRegion = OcrQuestionRegion(
          number: regionized.regions.single.number,
          stemParts: regionized.regions.single.stemParts,
          answerParts: regionized.regions.single.answerParts,
          explanationParts: regionized.regions.single.explanationParts,
          sourcePageIndices: regionized.regions.single.sourcePageIndices,
          sourceBlockIds: regionized.regions.single.sourceBlockIds,
          diagnostics: regionized.regions.single.diagnostics,
          declaredKind: regionized.regions.single.declaredKind,
          ownedSources: const <OcrQuestionRegionSource>[],
        );
        final batch = buildOcrTypedCandidateBatch(
          document: document,
          regions: <OcrQuestionRegion>[unownedRegion],
          legacyQuestions: _legacyQuestions(<OcrQuestionRegion>[unownedRegion]),
          uuidV4Factory: _uuidSequence(),
        );

        expect(batch.candidates, isEmpty);
        expect(
          batch.failure,
          OcrTypedCandidateFailure.unsupportedStructure,
        );
        expect(emitted, hasLength(1));
        final record = emitted.single;
        expect(record['questionNumber'], unownedRegion.number);
        expect(record['kindCode'], 'ocr_structural_ownership');
        expect(record['failure'], 'unsupportedStructure');
      });
    });
  });
}

/// A queued factory producing the canonical test UUID sequence so identities
/// are deterministic: source, then per questionId/reviewItemId pairs.
String Function() _uuidSequence() {
  final queue = <String>[
    _sourceUuid,
    _questionUuidA,
    _reviewUuidA,
    _questionUuidB,
    _reviewUuidB,
  ];
  var index = 0;
  return () => queue[index++];
}

List<Map<String, dynamic>> _legacyQuestions(List<OcrQuestionRegion> regions) {
  return regions
      .map((region) => _assembler.assemble(region).question)
      .toList(growable: false);
}

OcrTypedCandidate _candidate({
  required int questionNumber,
  required String questionId,
  required String reviewItemId,
  QuestionDraftV2? draft,
  LegacyReviewBaseline? projectedLegacy,
}) {
  return OcrTypedCandidate(
    questionNumber: questionNumber,
    questionId: questionId,
    reviewItemId: reviewItemId,
    draft: draft ??
        QuestionDraftV2(
          questionId: questionId,
          kind: QuestionKind.shortAnswer,
          questionNumber: questionNumber,
          stem: RichContent(
            nodes: <ContentNode>[
              TextNode('Synthetic prompt marker $questionNumber.'),
            ],
          ),
          answer: ContentAnswer(
            content: RichContent(
              nodes: <ContentNode>[TextNode('synthetic-result-1')],
            ),
          ),
          explanation: RichContent(
            nodes: <ContentNode>[TextNode('Synthetic explanation 1')],
          ),
        ),
    projectedLegacy: projectedLegacy ?? _finalBaseline(number: questionNumber),
    sourcePageIndices: const <int>[1],
    sourceBlockIds: const <String>['q_1', 'answer_1', 'explanation_1'],
  );
}

QuestionDraftV2 _draftWithExplanation({
  required int questionNumber,
  required String questionId,
  required RichContent explanation,
  Iterable<SourceRef>? sourceRefs,
  Iterable<SourcedAssetRef> assetRefs = const <SourcedAssetRef>[],
}) {
  return QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.shortAnswer,
    questionNumber: questionNumber,
    stem: RichContent(
      nodes: <ContentNode>[
        TextNode('Synthetic prompt marker $questionNumber.')
      ],
    ),
    answer: ContentAnswer(
      content: RichContent(
        nodes: <ContentNode>[TextNode('synthetic-result-1')],
      ),
    ),
    explanation: explanation,
    sourceRefs:
        sourceRefs ?? <SourceRef>[SourceRef.document(sourceId: _sourceUuid)],
    assetRefs: assetRefs,
  );
}

LegacyReviewBaseline _finalBaseline({
  required int number,
  String explanation = 'Synthetic explanation 1',
}) {
  return LegacyReviewBaseline(
    type: 3,
    questionNumber: number,
    content: 'Synthetic prompt marker $number.',
    options: const <String>[],
    standardAnswer: 'synthetic-result-1',
    explanation: explanation,
  );
}

Map<String, dynamic> _finalQuestion({required int number}) {
  return <String, dynamic>{
    'q_num': number.toString(),
    'question_number': number,
    'type': 3,
    'content': 'Synthetic prompt marker $number.',
    'options': <String>[],
    'standard_answer': 'synthetic-result-1',
    'explanation': 'Synthetic explanation 1',
    'raw_explanation': 'Synthetic explanation 1',
    'source_page_indices': <int>[1],
    'source_block_ids': <String>['q_1', 'answer_1', 'explanation_1'],
    'source': 'glm_ocr_intermediate',
    'diagnostics': <String>[],
  };
}

OcrBlock _block(
  String blockId,
  int pageIndex,
  int readingOrder,
  String text, {
  String type = 'text',
}) {
  return OcrBlock(
    blockId: blockId,
    pageIndex: pageIndex,
    type: type,
    text: text,
    bbox: const <double>[],
    readingOrder: readingOrder,
  );
}

OcrDocument _document(String sourceName, List<OcrPage> pages) {
  return OcrDocument(
    sourceName: sourceName,
    pages: pages,
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

OcrDocument _shortAnswerDocument() {
  return _document(
    'r7b_synthetic_single.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block('q_1', 1, 1, '1. Synthetic prompt marker 1.'),
          _block('answer_1', 1, 2, '答案：synthetic-result-1'),
          _block('explanation_1', 1, 3, '解析：Synthetic explanation 1'),
        ],
      ),
    ],
  );
}

OcrQuestionRegion _asciiChoiceRegion() {
  return const OcrQuestionRegion(
    number: 1,
    stemParts: <String>['1. 题干\n(A) 甲\n(B) 乙\n(C) 丙\n(D) 丁'],
    answerParts: <String>['A'],
    explanationParts: <String>['解析：保留解析'],
    sourcePageIndices: <int>[1],
    sourceBlockIds: <String>['q_1', 'answer_1', 'explanation_1'],
    diagnostics: <String>[],
    declaredKind: TextQuestionKind.choice,
  );
}

OcrDocument _asciiChoiceDocument() {
  return _document(
    'r7b_synthetic_ascii_choice.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('q_1', 1, 0, '1. 题干\n(A) 甲\n(B) 乙\n(C) 丙\n(D) 丁'),
          _block('answer_1', 1, 1, '答案：A'),
          _block('explanation_1', 1, 2, '解析：保留解析'),
        ],
      ),
    ],
  );
}

OcrDocument _twoQuestionDocument() {
  return _document(
    'r7b_synthetic_two.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block('q_1', 1, 1, '1. Synthetic prompt marker 1.'),
          _block('answer_1', 1, 2, '答案：synthetic-result-1'),
          _block('explanation_1', 1, 3, '解析：Synthetic explanation 1'),
          _block('q_2', 1, 4, '2. Synthetic prompt marker 2.'),
          _block('answer_2', 1, 5, '答案：synthetic-result-2'),
          _block('explanation_2', 1, 6, '解析：Synthetic explanation 2'),
        ],
      ),
    ],
  );
}

OcrDocument _referenceAnswerDocument() {
  return _document(
    'r7b_synthetic_reference.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题（共2题）'),
          _block('q_1', 1, 1, '1. Synthetic prompt marker 1.'),
          _block('e_1', 1, 2, '解析：Synthetic explanation 1'),
          _block('q_2', 1, 3, '2. Synthetic prompt marker 2.'),
          _block('e_2', 1, 4, '解析：Synthetic explanation 2'),
          _block('reference_title', 1, 5, '2022 模拟试卷参考答案汇总'),
          _block('reference_1', 1, 6, '(1) Final answer one'),
          _block('reference_2', 1, 7, '（2）Final answer two'),
        ],
      ),
    ],
  );
}

OcrDocument _tableDocument() {
  return _document(
    'r7b_synthetic_table.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block(
            'q_1',
            1,
            1,
            '1. Synthetic prompt marker 1.',
            type: 'table',
          ),
          _block('answer_1', 1, 2, '答案：synthetic-result-1'),
          _block('explanation_1', 1, 3, '解析：Synthetic explanation 1'),
        ],
      ),
    ],
  );
}

OcrDocument _mergedExplanationTableDocument() {
  return _document(
    'r7b_synthetic_merged_explanation.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block('q_1', 1, 1, '1. Synthetic prompt marker 1.'),
          _block('answer_1', 1, 2, '答案：synthetic-result-1'),
          _block(
            'explanation_table',
            1,
            3,
            '<table>'
                '<tr><td rowspan="2" colspan="2">A</td><td>B</td></tr>'
                '<tr><td>C</td></tr>'
                '</table>',
            type: 'table',
          ),
        ],
      ),
    ],
  );
}

OcrQuestionRegion _mergedExplanationTableRegion() {
  return const OcrQuestionRegion(
    number: 1,
    stemParts: <String>['Synthetic prompt marker 1.'],
    answerParts: <String>['synthetic-result-1'],
    explanationParts: <String>['A | | B\n | | C'],
    sourcePageIndices: <int>[1],
    sourceBlockIds: <String>['q_1', 'answer_1', 'explanation_table'],
    diagnostics: <String>['contains_table_block'],
    declaredKind: TextQuestionKind.subjective,
    ownedSources: <OcrQuestionRegionSource>[
      OcrQuestionRegionSource(
        blockId: 'q_1',
        field: OcrRegionField.stem,
        text: 'Synthetic prompt marker 1.',
      ),
      OcrQuestionRegionSource(
        blockId: 'answer_1',
        field: OcrRegionField.answer,
        text: 'synthetic-result-1',
      ),
      OcrQuestionRegionSource(
        blockId: 'explanation_table',
        field: OcrRegionField.explanation,
        text: 'A | | B\n | | C',
      ),
    ],
  );
}

OcrDocument _unsupportedTypeDocument(String type) {
  return _document(
    'r7b_synthetic_unsupported_$type.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block(
            'q_1',
            1,
            1,
            '1. Synthetic prompt marker 1.',
            type: type,
          ),
          _block('answer_1', 1, 2, '答案：synthetic-result-1'),
          _block('explanation_1', 1, 3, '解析：Synthetic explanation 1'),
        ],
      ),
    ],
  );
}
