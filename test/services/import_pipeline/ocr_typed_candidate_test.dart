// R7B unit contract for the shadow typed candidate contract, batch builder
// and all-or-nothing final gate. Synthetic fixtures only; the harness has no
// Provider, Replay, network, database, UI, filesystem or application call
// site, so Provider calls are 0 by construction.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_extractor.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_merger.dart';

import '../../support/memory_content_asset_store.dart';

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

    test(
        'malformed table structure inside question region makes the whole batch ineligible',
        () {
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

    test(
        'valid HTML table inside question region admits candidate with table_text_projection',
        () {
      final document = _validTableInQuestionDocument();
      final regionized = _regionizer.regionize(document);
      expect(regionized.regions, hasLength(1));
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: _legacyQuestions(regionized.regions),
        uuidV4Factory: _uuidSequence(),
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      final candidate = batch.candidates.single;
      expect(
          candidate.draft.issues.any((i) => i.code == 'table_text_projection'),
          isTrue);
      expect(candidate.draft.explanation, isNotNull);
      final explText = candidate.draft.explanation!.nodes
          .whereType<TextNode>()
          .map((n) => n.text)
          .join();
      expect(explText, contains('分布 | 期望'));
      expect(explText, contains('B(n,p) | np'));
      expect(explText.contains('<table'), isFalse);
    });

    test(
        'multiple table blocks inside a single question maintain provenance and succeed',
        () {
      final document = _multiTableInQuestionDocument();
      final regionized = _regionizer.regionize(document);
      expect(regionized.regions, hasLength(1));
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: _legacyQuestions(regionized.regions),
        uuidV4Factory: _uuidSequence(),
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      final candidate = batch.candidates.single;
      expect(candidate.draft.explanation, isNotNull);
      final explText = candidate.draft.explanation!.nodes
          .whereType<TextNode>()
          .map((n) => n.text)
          .join();
      expect(explText, contains('分布 | 期望'));
      expect(explText, contains('(续表) | 方差'));
    });

    test(
        'mixed image and table in same explanation preserves ImageNode without squashing',
        () {
      final document = _imageAndTableInExplanationDocument();
      final regionized = _regionizer.regionize(document);
      expect(regionized.regions, hasLength(1));
      final assetStore = MemoryContentAssetStore();
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: _legacyQuestions(regionized.regions),
        uuidV4Factory: _uuidSequence(),
        assetStore: assetStore,
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      final candidate = batch.candidates.single;
      expect(candidate.draft.explanation, isNotNull);
      final nodes = candidate.draft.explanation!.nodes;
      expect(nodes.whereType<ImageNode>(), hasLength(1));
      expect(nodes.whereType<TextNode>().any((n) => n.text.contains('条件 | 结论')),
          isTrue);
    });

    test('table structure outside question regions does not disqualify batch',
        () {
      final document = _unreferencedTableDocument();
      final regionized = _regionizer.regionize(document);
      expect(regionized.regions, hasLength(1));
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: _legacyQuestions(regionized.regions),
        uuidV4Factory: _uuidSequence(),
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
    });

    test(
        'image with ContentAssetStore materializes ImageNode with stored bytes in assetStore',
        () {
      final document = _imageInQuestionDocument();
      final regionized = _regionizer.regionize(document);
      expect(regionized.regions, hasLength(1));
      final assetStore = MemoryContentAssetStore();
      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: _legacyQuestions(regionized.regions),
        uuidV4Factory: _uuidSequence(),
        assetStore: assetStore,
      );

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      final candidate = batch.candidates.single;
      final imageNodes =
          candidate.draft.stem.nodes.whereType<ImageNode>().toList();
      expect(imageNodes, hasLength(1));
      final imageNode = imageNodes.single;
      expect(imageNode.assetRef, startsWith('content_assets/'));
      expect(assetStore.storage.containsKey(imageNode.assetRef), isTrue);
      expect(assetStore.storage[imageNode.assetRef], isNotEmpty);
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

    test('raw_explanation with benign HTML wrapper differences is allowed', () {
      for (final raw in <String>[
        '<div align="center">Synthetic explanation 1</div>',
        '<p><span>Synthetic explanation 1</span></p>',
      ]) {
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
            reason: 'benign wrapper in raw_explanation must be allowed');
        // Verify provenance was not mutated:
        expect(
          result.questions.single['raw_explanation'],
          raw,
          reason:
              'gate PASS must preserve exact original raw_explanation bytes',
        );
      }
    });

    test('raw_explanation divergence fails the whole batch', () {
      final question = _finalQuestion(number: 1)
        ..['raw_explanation'] = '<div>Synthetic explanation 1 with diff</div>';
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

    test('raw_explanation with dangerous or unsupported HTML tags fails gate',
        () {
      for (final raw in <String>[
        '<script>alert(1)</script>Synthetic explanation 1',
        '<table><tr><td>表格</td></tr></table>',
      ]) {
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

        expect(result.reason, 'typed_candidate_raw_explanation_diverged');
        expect(
          result.questions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
          isFalse,
        );
      }
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
    projectedLegacy: _finalBaseline(number: questionNumber),
    sourcePageIndices: const <int>[1],
    sourceBlockIds: const <String>['q_1', 'answer_1', 'explanation_1'],
  );
}

LegacyReviewBaseline _finalBaseline({required int number}) {
  return LegacyReviewBaseline(
    type: 3,
    questionNumber: number,
    content: 'Synthetic prompt marker $number.',
    options: const <String>[],
    standardAnswer: 'synthetic-result-1',
    explanation: 'Synthetic explanation 1',
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

OcrDocument _unreferencedTableDocument() {
  return _document(
    'r7b_synthetic_unreferenced_table.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('header_table', 1, 0, '表格：考试科目与分数分布表', type: 'table'),
          _block('section', 1, 1, '三、解答题'),
          _block('q_1', 1, 2, '1. Synthetic prompt marker 1.'),
          _block('answer_1', 1, 3, '答案：synthetic-result-1'),
          _block('explanation_1', 1, 4, '解析：Synthetic explanation 1'),
        ],
      ),
    ],
  );
}

OcrDocument _imageInQuestionDocument() {
  const tinyPngDataUrl =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
  return _document(
    'r7b_synthetic_image_in_question.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block('q_1_text', 1, 1, '1. 如图所示：'),
          _block('q_1_img', 1, 2, tinyPngDataUrl, type: 'image'),
          _block('answer_1', 1, 3, '答案：synthetic-result-1'),
          _block('explanation_1', 1, 4, '解析：Synthetic explanation 1'),
        ],
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
          _block('q_1', 1, 1, '1. Synthetic prompt marker 1.'),
          _block('q_1_unsupported', 1, 2, 'Unsupported content', type: type),
          _block('answer_1', 1, 3, '答案：synthetic-result-1'),
          _block('explanation_1', 1, 4, '解析：Synthetic explanation 1'),
        ],
      ),
    ],
  );
}

OcrDocument _validTableInQuestionDocument() {
  const tableHtml =
      '<table border="1"><tr><td>分布</td><td>期望</td></tr><tr><td>B(n,p)</td><td>np</td></tr></table>';
  return _document(
    'r7b_synthetic_valid_table.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block('q_1', 1, 1, '1. 常见分布题：'),
          _block('answer_1', 1, 2, '答案：np'),
          _block('explanation_1', 1, 3, '解析：详细解析如下'),
          _block('table_1', 1, 4, tableHtml, type: 'table'),
        ],
      ),
    ],
  );
}

OcrDocument _multiTableInQuestionDocument() {
  const tableHtml1 =
      '<table border="1"><tr><td>分布</td><td>期望</td></tr></table>';
  const tableHtml2 =
      '<table border="1"><tr><td>(续表)</td><td>方差</td></tr></table>';
  return _document(
    'r7b_synthetic_multi_table.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block('q_1', 1, 1, '1. 分布与方差：'),
          _block('answer_1', 1, 2, '答案：见表格'),
          _block('explanation_1', 1, 3, '解析：总结如下'),
          _block('table_1', 1, 4, tableHtml1, type: 'table'),
          _block('table_2', 1, 5, tableHtml2, type: 'table'),
        ],
      ),
    ],
  );
}

OcrDocument _imageAndTableInExplanationDocument() {
  const tinyPngDataUrl =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
  const tableHtml = '<table border="1"><tr><td>条件</td><td>结论</td></tr></table>';
  return _document(
    'r7b_synthetic_image_and_table.pdf',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block('q_1', 1, 1, '1. 综合题：'),
          _block('answer_1', 1, 2, '答案：C'),
          _block('explanation_1', 1, 3, '解析：如图所示：'),
          _block('img_1', 1, 4, tinyPngDataUrl, type: 'image'),
          _block('table_1', 1, 5, tableHtml, type: 'table'),
        ],
      ),
    ],
  );
}
