import 'package:meta/meta.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/content/rich_content_limits.dart';
import 'package:shiroha_quiz/domain/content/rich_content_text_projection.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_rich_content_parser.dart';
import 'package:shiroha_quiz/services/import_pipeline/final_question_latex_audit.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/question_draft_v2_legacy_projection.dart';
import 'package:shiroha_quiz/services/import_pipeline/typed_question_assembler.dart';

/// Fixed task-level storage reason for a successful shadow candidate batch.
const String ocrTypedCandidateShadowReadyReason =
    'typed_candidate_shadow_ready';

/// Fixed task-level storage reason for an R7C activated typed candidate
/// batch. Only this reason is accepted for [ImportStorageRoute.typedV2].
const String ocrTypedCandidateReadyReason = 'typed_candidate_ready';

/// Fixed classification of shadow typed candidate batch failures.
///
/// The enum is the only domain state; arbitrary error strings are never used
/// as candidate status. Each value maps to exactly one fixed task reason.
enum OcrTypedCandidateFailure {
  unsupportedStructure,
  projectionUnsupported,
  repairApplied,
  projectionMismatch,
  countMismatch,
  identityMismatch,
  baselineInvalid,
  rawExplanationDiverged,
  snapshotInvalid,
  notSingleFile,
  internalError,
}

/// Serializes a [OcrTypedCandidateFailure] to its fixed lower_snake_case
/// task storage reason. Values never include question numbers, exceptions,
/// kind codes, paths, source IDs or Provider information.
String ocrTypedCandidateFailureReason(OcrTypedCandidateFailure failure) {
  return switch (failure) {
    OcrTypedCandidateFailure.unsupportedStructure =>
      'typed_candidate_unsupported_structure',
    OcrTypedCandidateFailure.projectionUnsupported =>
      'typed_candidate_projection_unsupported',
    OcrTypedCandidateFailure.repairApplied => 'typed_candidate_repair_applied',
    OcrTypedCandidateFailure.projectionMismatch =>
      'typed_candidate_projection_mismatch',
    OcrTypedCandidateFailure.countMismatch => 'typed_candidate_count_mismatch',
    OcrTypedCandidateFailure.identityMismatch =>
      'typed_candidate_identity_mismatch',
    OcrTypedCandidateFailure.baselineInvalid =>
      'typed_candidate_baseline_invalid',
    OcrTypedCandidateFailure.rawExplanationDiverged =>
      'typed_candidate_raw_explanation_diverged',
    OcrTypedCandidateFailure.snapshotInvalid =>
      'typed_candidate_snapshot_invalid',
    OcrTypedCandidateFailure.notSingleFile => 'typed_candidate_not_single_file',
    OcrTypedCandidateFailure.internalError => 'typed_candidate_internal_error',
  };
}

/// One shadow typed candidate produced from real production objects.
///
/// Immutable. Collections are defensive copies. No file path, source name,
/// Provider payload, exception, raw OCR response or diagnostics map is ever
/// stored on a candidate.
final class OcrTypedCandidate {
  factory OcrTypedCandidate({
    required int questionNumber,
    required String reviewItemId,
    required String questionId,
    required QuestionDraftV2 draft,
    required LegacyReviewBaseline projectedLegacy,
    required List<int> sourcePageIndices,
    required List<String> sourceBlockIds,
  }) {
    return OcrTypedCandidate._(
      questionNumber: questionNumber,
      reviewItemId: reviewItemId,
      questionId: questionId,
      draft: draft,
      projectedLegacy: projectedLegacy,
      sourcePageIndices: List<int>.unmodifiable(sourcePageIndices),
      sourceBlockIds: List<String>.unmodifiable(sourceBlockIds),
    );
  }

  const OcrTypedCandidate._({
    required this.questionNumber,
    required this.reviewItemId,
    required this.questionId,
    required this.draft,
    required this.projectedLegacy,
    required this.sourcePageIndices,
    required this.sourceBlockIds,
  });

  final int questionNumber;
  final String reviewItemId;
  final String questionId;
  final QuestionDraftV2 draft;
  final LegacyReviewBaseline projectedLegacy;
  final List<int> sourcePageIndices;
  final List<String> sourceBlockIds;
}

/// The all-or-nothing outcome of shadow candidate generation for one OCR
/// batch. When [failure] is non-null the batch is ineligible and carries no
/// candidates.
final class OcrTypedCandidateBatch {
  factory OcrTypedCandidateBatch({
    required List<OcrTypedCandidate> candidates,
    OcrTypedCandidateFailure? failure,
    ContentAssetCandidateLease? candidateAssetLease,
  }) {
    return OcrTypedCandidateBatch._(
      candidates: List<OcrTypedCandidate>.unmodifiable(candidates),
      failure: failure,
      candidateAssetLease: candidateAssetLease,
    );
  }

  const OcrTypedCandidateBatch._({
    required this.candidates,
    required this.failure,
    required this.candidateAssetLease,
  });

  final List<OcrTypedCandidate> candidates;
  final OcrTypedCandidateFailure? failure;

  /// Candidate-owned bytes remain available only while the candidate is
  /// pending formal retention. The pipeline rolls this lease back on a
  /// rejected/fallback/cancelled outcome.
  final ContentAssetCandidateLease? candidateAssetLease;
}

/// Builds shadow typed candidates from the real production objects already
/// present in [OcrImportService]: the [OcrDocument], the reference-answer
/// merged [OcrQuestionRegion]s in question order, and the parallel final
/// legacy question maps.
///
/// Every candidate follows the frozen typed path:
/// `OcrSourceDocumentAdapter -> OcrQuestionRegionBridge ->
/// TypedQuestionAssembler -> QuestionDraftV2LegacyProjector(OCR profile)`.
/// Candidates are never reconstructed from legacy maps, strings or
/// diagnostics. Any internal failure maps to a fixed failure classification
/// and never carries the original exception.
OcrTypedCandidateBatch buildOcrTypedCandidateBatch({
  required OcrDocument document,
  required List<OcrQuestionRegion> regions,
  required List<Map<String, dynamic>> legacyQuestions,
  required String Function() uuidV4Factory,
  ContentAssetStore? assetStore,
  ExplanationRetentionMode explanationRetentionMode =
      ExplanationRetentionMode.subjectiveOnly,
}) {
  emitImportExplanationLifecycleTelemetryForProduction(
    stage: 'typed_batch_input',
    sourceCollectionName: 'ocr_typed_batch_legacy_questions',
    questions: legacyQuestions,
    retentionMode: explanationRetentionMode,
  );
  if (regions.length != legacyQuestions.length) {
    return OcrTypedCandidateBatch(
      candidates: <OcrTypedCandidate>[],
      failure: OcrTypedCandidateFailure.countMismatch,
    );
  }

  for (final question in legacyQuestions) {
    final diagnostics = question['diagnostics'];
    if (diagnostics is List && diagnostics.contains('ai_repair_applied')) {
      return OcrTypedCandidateBatch(
        candidates: <OcrTypedCandidate>[],
        failure: OcrTypedCandidateFailure.repairApplied,
      );
    }
  }

  String? sourceId;
  final SourceDocument sourceDocument;
  final mathSourceMap = OcrMathSourceMap();
  final createdAssetIds = <String>{};
  ContentAssetCandidateLease? candidateAssetLease;
  try {
    final generatedSourceId = uuidV4Factory();
    sourceId = generatedSourceId;
    sourceDocument = OcrSourceDocumentAdapter(
      assetStore: assetStore,
      onAssetCreated: createdAssetIds.add,
    ).convert(document,
        sourceId: generatedSourceId,
        displayLabel: null,
        mathSourceMap: mathSourceMap);
    candidateAssetLease = ContentAssetCandidateLease(
      sourceId: generatedSourceId,
      localAssetIds: createdAssetIds,
    );
  } catch (_) {
    if (sourceId != null) {
      candidateAssetLease = ContentAssetCandidateLease(
        sourceId: sourceId,
        localAssetIds: createdAssetIds,
      );
    }
    return OcrTypedCandidateBatch(
      candidates: <OcrTypedCandidate>[],
      failure: OcrTypedCandidateFailure.internalError,
      candidateAssetLease: candidateAssetLease,
    );
  }

  final candidates = <OcrTypedCandidate>[];
  for (final region in regions) {
    try {
      final typedRegion = const OcrQuestionRegionBridge().convert(
        region,
        sourceDocument: sourceDocument,
        mathSourceMap: mathSourceMap,
      );
      final questionId = uuidV4Factory();
      final draft = const TypedQuestionAssembler().assemble(
        typedRegion,
        questionId: questionId,
        mathSourceMap: mathSourceMap,
      );
      final projected = const QuestionDraftV2LegacyProjector().project(
        draft: draft,
        region: typedRegion,
        profile: const OcrLegacyProjectionProfile(),
        mathSourceMap: mathSourceMap,
        explanationRetentionMode: explanationRetentionMode,
      );
      _emitTypedCandidateConstructionTelemetry(
        region: region,
        typedRegion: typedRegion,
        draft: draft,
      );
      final reviewItemId = uuidV4Factory();
      final projectedQuestion = projected.question;
      final baseline = LegacyReviewBaseline(
        type: projectedQuestion['type'] as int,
        questionNumber:
            (projectedQuestion['question_number'] as num?)?.toInt() ??
                region.number,
        content: projectedQuestion['content'] as String,
        options: List<String>.from(
          projectedQuestion['options'] as List<Object?>,
        ),
        standardAnswer: projectedQuestion['standard_answer'] as String,
        explanation: projectedQuestion['explanation'] as String,
      );
      final pages = projectedQuestion['source_page_indices'];
      final blocks = projectedQuestion['source_block_ids'];
      candidates.add(
        OcrTypedCandidate(
          questionNumber: region.number,
          reviewItemId: reviewItemId,
          questionId: questionId,
          draft: draft,
          projectedLegacy: baseline,
          sourcePageIndices: pages is List
              ? pages.map((value) => value as int).toList(growable: false)
              : const <int>[],
          sourceBlockIds: blocks is List
              ? blocks.map((value) => value as String).toList(growable: false)
              : const <String>[],
        ),
      );
    } on QuestionRegionUnsupportedException {
      return OcrTypedCandidateBatch(
        candidates: <OcrTypedCandidate>[],
        failure: OcrTypedCandidateFailure.unsupportedStructure,
        candidateAssetLease: candidateAssetLease,
      );
    } on LegacyProjectionUnsupportedException {
      return OcrTypedCandidateBatch(
        candidates: <OcrTypedCandidate>[],
        failure: OcrTypedCandidateFailure.projectionUnsupported,
        candidateAssetLease: candidateAssetLease,
      );
    } catch (_) {
      return OcrTypedCandidateBatch(
        candidates: <OcrTypedCandidate>[],
        failure: OcrTypedCandidateFailure.internalError,
        candidateAssetLease: candidateAssetLease,
      );
    }
  }

  return OcrTypedCandidateBatch(
    candidates: candidates,
    candidateAssetLease: candidateAssetLease,
  );
}

/// Handler used by tests to capture the redacted construction boundary between
/// the OCR region, typed region, and assembled draft.
@visibleForTesting
void Function(Map<String, Object?> telemetry)?
    typedCandidateConstructionTelemetryHandlerForTesting;

/// Emits construction diagnostics without becoming part of candidate
/// semantics. Collection, observation, and logging are all best-effort so a
/// telemetry failure cannot change the candidate or projection result.
void _emitTypedCandidateConstructionTelemetry({
  required OcrQuestionRegion region,
  required QuestionRegion typedRegion,
  required QuestionDraftV2 draft,
}) {
  try {
    final telemetry = _collectTypedCandidateConstructionTelemetry(
      region: region,
      typedRegion: typedRegion,
      draft: draft,
    );
    typedCandidateConstructionTelemetryHandlerForTesting?.call(telemetry);
    AppLogger.info(
      'Typed candidate construction telemetry',
      module: 'ImportTypedCandidate',
      data: telemetry,
    );
  } catch (_) {
    // Diagnostic observation is deliberately non-authoritative.
  }
}

Map<String, Object?> _collectTypedCandidateConstructionTelemetry({
  required OcrQuestionRegion region,
  required QuestionRegion typedRegion,
  required QuestionDraftV2 draft,
}) {
  final ocrRegionStem = region.stemText;
  final stemOwnedSources = region.ownedSources
      .where((owned) => owned.field == OcrRegionField.stem)
      .toList(growable: false);
  final stemFragments = typedRegion.fragmentsFor(QuestionRegionField.stem);
  final typedMaterializedStem =
      _diagnosticMaterializedTypedRegionContent(stemFragments);
  final draftStem =
      const RichContentTextProjection().project(draft.stem).trim();
  final ocrRegionAnswer = region.answerText;
  final answerOwnedSources = region.ownedSources
      .where((owned) => owned.field == OcrRegionField.answer)
      .toList(growable: false);
  final answerFragments = typedRegion.fragmentsFor(QuestionRegionField.answer);
  final bridgeMaterializedAnswer =
      _diagnosticMaterializedTypedRegionContent(answerFragments);
  final draftAnswerProjection = _diagnosticAnswerProjection(draft.answer);
  final ocrMetrics = _diagnosticCharacterMetrics(ocrRegionStem);
  final materializedMetrics =
      _diagnosticCharacterMetrics(typedMaterializedStem);
  final draftMetrics = _diagnosticCharacterMetrics(draftStem);

  var sourceContentCount = 0;
  var sourceAssetCount = 0;
  var sourceTableCount = 0;
  var unsupportedCount = 0;
  for (final fragment in stemFragments) {
    switch (fragment.part) {
      case SourceContentPart():
        sourceContentCount++;
      case SourceAssetPart():
        sourceAssetCount++;
      case SourceTablePart():
        sourceTableCount++;
      case UnsupportedSourcePart():
        unsupportedCount++;
    }
  }

  return <String, Object?>{
    'questionNumber': region.number,
    'ocrRegionStemPartCount': region.stemParts.length,
    'ocrRegionStemTextLength': ocrRegionStem.length,
    'ocrRegionStemSpaceCount': ocrMetrics.spaceCount,
    'ocrRegionStemTabCount': ocrMetrics.tabCount,
    'ocrRegionStemCrCount': ocrMetrics.crCount,
    'ocrRegionStemLfCount': ocrMetrics.lfCount,
    'ocrRegionStemRepeatedHorizontalWhitespaceRuns':
        ocrMetrics.repeatedHorizontalWhitespaceRuns,
    'ocrRegionStemTripleNewlineRuns': ocrMetrics.tripleNewlineRuns,
    'ownedSourceCount': stemOwnedSources.length,
    'ownedSourceWithExplicitStartCount': stemOwnedSources
        .where((owned) => owned.startCodeUnitOffset != null)
        .length,
    'ownedSourceWithExplicitEndCount': stemOwnedSources
        .where((owned) => owned.endCodeUnitOffset != null)
        .length,
    'ownedSourceWithBothOffsetsCount': stemOwnedSources
        .where(
          (owned) =>
              owned.startCodeUnitOffset != null &&
              owned.endCodeUnitOffset != null,
        )
        .length,
    'typedRegionStemFragmentCount': stemFragments.length,
    'typedRegionStemFragmentWithSliceCount':
        stemFragments.where((fragment) => fragment.slice != null).length,
    'typedRegionStemFragmentWithoutSliceCount':
        stemFragments.where((fragment) => fragment.slice == null).length,
    'typedRegionStemSourceContentCount': sourceContentCount,
    'typedRegionStemSourceAssetCount': sourceAssetCount,
    'typedRegionStemSourceTableCount': sourceTableCount,
    'typedRegionStemUnsupportedCount': unsupportedCount,
    'typedRegionMaterializedStemLength': typedMaterializedStem.length,
    'typedRegionMaterializedStemSpaceCount': materializedMetrics.spaceCount,
    'typedRegionMaterializedStemTabCount': materializedMetrics.tabCount,
    'typedRegionMaterializedStemCrCount': materializedMetrics.crCount,
    'typedRegionMaterializedStemLfCount': materializedMetrics.lfCount,
    'draftStemProjectedLength': draftStem.length,
    'draftStemSpaceCount': draftMetrics.spaceCount,
    'draftStemTabCount': draftMetrics.tabCount,
    'draftStemCrCount': draftMetrics.crCount,
    'draftStemLfCount': draftMetrics.lfCount,
    'ocrRegionVsTypedMaterializedExactEqual':
        ocrRegionStem == typedMaterializedStem,
    'ocrRegionVsTypedMaterializedDiagnosticNormalizedEqual':
        _diagnosticOcrNormalization(ocrRegionStem) ==
            _diagnosticOcrNormalization(typedMaterializedStem),
    'typedMaterializedVsDraftExactEqual': typedMaterializedStem == draftStem,
    'typedMaterializedVsDraftDiagnosticNormalizedEqual':
        _diagnosticOcrNormalization(typedMaterializedStem) ==
            _diagnosticOcrNormalization(draftStem),
    'regionAnswerPartCount': region.answerParts.length,
    'regionAnswerLength': ocrRegionAnswer.length,
    'bridgeMaterializedAnswerLength': bridgeMaterializedAnswer.length,
    'regionVsBridgeExactEqual': ocrRegionAnswer == bridgeMaterializedAnswer,
    'answerFragmentCount': answerFragments.length,
    'answerFragmentsWithSlice':
        answerFragments.where((fragment) => fragment.slice != null).length,
    'answerFragmentsWithoutSlice':
        answerFragments.where((fragment) => fragment.slice == null).length,
    'ownedAnswerSourceCount': answerOwnedSources.length,
    'draftAnswerKind': _diagnosticAnswerKind(draft.answer),
    'draftAnswerProjectedLength': draftAnswerProjection.length,
  };
}

String _diagnosticMaterializedTypedRegionContent(
  List<QuestionRegionFragment> fragments,
) {
  final nodes = <ContentNode>[];
  var lastFragmentWasPlainText = false;
  for (final fragment in fragments) {
    switch (fragment.part) {
      case SourceContentPart(:final content):
        final materialized = materializeQuestionRegionContent(
          content,
          fragment.slice,
        );
        if (_diagnosticStructurallyEmpty(materialized)) {
          continue;
        }
        final plainText = materialized.isNotEmpty &&
            materialized.every((node) => node is TextNode);
        if (nodes.isNotEmpty && lastFragmentWasPlainText && plainText) {
          nodes.add(const TextNode('\n'));
        }
        nodes.addAll(materialized);
        lastFragmentWasPlainText = plainText;
      case SourceAssetPart(:final asset, :final alternativeText):
        nodes.add(
          ImageNode(
            sourceId: fragment.part.sourceRef.sourceId,
            localAssetId: asset.assetId,
            alternativeText: alternativeText,
          ),
        );
        lastFragmentWasPlainText = false;
      case SourceTablePart(:final structure):
        if (structure == null) {
          throw StateError(
              'Diagnostic materialization requires table geometry.');
        }
        nodes.add(TableNode(structure: structure));
        lastFragmentWasPlainText = false;
      case UnsupportedSourcePart():
        throw StateError('Unsupported diagnostic region fragment.');
    }
  }
  return const RichContentTextProjection().project(RichContent(nodes: nodes));
}

bool _diagnosticStructurallyEmpty(List<ContentNode> nodes) {
  return nodes.isEmpty ||
      nodes.every((node) => node is TextNode && node.text.trim().isEmpty);
}

String _diagnosticAnswerKind(QuestionAnswer? answer) {
  return switch (answer) {
    null => 'none',
    ChoiceAnswer() => 'choice',
    ContentAnswer() => 'content',
  };
}

String _diagnosticAnswerProjection(QuestionAnswer? answer) {
  return switch (answer) {
    null => '',
    ChoiceAnswer(:final optionIds) => optionIds.join(),
    ContentAnswer(:final content) =>
      const RichContentTextProjection().project(content),
  };
}

({
  int spaceCount,
  int tabCount,
  int crCount,
  int lfCount,
  int repeatedHorizontalWhitespaceRuns,
  int tripleNewlineRuns,
}) _diagnosticCharacterMetrics(String input) {
  var spaceCount = 0;
  var tabCount = 0;
  var crCount = 0;
  var lfCount = 0;
  for (final codeUnit in input.codeUnits) {
    switch (codeUnit) {
      case 0x20:
        spaceCount++;
      case 0x09:
        tabCount++;
      case 0x0d:
        crCount++;
      case 0x0a:
        lfCount++;
    }
  }
  return (
    spaceCount: spaceCount,
    tabCount: tabCount,
    crCount: crCount,
    lfCount: lfCount,
    repeatedHorizontalWhitespaceRuns:
        RegExp(r'[ \t]{2,}').allMatches(input).length,
    tripleNewlineRuns: RegExp(r'\n{3,}').allMatches(input).length,
  );
}

/// Diagnostic mirror only; this is not a semantic normalization authority and
/// must never feed a candidate, projection, or gate decision.
String _diagnosticOcrNormalization(String input) {
  return input
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// The all-or-nothing storage outcome of the final parity gate.
final class OcrTypedCandidateGateResult {
  const OcrTypedCandidateGateResult({
    required this.questions,
    required this.route,
    required this.reason,
    this.candidateAssetLease,
  });

  final List<Map<String, dynamic>> questions;
  final ImportStorageRoute route;
  final String? reason;
  final ContentAssetCandidateLease? candidateAssetLease;
}

/// Applies the R7B eligibility gate over one OCR batch after the final
/// `finalizeAndAuditImportQuestions` pass.
///
/// All checks are batch-wide: any failure returns the original questions
/// without any `_typed_review_v1` envelope and a single fixed reason. Only
/// when every check passes are envelopes attached to a freshly constructed
/// question list in one atomic step. Eligible R7C batches activate the typed
/// route with [ocrTypedCandidateReadyReason]; ineligible batches stay
/// [ImportStorageRoute.legacyV1] with their fixed failure reason.
OcrTypedCandidateGateResult applyOcrTypedCandidateGate({
  required OcrTypedCandidateBatch batch,
  required List<Map<String, dynamic>> finalQuestions,
  required bool singleFile,
  ContentAssetAuthority? contentAssetAuthority,
}) {
  if (!singleFile) {
    return _ineligible(
      finalQuestions,
      ocrTypedCandidateFailureReason(OcrTypedCandidateFailure.notSingleFile),
    );
  }
  if (batch.failure != null) {
    return _ineligible(
      finalQuestions,
      ocrTypedCandidateFailureReason(batch.failure!),
    );
  }

  final candidates = batch.candidates;
  if (candidates.length != finalQuestions.length) {
    return _ineligible(
      finalQuestions,
      ocrTypedCandidateFailureReason(OcrTypedCandidateFailure.countMismatch),
    );
  }

  final reviewItemIds = <String>{};
  final questionIds = <String>{};
  for (final candidate in candidates) {
    if (!isCanonicalUuidV4(candidate.reviewItemId) ||
        !isCanonicalUuidV4(candidate.questionId) ||
        !reviewItemIds.add(candidate.reviewItemId) ||
        !questionIds.add(candidate.questionId)) {
      return _ineligible(
        finalQuestions,
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.identityMismatch,
        ),
      );
    }
    for (final sourceRef in candidate.draft.sourceRefs) {
      if (!isCanonicalUuidV4(sourceRef.sourceId)) {
        return _ineligible(
          finalQuestions,
          ocrTypedCandidateFailureReason(
            OcrTypedCandidateFailure.identityMismatch,
          ),
        );
      }
    }
  }

  final finalNumbers = <int>[];
  for (final question in finalQuestions) {
    final rawNumber = question['question_number'];
    if (rawNumber is! int || rawNumber <= 0) {
      return _ineligible(
        finalQuestions,
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.identityMismatch,
        ),
      );
    }
    finalNumbers.add(rawNumber);
  }
  final candidateNumbers =
      candidates.map((candidate) => candidate.questionNumber).toList();
  if (candidateNumbers.toSet().length != candidateNumbers.length ||
      finalNumbers.toSet().length != finalNumbers.length ||
      !_sameNumberSet(candidateNumbers, finalNumbers)) {
    return _ineligible(
      finalQuestions,
      ocrTypedCandidateFailureReason(OcrTypedCandidateFailure.identityMismatch),
    );
  }

  final byNumber = <int, OcrTypedCandidate>{
    for (final candidate in candidates) candidate.questionNumber: candidate,
  };
  final baselines = <int, LegacyReviewBaseline>{};
  for (final question in finalQuestions) {
    final number = question['question_number'] as int;
    final baseline = _strictDecodeBaseline(question);
    if (baseline == null) {
      return _ineligible(
        finalQuestions,
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.baselineInvalid,
        ),
      );
    }
    baselines[number] = baseline;
  }

  for (final question in finalQuestions) {
    final number = question['question_number'] as int;
    final candidate = byNumber[number]!;
    if (!_rawExplanationAllowed(
      question,
      baselines[number]!.explanation,
      candidate,
    )) {
      return _ineligible(
        finalQuestions,
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.rawExplanationDiverged,
        ),
      );
    }
  }

  for (final question in finalQuestions) {
    final number = question['question_number'] as int;
    final candidate = byNumber[number]!;
    _emitProjectionParityTelemetryForGate(
      questionNumber: number,
      question: question,
      baseline: baselines[number]!,
      candidate: candidate,
    );
    if (!_baselineParity(baselines[number]!, candidate) ||
        !_provenanceParity(candidate, question)) {
      return _ineligible(
        finalQuestions,
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.projectionMismatch,
        ),
      );
    }
  }

  // Preserve the existing first-failure order through provenance. Asset
  // admission is the final pre-snapshot gate and remains batch-wide.
  for (final candidate in candidates) {
    final failure = _candidateStructureFailure(
      candidate: candidate,
      candidateAssetLease: batch.candidateAssetLease,
      contentAssetAuthority: contentAssetAuthority,
    );
    if (failure != null) {
      return _ineligible(
        finalQuestions,
        ocrTypedCandidateFailureReason(failure),
      );
    }
  }

  const codec = TypedReviewSnapshotCodec();
  final attached = <Map<String, dynamic>>[];
  for (final question in finalQuestions) {
    final number = question['question_number'] as int;
    final candidate = byNumber[number]!;
    final baseline = baselines[number]!;
    try {
      final snapshot = TypedReviewSnapshot(
        reviewItemId: candidate.reviewItemId,
        questionId: candidate.questionId,
        draft: candidate.draft,
        baselineLegacy: baseline,
      );
      final envelope = codec.encode(snapshot);
      final decoded = codec.decodeRequired(envelope);
      if (decoded.reviewItemId != snapshot.reviewItemId ||
          decoded.questionId != snapshot.questionId ||
          decoded.baselineLegacy != baseline ||
          decoded.draft != candidate.draft) {
        return _ineligible(
          finalQuestions,
          ocrTypedCandidateFailureReason(
            OcrTypedCandidateFailure.snapshotInvalid,
          ),
        );
      }
      attached.add(<String, dynamic>{
        ...question,
        TypedReviewSnapshotCodec.mapKey: envelope,
      });
    } on TypedReviewSnapshotException {
      return _ineligible(
        finalQuestions,
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.snapshotInvalid,
        ),
      );
    }
  }

  return OcrTypedCandidateGateResult(
    questions: List<Map<String, dynamic>>.unmodifiable(attached),
    route: ImportStorageRoute.typedV2,
    reason: ocrTypedCandidateReadyReason,
    candidateAssetLease: batch.candidateAssetLease,
  );
}

OcrTypedCandidateGateResult _ineligible(
  List<Map<String, dynamic>> questions,
  String reason,
) {
  return OcrTypedCandidateGateResult(
    questions: List<Map<String, dynamic>>.unmodifiable(<Map<String, dynamic>>[
      for (final question in questions)
        <String, dynamic>{
          for (final entry in question.entries)
            if (entry.key != TypedReviewSnapshotCodec.mapKey)
              entry.key: entry.value,
        },
    ]),
    route: ImportStorageRoute.legacyV1,
    reason: reason,
  );
}

/// Strict six-field baseline decode from the final legacy map. Any shape
/// anomaly (wrong type, non-string option, negative or missing number)
/// returns null; no `toString()` repair or silent option drop is allowed.
LegacyReviewBaseline? _strictDecodeBaseline(Map<String, dynamic> question) {
  final type = question['type'];
  final number = question['question_number'];
  final content = question['content'];
  final options = question['options'];
  final standardAnswer = question['standard_answer'];
  final explanation = question['explanation'];
  if (type is! int ||
      number is! int ||
      number <= 0 ||
      content is! String ||
      options is! List ||
      standardAnswer is! String ||
      explanation is! String) {
    return null;
  }
  try {
    return LegacyReviewBaseline(
      type: type,
      questionNumber: number,
      content: content,
      options: List<String>.from(options),
      standardAnswer: standardAnswer,
      explanation: explanation,
    );
  } on TypedReviewSnapshotException {
    return null;
  } on TypeError {
    return null;
  }
}

/// Handler used by tests to capture telemetry emitted during gate evaluation.
@visibleForTesting
void Function(Map<String, Object?> telemetry)?
    rawExplanationTelemetryHandlerForTesting;

void _emitRawExplanationTelemetry(Map<String, Object?> telemetry) {
  rawExplanationTelemetryHandlerForTesting?.call(telemetry);
  AppLogger.info(
    'Raw explanation parity telemetry',
    module: 'ImportGate',
    data: telemetry,
  );
}

/// Handler used by tests to capture the redacted baseline/provenance
/// diagnostic emitted at the projection gate.
@visibleForTesting
void Function(Map<String, Object?> telemetry)?
    projectionParityTelemetryHandlerForTesting;

/// Emits projection diagnostics without becoming part of gate semantics.
/// Telemetry is best-effort: a logger or test observer failure must not change
/// the existing candidate admission result.
void _emitProjectionParityTelemetryForGate({
  required int questionNumber,
  required Map<String, dynamic> question,
  required LegacyReviewBaseline baseline,
  required OcrTypedCandidate candidate,
}) {
  try {
    final telemetry = _collectProjectionParityTelemetry(
      questionNumber: questionNumber,
      question: question,
      baseline: baseline,
      candidate: candidate,
    );
    projectionParityTelemetryHandlerForTesting?.call(telemetry);
    AppLogger.info(
      'Typed candidate projection parity telemetry',
      module: 'ImportGate',
      data: telemetry,
    );
  } catch (_) {
    // Diagnostic observation is deliberately non-authoritative.
  }
}

Map<String, Object?> _collectProjectionParityTelemetry({
  required int questionNumber,
  required Map<String, dynamic> question,
  required LegacyReviewBaseline baseline,
  required OcrTypedCandidate candidate,
}) {
  final baselineEvaluation = _evaluateBaselineParity(baseline, candidate);
  final provenanceEvaluation = _evaluateProvenanceParity(candidate, question);
  final baselineParity = _baselineParity(baseline, candidate);
  final provenanceParity = _provenanceParity(candidate, question);
  final firstMismatchField = !baselineParity
      ? baselineEvaluation.firstMismatchField
      : !provenanceParity
          ? provenanceEvaluation.firstMismatchField
          : 'none';

  return <String, Object?>{
    'questionNumber': questionNumber,
    'baselineParity': baselineParity,
    'provenanceParity': provenanceParity,
    'typeEqual': baselineEvaluation.typeEqual,
    'questionNumberEqual': baselineEvaluation.questionNumberEqual,
    'contentEqual': baselineEvaluation.content.equal,
    'contentN0Equal': baselineEvaluation.content.n0Equal,
    'contentFinalizerEligible': baselineEvaluation.content.finalizerEligible,
    'contentFinalizerMatched': baselineEvaluation.content.finalizerMatched,
    'baselineContentLength': baselineEvaluation.content.baselineLength,
    'projectedContentLength': baselineEvaluation.content.projectedLength,
    'optionsEqual': baselineEvaluation.optionsEqual,
    'optionCountEqual': baselineEvaluation.optionCountEqual,
    'firstMismatchedOptionIndex': baselineEvaluation.firstMismatchedOptionIndex,
    'baselineOptionCount': baseline.options.length,
    'projectedOptionCount': candidate.projectedLegacy.options.length,
    'baselineOptionsTotalLength': _totalStringLength(baseline.options),
    'projectedOptionsTotalLength':
        _totalStringLength(candidate.projectedLegacy.options),
    'standardAnswerEqual': baselineEvaluation.standardAnswer.equal,
    'standardAnswerN0Equal': baselineEvaluation.standardAnswer.n0Equal,
    'standardAnswerFinalizerEligible':
        baselineEvaluation.standardAnswer.finalizerEligible,
    'standardAnswerFinalizerMatched':
        baselineEvaluation.standardAnswer.finalizerMatched,
    'baselineAnswerLength': baselineEvaluation.standardAnswer.baselineLength,
    'projectedAnswerLength': baselineEvaluation.standardAnswer.projectedLength,
    'explanationEqual': baselineEvaluation.explanation.text.equal,
    'explanationN0Equal': baselineEvaluation.explanation.text.n0Equal,
    'explanationParityAllowed': baselineEvaluation.explanation.parityAllowed,
    'explanationFinalizerEligible':
        baselineEvaluation.explanation.text.finalizerEligible,
    'explanationFinalizerMatched':
        baselineEvaluation.explanation.text.finalizerMatched,
    'baselineExplanationLength':
        baselineEvaluation.explanation.text.baselineLength,
    'projectedExplanationLength':
        baselineEvaluation.explanation.text.projectedLength,
    'pageCountEqual': provenanceEvaluation.pageCountEqual,
    'pageOrderEqual': provenanceEvaluation.pageOrderEqual,
    'finalPageCount': provenanceEvaluation.finalPageCount,
    'candidatePageCount': provenanceEvaluation.candidatePageCount,
    'blockCountEqual': provenanceEvaluation.blockCountEqual,
    'blockOrderEqual': provenanceEvaluation.blockOrderEqual,
    'finalBlockCount': provenanceEvaluation.finalBlockCount,
    'candidateBlockCount': provenanceEvaluation.candidateBlockCount,
    'firstMismatchField': firstMismatchField,
  };
}

int _totalStringLength(Iterable<String> values) {
  var total = 0;
  for (final value in values) {
    total += value.length;
  }
  return total;
}

final class _TextParityEvaluation {
  const _TextParityEvaluation({
    required this.equal,
    required this.n0Equal,
    required this.finalizerEligible,
    required this.finalizerMatched,
    required this.baselineLength,
    required this.projectedLength,
  });

  final bool equal;
  final bool n0Equal;
  final bool finalizerEligible;
  final bool finalizerMatched;
  final int baselineLength;
  final int projectedLength;
}

final class _ExplanationParityEvaluation {
  const _ExplanationParityEvaluation({
    required this.text,
    required this.parityAllowed,
  });

  final _TextParityEvaluation text;
  final bool parityAllowed;
}

final class _BaselineParityEvaluation {
  const _BaselineParityEvaluation({
    required this.typeEqual,
    required this.questionNumberEqual,
    required this.content,
    required this.optionsEqual,
    required this.optionCountEqual,
    required this.firstMismatchedOptionIndex,
    required this.standardAnswer,
    required this.explanation,
  });

  final bool typeEqual;
  final bool questionNumberEqual;
  final _TextParityEvaluation content;
  final bool optionsEqual;
  final bool optionCountEqual;
  final int? firstMismatchedOptionIndex;
  final _TextParityEvaluation standardAnswer;
  final _ExplanationParityEvaluation explanation;

  bool get parity =>
      typeEqual &&
      questionNumberEqual &&
      content.equal &&
      optionsEqual &&
      standardAnswer.equal &&
      (explanation.text.equal || explanation.parityAllowed);

  String get firstMismatchField {
    if (!typeEqual) return 'type';
    if (!questionNumberEqual) return 'questionNumber';
    if (!content.equal) return 'content';
    if (!optionsEqual) return 'options';
    if (!standardAnswer.equal) return 'standardAnswer';
    if (!explanation.text.equal && !explanation.parityAllowed) {
      return 'explanation';
    }
    return 'none';
  }
}

final class _ProvenanceParityEvaluation {
  const _ProvenanceParityEvaluation({
    required this.pageCountEqual,
    required this.pageOrderEqual,
    required this.finalPageCount,
    required this.candidatePageCount,
    required this.blockCountEqual,
    required this.blockOrderEqual,
    required this.finalBlockCount,
    required this.candidateBlockCount,
  });

  final bool pageCountEqual;
  final bool pageOrderEqual;
  final int? finalPageCount;
  final int candidatePageCount;
  final bool blockCountEqual;
  final bool blockOrderEqual;
  final int? finalBlockCount;
  final int candidateBlockCount;

  String get firstMismatchField {
    if (!pageCountEqual || !pageOrderEqual) return 'pageIndices';
    if (!blockCountEqual || !blockOrderEqual) return 'blockIds';
    return 'none';
  }
}

_BaselineParityEvaluation _evaluateBaselineParity(
  LegacyReviewBaseline baseline,
  OcrTypedCandidate candidate,
) {
  final projected = candidate.projectedLegacy;
  final content = _compareParityText(
    projected: projected.content,
    baseline: baseline.content,
  );
  final standardAnswer = _compareParityText(
    projected: projected.standardAnswer,
    baseline: baseline.standardAnswer,
  );
  final explanationText = _compareParityText(
    projected: projected.explanation,
    baseline: baseline.explanation,
  );
  final explanation = _ExplanationParityEvaluation(
    text: explanationText,
    parityAllowed: _explanationParityAllowed(
      source: projected.explanation,
      target: baseline.explanation,
      candidate: candidate,
    ),
  );
  final optionsEqual = _sameOrderedStrings(baseline.options, projected.options);
  return _BaselineParityEvaluation(
    typeEqual: baseline.type == projected.type,
    questionNumberEqual: baseline.questionNumber == projected.questionNumber,
    content: content,
    optionsEqual: optionsEqual,
    optionCountEqual: baseline.options.length == projected.options.length,
    firstMismatchedOptionIndex: _firstMismatchedOptionIndex(
      baseline.options,
      projected.options,
    ),
    standardAnswer: standardAnswer,
    explanation: explanation,
  );
}

_TextParityEvaluation _compareParityText({
  required String projected,
  required String baseline,
}) {
  final finalized = finalizeImportTextForParityComparison(projected);
  return _TextParityEvaluation(
    equal: projected == baseline,
    n0Equal: _n0Equals(projected, baseline),
    finalizerEligible: finalized.eligible,
    finalizerMatched: finalized.eligible && finalized.text == baseline,
    baselineLength: baseline.length,
    projectedLength: projected.length,
  );
}

int? _firstMismatchedOptionIndex(
  List<String> baseline,
  List<String> projected,
) {
  final commonLength =
      baseline.length < projected.length ? baseline.length : projected.length;
  for (var index = 0; index < commonLength; index++) {
    if (baseline[index] != projected[index]) return index;
  }
  return null;
}

_ProvenanceParityEvaluation _evaluateProvenanceParity(
  OcrTypedCandidate candidate,
  Map<String, dynamic> question,
) {
  final pages = question['source_page_indices'];
  final blocks = question['source_block_ids'];
  final finalPageCount = pages is List ? pages.length : null;
  final finalBlockCount = blocks is List ? blocks.length : null;
  final pageCountEqual =
      pages is List && pages.length == candidate.sourcePageIndices.length;
  final blockCountEqual =
      blocks is List && blocks.length == candidate.sourceBlockIds.length;
  return _ProvenanceParityEvaluation(
    pageCountEqual: pageCountEqual,
    pageOrderEqual: pageCountEqual &&
        _sameOrderedPageIndices(pages, candidate.sourcePageIndices),
    finalPageCount: finalPageCount,
    candidatePageCount: candidate.sourcePageIndices.length,
    blockCountEqual: blockCountEqual,
    blockOrderEqual: blockCountEqual &&
        _sameOrderedBlockIds(blocks, candidate.sourceBlockIds),
    finalBlockCount: finalBlockCount,
    candidateBlockCount: candidate.sourceBlockIds.length,
  );
}

bool _sameOrderedPageIndices(Object? value, List<int> expected) {
  if (value is! List || value.length != expected.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (value[index] != expected[index]) return false;
  }
  return true;
}

bool _sameOrderedBlockIds(Object? value, List<String> expected) {
  if (value is! List || value.length != expected.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (value[index] != expected[index]) return false;
  }
  return true;
}

Map<String, Object?> _collectRawExplanationTelemetry({
  required Map<String, dynamic> question,
  required String finalExplanation,
  required OcrTypedCandidate candidate,
}) {
  final rawPresent = question.containsKey('raw_explanation') &&
      question['raw_explanation'] != null;
  final raw = question['raw_explanation'];
  final rawTypeValid = raw is String;
  final rawEmpty = rawTypeValid ? raw.isEmpty : false;
  final rawEqualsFinal = rawTypeValid ? raw == finalExplanation : false;
  final finalEmpty = finalExplanation.isEmpty;
  final candidateExplanation = candidate.draft.explanation;
  final candidateExplanationPresent = candidateExplanation != null;
  final topLevelNodeKinds = _topLevelNodeKinds(candidateExplanation);
  final rawFallbackLocation =
      _rawFallbackLocationForExplanation(candidateExplanation);
  final containsRawFallback = rawFallbackLocation != null;
  final boundedAllowed = _boundedExplanationParityAllowed(candidate);

  var n0Equal = false;
  var finalizerEligible = false;
  var finalizerMatched = false;
  if (rawTypeValid) {
    n0Equal = _n0Equals(raw, finalExplanation);
    final finalized = finalizeImportTextForParityComparison(raw);
    finalizerEligible = finalized.eligible;
    finalizerMatched = finalized.eligible && finalized.text == finalExplanation;
  }

  final rawNumber = question['question_number'];
  final questionNumber = switch (rawNumber) {
    final int number when number > 0 => number,
    final num number when number > 0 => number.toInt(),
    _ => candidate.questionNumber,
  };

  return <String, Object?>{
    'questionNumber': questionNumber,
    'rawPresent': rawPresent,
    'rawTypeValid': rawTypeValid,
    'rawEmpty': rawEmpty,
    'rawEqualsFinal': rawEqualsFinal,
    'finalEmpty': finalEmpty,
    'candidateExplanationPresent': candidateExplanationPresent,
    'topLevelNodeKinds': topLevelNodeKinds,
    'containsRawFallback': containsRawFallback,
    'rawFallbackLocation': rawFallbackLocation,
    'boundedAllowed': boundedAllowed,
    'n0Equal': n0Equal,
    'finalizerEligible': finalizerEligible,
    'finalizerMatched': finalizerMatched,
  };
}

List<String> _topLevelNodeKinds(RichContent? explanation) {
  if (explanation == null) return const <String>[];
  return explanation.nodes
      .map((node) => switch (node) {
            TextNode() => 'text',
            InlineMathNode() => 'inlineMath',
            BlockMathNode() => 'blockMath',
            ImageNode() => 'image',
            TableNode() => 'table',
            RawFallbackNode() => 'rawFallback',
          })
      .toList(growable: false);
}

String? _rawFallbackLocationForExplanation(RichContent? explanation) {
  if (explanation == null) return null;
  for (final node in explanation.nodes) {
    if (node is RawFallbackNode) {
      return 'top-level';
    }
  }
  for (final node in explanation.nodes) {
    if (node is ImageNode) {
      final alt = node.alternativeText;
      if (alt != null && _containsRawFallbackNodes(alt.nodes)) {
        return 'image-alt';
      }
    }
  }
  for (final node in explanation.nodes) {
    if (node is TableNode) {
      for (final row in node.structure.rows) {
        for (final cell in row.cells) {
          if (_containsRawFallbackNodes(cell.content.nodes)) {
            return 'table-cell';
          }
        }
      }
    }
  }
  return null;
}

bool _containsRawFallbackNodes(Iterable<ContentNode> nodes) {
  for (final node in nodes) {
    switch (node) {
      case RawFallbackNode():
        return true;
      case ImageNode(:final alternativeText):
        if (alternativeText != null &&
            _containsRawFallbackNodes(alternativeText.nodes)) {
          return true;
        }
      case TableNode(:final structure):
        for (final row in structure.rows) {
          for (final cell in row.cells) {
            if (_containsRawFallbackNodes(cell.content.nodes)) {
              return true;
            }
          }
        }
      case TextNode():
      case InlineMathNode():
      case BlockMathNode():
        break;
    }
  }
  return false;
}

bool _rawExplanationAllowed(
  Map<String, dynamic> question,
  String finalExplanation,
  OcrTypedCandidate candidate,
) {
  final telemetry = _collectRawExplanationTelemetry(
    question: question,
    finalExplanation: finalExplanation,
    candidate: candidate,
  );
  _emitRawExplanationTelemetry(telemetry);

  final raw = question['raw_explanation'];
  if (raw == null) return true;
  if (raw is! String) return false;
  if (raw.isEmpty || raw == finalExplanation) return true;
  if (finalExplanation.isEmpty) return false;
  return _explanationParityAllowed(
    source: raw,
    target: finalExplanation,
    candidate: candidate,
  );
}

bool _baselineParity(
  LegacyReviewBaseline baseline,
  OcrTypedCandidate candidate,
) {
  final projected = candidate.projectedLegacy;
  if (baseline == projected) return true;
  if (baseline.type != projected.type ||
      baseline.questionNumber != projected.questionNumber ||
      baseline.content != projected.content ||
      !_sameOrderedStrings(baseline.options, projected.options) ||
      baseline.standardAnswer != projected.standardAnswer) {
    return false;
  }
  return _explanationParityAllowed(
    source: projected.explanation,
    target: baseline.explanation,
    candidate: candidate,
  );
}

bool _explanationParityAllowed({
  required String source,
  required String target,
  required OcrTypedCandidate candidate,
}) {
  if (!_boundedExplanationParityAllowed(candidate)) return false;
  if (_n0Equals(source, target)) return true;
  final finalized = finalizeImportTextForParityComparison(source);
  return finalized.eligible && finalized.text == target;
}

bool _boundedExplanationParityAllowed(OcrTypedCandidate candidate) {
  final explanation = candidate.draft.explanation;
  return explanation != null &&
      _boundedExplanationNodesAllowed(explanation.nodes);
}

bool _boundedExplanationNodesAllowed(Iterable<ContentNode> nodes) {
  for (final node in nodes) {
    switch (node) {
      case TextNode():
      case InlineMathNode():
      case BlockMathNode():
        break;
      case ImageNode(:final alternativeText):
        if (alternativeText != null &&
            !_boundedExplanationNodesAllowed(alternativeText.nodes)) {
          return false;
        }
      case TableNode(:final structure):
        for (final row in structure.rows) {
          for (final cell in row.cells) {
            if (!_boundedExplanationNodesAllowed(cell.content.nodes)) {
              return false;
            }
          }
        }
      case RawFallbackNode():
        return false;
    }
  }
  return true;
}

OcrTypedCandidateFailure? _candidateStructureFailure({
  required OcrTypedCandidate candidate,
  required ContentAssetCandidateLease? candidateAssetLease,
  required ContentAssetAuthority? contentAssetAuthority,
}) {
  final explanation = candidate.draft.explanation;
  if (explanation != null &&
      !_boundedExplanationNodesAllowed(explanation.nodes)) {
    return OcrTypedCandidateFailure.unsupportedStructure;
  }

  final images = <ImageNode>[
    ...reachableImageNodes(candidate.draft.stem),
    for (final option in candidate.draft.options)
      ...reachableImageNodes(option.content),
    if (candidate.draft.answer case ContentAnswer(:final content))
      ...reachableImageNodes(content),
    if (explanation != null) ...reachableImageNodes(explanation),
  ];
  if (images.isEmpty) return null;

  final lease = candidateAssetLease;
  if (lease == null) return OcrTypedCandidateFailure.identityMismatch;
  final leasedAssetIds = lease.localAssetIds.toSet();
  final assetsByIdentity = <(String, String), SourcedAssetRef>{
    for (final asset in candidate.draft.assetRefs)
      (asset.sourceId, asset.localAssetId): asset,
  };
  for (final image in images) {
    if (image.sourceId != lease.sourceId ||
        !leasedAssetIds.contains(image.localAssetId)) {
      return OcrTypedCandidateFailure.identityMismatch;
    }
    final asset = assetsByIdentity[(image.sourceId, image.localAssetId)];
    if (asset == null || contentAssetAuthority == null) {
      return OcrTypedCandidateFailure.unsupportedStructure;
    }
    try {
      if (!contentAssetAuthority.isDurableAssetReady(asset)) {
        return OcrTypedCandidateFailure.unsupportedStructure;
      }
    } catch (_) {
      return OcrTypedCandidateFailure.unsupportedStructure;
    }
  }
  return null;
}

bool _n0Equals(String left, String right) {
  if (left == right) return true;
  final leftNormalized = _n0Scalars(left);
  final rightNormalized = _n0Scalars(right);
  if (leftNormalized == null || rightNormalized == null) return false;
  if (leftNormalized.length != rightNormalized.length) return false;
  for (var index = 0; index < leftNormalized.length; index++) {
    if (leftNormalized[index] != rightNormalized[index]) return false;
  }
  return true;
}

List<int>? _n0Scalars(String value) {
  final original = <int>[];
  for (final scalar in value.runes) {
    original.add(scalar);
    if (original.length > RichContentLimits.maxProjectionScalars) {
      return null;
    }
  }

  final normalized = <int>[];
  var skipLfAfterCr = false;
  for (final scalar in original) {
    if (skipLfAfterCr) {
      skipLfAfterCr = false;
      if (scalar == 0x0a) continue;
    }
    if (scalar == 0x0d) {
      normalized.add(0x0a);
      skipLfAfterCr = true;
    } else {
      normalized.add(scalar);
    }
  }

  var start = 0;
  while (start < normalized.length && _isN0BoundaryScalar(normalized[start])) {
    start++;
  }
  var end = normalized.length;
  while (end > start && _isN0BoundaryScalar(normalized[end - 1])) {
    end--;
  }
  return normalized.sublist(start, end);
}

bool _isN0BoundaryScalar(int scalar) {
  return scalar == 0x20 || scalar == 0x09 || scalar == 0x0a || scalar == 0x3000;
}

bool _sameOrderedStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _provenanceParity(
  OcrTypedCandidate candidate,
  Map<String, dynamic> question,
) {
  final pages = question['source_page_indices'];
  final blocks = question['source_block_ids'];
  if (pages is! List || blocks is! List) return false;
  if (pages.length != candidate.sourcePageIndices.length ||
      blocks.length != candidate.sourceBlockIds.length) {
    return false;
  }
  for (var index = 0; index < pages.length; index++) {
    if (pages[index] != candidate.sourcePageIndices[index]) return false;
  }
  for (var index = 0; index < blocks.length; index++) {
    if (blocks[index] != candidate.sourceBlockIds[index]) return false;
  }
  return true;
}

bool _sameNumberSet(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  return left.toSet().containsAll(right.toSet());
}
