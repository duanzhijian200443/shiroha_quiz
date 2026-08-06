import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
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
  }) {
    return OcrTypedCandidateBatch._(
      candidates: List<OcrTypedCandidate>.unmodifiable(candidates),
      failure: failure,
    );
  }

  const OcrTypedCandidateBatch._({
    required this.candidates,
    required this.failure,
  });

  final List<OcrTypedCandidate> candidates;
  final OcrTypedCandidateFailure? failure;
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
}) {
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

  final String sourceId;
  final SourceDocument sourceDocument;
  try {
    sourceId = uuidV4Factory();
    sourceDocument = const OcrSourceDocumentAdapter().convert(
      document,
      sourceId: sourceId,
      displayLabel: null,
    );
  } catch (_) {
    return OcrTypedCandidateBatch(
      candidates: <OcrTypedCandidate>[],
      failure: OcrTypedCandidateFailure.internalError,
    );
  }

  for (final part in sourceDocument.parts) {
    if (part is SourceAssetPart ||
        part is SourceTablePart ||
        part is UnsupportedSourcePart) {
      return OcrTypedCandidateBatch(
        candidates: <OcrTypedCandidate>[],
        failure: OcrTypedCandidateFailure.unsupportedStructure,
      );
    }
  }

  final candidates = <OcrTypedCandidate>[];
  for (final region in regions) {
    try {
      final typedRegion = const OcrQuestionRegionBridge().convert(
        region,
        sourceDocument: sourceDocument,
      );
      final questionId = uuidV4Factory();
      final draft = const TypedQuestionAssembler().assemble(
        typedRegion,
        questionId: questionId,
      );
      final projected = const QuestionDraftV2LegacyProjector().project(
        draft: draft,
        region: typedRegion,
        profile: const OcrLegacyProjectionProfile(),
      );
      final reviewItemId = uuidV4Factory();
      final projectedQuestion = projected.question;
      final baseline = LegacyReviewBaseline(
        type: projectedQuestion['type'] as int,
        questionNumber:
            (projectedQuestion['question_number'] as num?)?.toInt() ??
                region.number,
        content: projectedQuestion['content'] as String,
        options:
            List<String>.from(projectedQuestion['options'] as List<Object?>),
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
      );
    } on LegacyProjectionUnsupportedException {
      return OcrTypedCandidateBatch(
        candidates: <OcrTypedCandidate>[],
        failure: OcrTypedCandidateFailure.projectionUnsupported,
      );
    } catch (_) {
      return OcrTypedCandidateBatch(
        candidates: <OcrTypedCandidate>[],
        failure: OcrTypedCandidateFailure.internalError,
      );
    }
  }

  return OcrTypedCandidateBatch(candidates: candidates);
}

/// The all-or-nothing storage outcome of the final parity gate.
final class OcrTypedCandidateGateResult {
  const OcrTypedCandidateGateResult({
    required this.questions,
    required this.route,
    required this.reason,
  });

  final List<Map<String, dynamic>> questions;
  final ImportStorageRoute route;
  final String? reason;
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
      ocrTypedCandidateFailureReason(
        OcrTypedCandidateFailure.identityMismatch,
      ),
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
    if (!_rawExplanationAllowed(question, baselines[number]!.explanation)) {
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
    if (baselines[number]! != candidate.projectedLegacy ||
        !_provenanceParity(candidate, question)) {
      return _ineligible(
        finalQuestions,
        ocrTypedCandidateFailureReason(
          OcrTypedCandidateFailure.projectionMismatch,
        ),
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
LegacyReviewBaseline? _strictDecodeBaseline(
  Map<String, dynamic> question,
) {
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

bool _rawExplanationAllowed(
  Map<String, dynamic> question,
  String explanation,
) {
  final raw = question['raw_explanation'];
  if (raw == null) return true;
  if (raw is! String) return false;
  return raw.isEmpty || raw == explanation;
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
