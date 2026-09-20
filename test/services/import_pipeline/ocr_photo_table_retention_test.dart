import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content_text_projection.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_pipeline/final_question_latex_audit.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_review/explanation_edit_provenance.dart';
import 'package:shiroha_quiz/services/import_review/review_legacy_field_content.dart';
import 'package:shiroha_quiz/services/import_review/typed_review_result_builder.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

// Synthetic, offline production seams. No provider, database, or input files.
void main() {
  for (final mode in ExplanationRetentionMode.values) {
    testWidgets('photo table survives ${mode.name} through snapshot rendering',
        (tester) async {
      final (batch, questions) = _build(mode);
      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      expect(batch.candidates.single.draft.stem.nodes.whereType<TableNode>(),
          isEmpty);
      expect(
          batch.candidates.single.draft.explanation!.nodes
              .whereType<TableNode>(),
          hasLength(1));
      expect(batch.candidates.single.draft.options, hasLength(4));
      expect(questions.single['raw_explanation'], isNotEmpty);
      expect(
        questions.single['options'],
        const <String>['A. One', 'B. Two', 'C. Three', 'D.\nFour'],
        reason: 'the production finalizer removes safe OCR HTML wrappers',
      );
      final retained = mode == ExplanationRetentionMode.allQuestionTypes;
      expect((questions.single['explanation'] as String).isNotEmpty, retained);

      final gate = applyOcrTypedCandidateGate(
        batch: batch,
        finalQuestions: questions,
        singleFile: true,
      );
      expect(gate.route, ImportStorageRoute.typedV2, reason: gate.reason);
      final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
        gate.questions.single[TypedReviewSnapshotCodec.mapKey],
      );
      expect(snapshot.draft.stem.nodes.whereType<TableNode>(), isEmpty);
      expect(snapshot.draft.explanation, isNotNull);
      expect(snapshot.draft.explanation!.nodes.whereType<TableNode>(),
          hasLength(1));
      expect(
          snapshot.baselineLegacy.explanation, questions.single['explanation']);
      final committed = TypedReviewResultBuilder().build(
        inputs: [
          TypedReviewCommitInput(
            reviewItemId: snapshot.reviewItemId,
            envelope: gate.questions.single[TypedReviewSnapshotCodec.mapKey],
            currentDraft: QuestionDraft.fromMap(gate.questions.single),
            explanationRetained: true,
            explanationEditProvenance: ExplanationEditProvenance.legacyUnknown,
          ),
        ],
        taskId: 'synthetic_photo',
        attemptToken: 'synthetic_attempt',
        attemptNumber: 1,
      );
      expect(committed.acceptedDrafts.single.stem, snapshot.draft.stem);
      expect(committed.acceptedDrafts.single.explanation != null, retained);
      if (!retained) {
        final restored = finalizeAndAuditImportQuestion(
          gate.questions.single,
          mode: ExplanationRetentionMode.allQuestionTypes,
        );
        final restoredCommit = TypedReviewResultBuilder().build(
          inputs: [
            TypedReviewCommitInput(
              reviewItemId: snapshot.reviewItemId,
              envelope: gate.questions.single[TypedReviewSnapshotCodec.mapKey],
              currentDraft: QuestionDraft.fromMap(restored),
              explanationRetained: true,
              explanationEditProvenance:
                  ExplanationEditProvenance.legacyUnknown,
            ),
          ],
          taskId: 'synthetic_photo',
          attemptToken: 'synthetic_attempt',
          attemptNumber: 1,
        );
        expect(
          restoredCommit.acceptedDrafts.single.explanation!.nodes
              .whereType<TableNode>(),
          hasLength(1),
        );
      }
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RichContentRenderer(content: snapshot.draft.explanation!),
        ),
      ));
      expect(find.textContaining('Cell alpha', findRichText: true),
          findsOneWidget);
      expect(
          find.textContaining('Cell beta', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('policy discard still rejects changed raw, final fields and provenance',
      () {
    final (batch, questions) = _build(ExplanationRetentionMode.subjectiveOnly);
    for (final mutation in <(String, Object, String)>[
      (
        'raw_explanation',
        'Different synthetic explanation',
        'typed_candidate_raw_explanation_diverged'
      ),
      ('raw_explanation', 42, 'typed_candidate_raw_explanation_diverged'),
      (
        'content',
        'Changed synthetic stem',
        'typed_candidate_projection_mismatch'
      ),
      (
        'options',
        <String>['A. One', 'B. Two', 'C. Three', 'D. Changed'],
        'typed_candidate_projection_mismatch'
      ),
      (
        'source_block_ids',
        <String>['other'],
        'typed_candidate_projection_mismatch'
      ),
    ]) {
      final changed = <String, dynamic>{
        ...questions.single,
        mutation.$1: mutation.$2,
        TypedReviewSnapshotCodec.mapKey: <String, Object?>{},
      };
      final gate = applyOcrTypedCandidateGate(
        batch: batch,
        finalQuestions: [changed],
        singleFile: true,
      );
      expect(gate.reason, mutation.$3);
      expect(gate.questions.single.containsKey(TypedReviewSnapshotCodec.mapKey),
          isFalse);
    }
  });

  test('empty final explanation cannot assert a discard without builder proof',
      () {
    final (batch, questions) = _build(ExplanationRetentionMode.subjectiveOnly);
    final candidate = batch.candidates.single;
    final unattested = OcrTypedCandidate(
      questionNumber: candidate.questionNumber,
      reviewItemId: candidate.reviewItemId,
      questionId: candidate.questionId,
      draft: candidate.draft,
      projectedLegacy: candidate.projectedLegacy,
      sourcePageIndices: candidate.sourcePageIndices,
      sourceBlockIds: candidate.sourceBlockIds,
    );
    final gate = applyOcrTypedCandidateGate(
      batch: OcrTypedCandidateBatch(candidates: [unattested]),
      finalQuestions: questions,
      singleFile: true,
    );
    expect(gate.reason, 'typed_candidate_raw_explanation_diverged');
  });

  test('retained explanations still reject an unexpected empty final field',
      () {
    final (batch, questions) =
        _build(ExplanationRetentionMode.allQuestionTypes);
    final gate = applyOcrTypedCandidateGate(
      batch: batch,
      finalQuestions: [
        {...questions.single, 'explanation': ''}
      ],
      singleFile: true,
    );
    expect(gate.reason, 'typed_candidate_raw_explanation_diverged');
  });

  test(
      'typed snapshot creation initializes untouched provenance and survives '
      'a reload', () {
    final (batch, questions) = _build(ExplanationRetentionMode.subjectiveOnly);
    expect(batch.failure, isNull);

    // The initialization boundary: only the batch builder may create a typed
    // review item, so only it may declare the explanation untouched.
    expect(
      questions.single[explanationEditProvenanceKey],
      isNull,
      reason: 'the OCR layer never invents provenance',
    );

    final gate = applyOcrTypedCandidateGate(
      batch: batch,
      finalQuestions: questions,
      singleFile: true,
    );
    expect(gate.route, ImportStorageRoute.typedV2, reason: gate.reason);
    expect(
      gate.questions.single[explanationEditProvenanceKey],
      explanationEditProvenanceUntouched,
      reason: 'a new typed item must be explicitly untouched',
    );

    final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
      gate.questions.single[TypedReviewSnapshotCodec.mapKey],
    );
    // The objective explanation is hidden by the parse policy, so the legacy
    // text and the typed structure genuinely disagree here.
    expect(gate.questions.single['explanation'], isEmpty);
    final projected =
        const RichContentTextProjection().project(snapshot.draft.explanation!);
    expect(projected, isNotEmpty);

    // Reopen the draft under a keep decision, exactly as the review screen does.
    final reopened = finalizeAndAuditImportQuestion(
      gate.questions.single,
      mode: ExplanationRetentionMode.allQuestionTypes,
    );
    expect(
      reopened[explanationEditProvenanceKey],
      explanationEditProvenanceUntouched,
      reason: 'the explicit marker must survive every draft re-finalization',
    );

    // Preview authority: the untouched structure is used without comparing the
    // legacy text with the projection.
    final previewContent = resolveExplanationReviewContent(
      originalContent: snapshot.draft.explanation,
      baselineText: snapshot.baselineLegacy.explanation,
      currentText: reopened['explanation'] as String,
      retained: true,
      provenance: decodeExplanationEditProvenance(
        reopened[explanationEditProvenanceKey],
      ),
    );
    expect(previewContent, isNotNull);
    expect(previewContent!.nodes.whereType<TableNode>(), hasLength(1));

    // Commit authority consumes the same decisions and keeps the structure.
    final committed = TypedReviewResultBuilder().build(
      inputs: [
        TypedReviewCommitInput(
          reviewItemId: snapshot.reviewItemId,
          envelope: gate.questions.single[TypedReviewSnapshotCodec.mapKey],
          currentDraft: QuestionDraft.fromMap(reopened),
          explanationRetained: true,
          explanationEditProvenance: decodeExplanationEditProvenance(
            reopened[explanationEditProvenanceKey],
          ),
        ),
      ],
      taskId: 'synthetic_photo',
      attemptToken: 'synthetic_attempt',
      attemptNumber: 1,
    );
    final committedExplanation = committed.acceptedDrafts.single.explanation;
    expect(committedExplanation, isNotNull);
    expect(committedExplanation!.nodes.whereType<TableNode>(), hasLength(1),
        reason: 'preview and commit must not disagree about the structure');
    expect(committedExplanation, snapshot.draft.explanation);

    // A draft with no marker stays fail-closed whenever the stored text is not
    // an exact projection, which is exactly the real observed representation.
    final mismatched = <String, dynamic>{
      ...reopened,
      'explanation': '${reopened['explanation']}\$x\$',
    };
    expect(
      const RichContentTextProjection().project(snapshot.draft.explanation!) ==
          (mismatched['explanation'] as String),
      isFalse,
      reason: 'the fixture must really differ from the typed projection',
    );
    final legacyCommit = TypedReviewResultBuilder().build(
      inputs: [
        TypedReviewCommitInput(
          reviewItemId: snapshot.reviewItemId,
          envelope: gate.questions.single[TypedReviewSnapshotCodec.mapKey],
          currentDraft: QuestionDraft.fromMap(mismatched),
          explanationRetained: true,
          explanationEditProvenance: ExplanationEditProvenance.legacyUnknown,
        ),
      ],
      taskId: 'synthetic_photo',
      attemptToken: 'synthetic_attempt',
      attemptNumber: 1,
    );
    expect(
      legacyCommit.acceptedDrafts.single.explanation!.nodes
          .whereType<TableNode>(),
      isEmpty,
      reason: 'a marker-less draft never gets the structure back',
    );
  });
}

(OcrTypedCandidateBatch, List<Map<String, dynamic>>) _build(
    ExplanationRetentionMode mode) {
  final document = OcrDocument(
    sourceName: 'synthetic_photo.png',
    pages: <OcrPage>[
      OcrPage(pageIndex: 1, blocks: <OcrBlock>[
        _block('section', 'text', '一、选择题', 0),
        _block(
          'q_5',
          'text',
          '5. Synthetic table question\n'
              '(A) One\n(B) Two\n(C) Three\n(D) <p>Four</p>',
          1,
        ),
        _block('answer_5', 'text', '答案：A', 2),
        _block('explanation_5', 'text', '## 分析 Synthetic explanation.', 3),
        _block('table_5', 'table',
            '<table><tr><td>Cell alpha</td><td>Cell beta</td></tr></table>', 4),
      ]),
    ],
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
  final regions = const OcrQuestionRegionizer().regionize(document).regions;
  expect(regions, hasLength(1));
  final legacy = <Map<String, dynamic>>[
    for (final region in regions)
      const OcrQuestionAssembler().assemble(region).question,
  ];
  var id = 0;
  final batch = buildOcrTypedCandidateBatch(
    document: document,
    regions: regions,
    legacyQuestions: legacy,
    uuidV4Factory: () =>
        '00000000-0000-4000-8000-${(++id).toString().padLeft(12, '0')}',
    explanationRetentionMode: mode,
  );
  return (batch, finalizeAndAuditImportQuestions(legacy, mode: mode));
}

OcrBlock _block(String id, String type, String text, int order) => OcrBlock(
      blockId: id,
      pageIndex: 1,
      type: type,
      text: text,
      bbox: const <double>[],
      readingOrder: order,
    );
