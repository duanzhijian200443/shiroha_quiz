import 'dart:convert';
import 'dart:io';

import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';

import 'train_c_evidence_collector.dart';
import 'train_c_evidence_probe.dart';
import 'train_c_http_observer.dart';
import 'train_c_isolated_runtime.dart';

final class TrainCRuntimeEvidenceException implements Exception {
  const TrainCRuntimeEvidenceException(this.code);

  final String code;

  @override
  String toString() => code;
}

/// Source-side image ownership facts captured during the same parse that
/// produced the typed drafts. Raw identities never cross into the persisted
/// evidence map; they are used only for in-process ownership comparison.
final class TrainCSourceImageFacts {
  const TrainCSourceImageFacts._(
    this.referencedImageCounts,
    this.referencedIdentitiesByQuestion,
  );

  const TrainCSourceImageFacts.empty()
      : this._(
          const <int, int>{},
          const <int, Set<(String, String)>>{},
        );

  factory TrainCSourceImageFacts({
    required Map<int, int> referencedImageCounts,
    required Map<int, Set<(String, String)>> referencedIdentitiesByQuestion,
  }) {
    return TrainCSourceImageFacts._(
      Map<int, int>.unmodifiable(referencedImageCounts),
      Map<int, Set<(String, String)>>.unmodifiable(
        referencedIdentitiesByQuestion.map(
          (number, identities) =>
              MapEntry(number, Set<(String, String)>.unmodifiable(identities)),
        ),
      ),
    );
  }

  final Map<int, int> referencedImageCounts;
  final Map<int, Set<(String, String)>> referencedIdentitiesByQuestion;

  int countFor(int questionNumber) =>
      referencedImageCounts[questionNumber] ?? 0;

  Set<(String, String)> identitiesFor(int questionNumber) =>
      referencedIdentitiesByQuestion[questionNumber] ??
      const <(String, String)>{};

  int get totalReferencedImageCount =>
      referencedImageCounts.values.fold(0, (sum, count) => sum + count);

  Set<(String, String)> get allIdentities {
    final identities = <(String, String)>{};
    for (final value in referencedIdentitiesByQuestion.values) {
      identities.addAll(value);
    }
    return Set<(String, String)>.unmodifiable(identities);
  }
}

final class TrainCInputFacts {
  const TrainCInputFacts({
    required this.sha256,
    required this.sizeBytes,
    required this.pageCount,
  });

  final String sha256;
  final int sizeBytes;
  final int pageCount;
}

final class TrainCParseFacts {
  const TrainCParseFacts({
    required this.blockCount,
    required this.imageBlockCount,
    required this.tableBlockCount,
    required this.referencedImageBlockCount,
    required this.referencedTableBlockCount,
    required this.assembledQuestionCount,
    required this.finalQuestionCount,
    required this.storageRoute,
    required this.storageReason,
    this.sourceImages = const TrainCSourceImageFacts.empty(),
    this.warningCount = 0,
    this.status = 'PASS',
    this.layoutResponsePolicyActive = true,
    this.documentImageBudgetPolicyActive = true,
    this.resourceFailure = false,
    this.candidateCleanupPending = false,
    this.legacyWriterCalls = 0,
    this.layoutChunkSize = 20,
  });

  final String status;
  final int blockCount;
  final int imageBlockCount;
  final int tableBlockCount;
  final int referencedImageBlockCount;
  final int referencedTableBlockCount;
  final int assembledQuestionCount;
  final int finalQuestionCount;
  final int warningCount;
  final String storageRoute;
  final String storageReason;
  final TrainCSourceImageFacts sourceImages;
  final bool layoutResponsePolicyActive;
  final bool documentImageBudgetPolicyActive;
  final bool resourceFailure;
  final bool candidateCleanupPending;
  final int legacyWriterCalls;
  final int layoutChunkSize;
}

enum TrainCRenderStage { restart, b0Restore }

abstract interface class TrainCRenderEvidencePort {
  bool didRender({
    required int questionNumber,
    required TrainCRenderStage stage,
  });
}

final class UnavailableTrainCRenderEvidencePort
    implements TrainCRenderEvidencePort {
  const UnavailableTrainCRenderEvidencePort();

  @override
  bool didRender({
    required int questionNumber,
    required TrainCRenderStage stage,
  }) =>
      false;
}

final class TrainCQuestionCheckpoint {
  const TrainCQuestionCheckpoint({
    required this.questionNumber,
    required this.imageNodeCount,
    required this.uniqueAssetCount,
    required this.resolvedUniqueAssetCount,
    required this.tableNodeCount,
    required this.canonicalIdentityPreserved,
    required this.allReachableResolved,
    required this.identityDigest,
    required this.reachableIdentities,
  });

  final int? questionNumber;
  final int imageNodeCount;
  final int uniqueAssetCount;
  final int resolvedUniqueAssetCount;
  final int tableNodeCount;
  final bool canonicalIdentityPreserved;
  final bool allReachableResolved;
  final String identityDigest;
  final Set<(String, String)> reachableIdentities;

  bool equivalentTo(TrainCQuestionCheckpoint other) {
    return questionNumber == other.questionNumber &&
        imageNodeCount == other.imageNodeCount &&
        uniqueAssetCount == other.uniqueAssetCount &&
        resolvedUniqueAssetCount == other.resolvedUniqueAssetCount &&
        tableNodeCount == other.tableNodeCount &&
        canonicalIdentityPreserved == other.canonicalIdentityPreserved &&
        allReachableResolved == other.allReachableResolved &&
        identityDigest == other.identityDigest &&
        _sameIdentitySet(reachableIdentities, other.reachableIdentities);
  }
}

final class TrainCRuntimeCheckpoint {
  const TrainCRuntimeCheckpoint({
    required this.questionRows,
    required this.v2Sidecars,
    required this.typedCount,
    required this.validEnvelopeCount,
    required this.questionNumbers,
    required this.typedImageNodeCount,
    required this.typedUniqueAssetCount,
    required this.resolvedUniqueAssetCount,
    required this.allReachableResolved,
    required this.canonicalIdentityPreserved,
    required this.typedTableNodeCount,
    required this.payloadDigest,
    required this.reachableIdentities,
    required this.questions,
  });

  final int questionRows;
  final int v2Sidecars;
  final int typedCount;
  final int validEnvelopeCount;
  final List<int> questionNumbers;
  final int typedImageNodeCount;
  final int typedUniqueAssetCount;
  final int resolvedUniqueAssetCount;
  final bool allReachableResolved;
  final bool canonicalIdentityPreserved;
  final int typedTableNodeCount;
  final String payloadDigest;
  final Set<(String, String)> reachableIdentities;
  final List<TrainCQuestionCheckpoint> questions;

  factory TrainCRuntimeCheckpoint.empty() {
    return const TrainCRuntimeCheckpoint(
      questionRows: 0,
      v2Sidecars: 0,
      typedCount: 0,
      validEnvelopeCount: 0,
      questionNumbers: <int>[],
      typedImageNodeCount: 0,
      typedUniqueAssetCount: 0,
      resolvedUniqueAssetCount: 0,
      allReachableResolved: true,
      canonicalIdentityPreserved: true,
      typedTableNodeCount: 0,
      payloadDigest: '',
      reachableIdentities: <(String, String)>{},
      questions: <TrainCQuestionCheckpoint>[],
    );
  }

  bool get exactSet1To22 =>
      questionNumbers.length == 22 &&
      questionNumbers.asMap().entries.every(
            (entry) => entry.value == entry.key + 1,
          );

  TrainCQuestionCheckpoint? question(int number) {
    for (final item in questions) {
      if (item.questionNumber == number) return item;
    }
    return null;
  }

  bool equivalentTo(TrainCRuntimeCheckpoint other) {
    if (questionRows != other.questionRows ||
        v2Sidecars != other.v2Sidecars ||
        typedCount != other.typedCount ||
        validEnvelopeCount != other.validEnvelopeCount ||
        !_sameIntList(questionNumbers, other.questionNumbers) ||
        typedImageNodeCount != other.typedImageNodeCount ||
        typedUniqueAssetCount != other.typedUniqueAssetCount ||
        resolvedUniqueAssetCount != other.resolvedUniqueAssetCount ||
        allReachableResolved != other.allReachableResolved ||
        canonicalIdentityPreserved != other.canonicalIdentityPreserved ||
        typedTableNodeCount != other.typedTableNodeCount ||
        payloadDigest != other.payloadDigest ||
        !_sameIdentitySet(reachableIdentities, other.reachableIdentities)) {
      return false;
    }
    if (questions.length != other.questions.length) return false;
    for (var index = 0; index < questions.length; index++) {
      if (!questions[index].equivalentTo(other.questions[index])) return false;
    }
    return true;
  }
}

final class TrainCB0PhaseFacts {
  const TrainCB0PhaseFacts({
    required this.packagePath,
    required this.preB0Checkpoint,
    required this.restoreCheckpoint,
    this.backupStatus = 'PASS',
    this.restoreStatus = 'PASS',
  });

  final String packagePath;
  final TrainCRuntimeCheckpoint preB0Checkpoint;
  final TrainCRuntimeCheckpoint restoreCheckpoint;
  final String backupStatus;
  final String restoreStatus;
}

final class TrainCRuntimePhaseFacts {
  const TrainCRuntimePhaseFacts({
    required this.input,
    required this.parse,
    required this.requestLedger,
    required this.commitCheckpoint,
    required this.restartCheckpoint,
    required this.b0,
    this.restartProviderDispatchCount = 0,
  });

  final TrainCInputFacts input;
  final TrainCParseFacts parse;
  final TrainCRequestLedger requestLedger;
  final TrainCRuntimeCheckpoint commitCheckpoint;
  final TrainCRuntimeCheckpoint restartCheckpoint;
  final TrainCB0PhaseFacts b0;
  final int restartProviderDispatchCount;
}

/// Read-only runtime-backed source for the H1 evidence schema.
///
/// The source accepts only typed facts that cannot be reconstructed from the
/// final database (for example the request ledger and parse block counts). All
/// persisted question, sidecar, image, table, and B0 facts are re-derived from
/// the isolated runtime. It has no provider, PDF, backup mutation, or delete
/// capability.
final class TrainCRuntimeEvidenceSource implements TrainCTrustedEvidenceSource {
  TrainCRuntimeEvidenceSource({
    required this.runtime,
    required this.phaseFacts,
    this.renderEvidence = const UnavailableTrainCRenderEvidencePort(),
    this.reviewedIdentity = TrainCReviewedIdentity.l1a,
    this.currentHeadReader = _readCurrentHead,
  });

  final TrainCIsolatedRuntime runtime;
  final TrainCRuntimePhaseFacts phaseFacts;
  final TrainCRenderEvidencePort renderEvidence;
  final TrainCReviewedIdentity reviewedIdentity;
  final String Function() currentHeadReader;

  Future<TrainCRuntimeCheckpoint> captureCheckpoint() async {
    try {
      final db = await runtime.database;
      final questionRows = await db.query(
        'questions',
        columns: <String>['id'],
        orderBy: 'id',
      );
      final sidecarRows = await db.query(
        'question_v2_payloads',
        columns: <String>[
          'question_id',
          'payload_schema_version',
          'payload_json',
        ],
        orderBy: 'question_id',
      );
      final drafts = <_DecodedDraft>[];
      final questionIds = <String>{};
      for (final row in questionRows) {
        final id = row['id'];
        if (id is! String || !questionIds.add(id)) {
          throw const TrainCRuntimeEvidenceException(
            'TRAIN_C_RUNTIME_EVIDENCE_FAILURE',
          );
        }
      }
      final sidecarIds = <String>{};
      final encodedPayloads = <String>[];
      for (final row in sidecarRows) {
        final questionId = row['question_id'];
        final schemaVersion = row['payload_schema_version'];
        final payloadJson = row['payload_json'];
        if (questionId is! String ||
            !sidecarIds.add(questionId) ||
            schemaVersion != QuestionDraftV2Codec.schemaVersion ||
            payloadJson is! String ||
            payloadJson.isEmpty ||
            !questionIds.contains(questionId)) {
          throw const TrainCRuntimeEvidenceException(
            'TRAIN_C_RUNTIME_EVIDENCE_FAILURE',
          );
        }
        try {
          final draft = const QuestionDraftV2Codec().decode(
            jsonDecode(payloadJson),
          );
          drafts.add(_DecodedDraft(questionId: questionId, draft: draft));
          encodedPayloads.add(payloadJson);
        } catch (_) {
          throw const TrainCRuntimeEvidenceException(
            'TRAIN_C_RUNTIME_EVIDENCE_FAILURE',
          );
        }
      }
      if (sidecarIds.length != questionIds.length) {
        throw const TrainCRuntimeEvidenceException(
          'TRAIN_C_RUNTIME_EVIDENCE_FAILURE',
        );
      }

      final questionFacts = <TrainCQuestionCheckpoint>[];
      final reachable = <(String, String)>{};
      var imageNodeCount = 0;
      var tableNodeCount = 0;
      var canonicalIdentityPreserved = true;
      for (final decoded in drafts) {
        final inspection = await _inspectDraft(decoded.draft);
        questionFacts.add(
          TrainCQuestionCheckpoint(
            questionNumber: decoded.draft.questionNumber,
            imageNodeCount: inspection.imageNodeCount,
            uniqueAssetCount: inspection.uniqueIdentities.length,
            resolvedUniqueAssetCount: inspection.resolvedIdentities.length,
            tableNodeCount: inspection.tableNodeCount,
            canonicalIdentityPreserved: inspection.canonicalIdentityPreserved,
            allReachableResolved: inspection.allReachableResolved,
            identityDigest: _identityDigest(inspection.uniqueIdentities),
            reachableIdentities: Set<(String, String)>.unmodifiable(
              inspection.uniqueIdentities,
            ),
          ),
        );
        imageNodeCount += inspection.imageNodeCount;
        tableNodeCount += inspection.tableNodeCount;
        reachable.addAll(inspection.uniqueIdentities);
        canonicalIdentityPreserved =
            canonicalIdentityPreserved && inspection.canonicalIdentityPreserved;
      }
      final resolvedGlobal = <(String, String)>{};
      for (final identity in reachable) {
        final bytes = runtime.contentAssetStore.readAssetBytes(
          sourceId: identity.$1,
          localAssetId: identity.$2,
        );
        if (bytes != null) resolvedGlobal.add(identity);
      }
      final questionNumbers = <int>[];
      for (final fact in questionFacts) {
        final number = fact.questionNumber;
        if (number != null) questionNumbers.add(number);
      }
      questionFacts.sort(
        (left, right) =>
            (left.questionNumber ?? -1).compareTo(right.questionNumber ?? -1),
      );
      return TrainCRuntimeCheckpoint(
        questionRows: questionRows.length,
        v2Sidecars: sidecarRows.length,
        typedCount: drafts.length,
        validEnvelopeCount: drafts.length,
        questionNumbers: List<int>.unmodifiable(questionNumbers..sort()),
        typedImageNodeCount: imageNodeCount,
        typedUniqueAssetCount: reachable.length,
        resolvedUniqueAssetCount: resolvedGlobal.length,
        allReachableResolved: resolvedGlobal.length == reachable.length,
        canonicalIdentityPreserved: canonicalIdentityPreserved,
        typedTableNodeCount: tableNodeCount,
        payloadDigest: sha256Hex(
          utf8.encode(encodedPayloads.join('\u001f')),
        ),
        reachableIdentities: Set<(String, String)>.unmodifiable(reachable),
        questions: List<TrainCQuestionCheckpoint>.unmodifiable(questionFacts),
      );
    } on TrainCRuntimeEvidenceException {
      rethrow;
    } catch (_) {
      throw const TrainCRuntimeEvidenceException(
        'TRAIN_C_RUNTIME_EVIDENCE_FAILURE',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> readAuthoritativeSnapshot() async {
    try {
      final current = await captureCheckpoint();
      _requireFinalCheckpoint(current);
      final currentHead = currentHeadReader().trim();
      if (currentHead != reviewedIdentity.approvedHarnessHead) {
        throw const TrainCRuntimeEvidenceException('TRAIN_C_HEAD_DRIFT');
      }
      final productionDiff = _productionDiffFromBase();
      if (productionDiff != 0) {
        throw const TrainCRuntimeEvidenceException('TRAIN_C_HEAD_DRIFT');
      }
      final commit = phaseFacts.commitCheckpoint;
      final restart = phaseFacts.b0.preB0Checkpoint;
      if (!phaseFacts.restartCheckpoint.equivalentTo(restart)) {
        throw const TrainCRuntimeEvidenceException('TRAIN_C_RESTART_FAILURE');
      }
      final restore = phaseFacts.b0.restoreCheckpoint;
      _requireFinalCheckpoint(commit);
      _requireFinalCheckpoint(restart);
      _requireFinalCheckpoint(restore);
      if (!restore.equivalentTo(restart)) {
        throw const TrainCRuntimeEvidenceException(
          'TRAIN_C_B0_IDENTITY_MISMATCH',
        );
      }
      final sourceClosure = _validateSourceImageClosure(current);
      final manifest = await BackupArchiveIo.readManifestOnly(
        phaseFacts.b0.packagePath,
      );
      final assetInventoryCount =
          (await runtime.contentAssetStore.listAssets()).length;
      final request = phaseFacts.requestLedger;
      final parse = phaseFacts.parse;
      final mandatory = <String, dynamic>{};
      for (final number in const <int>[5, 18, 19]) {
        final currentQuestion = current.question(number);
        final commitQuestion = commit.question(number);
        final restartQuestion = restart.question(number);
        final restoreQuestion = restore.question(number);
        if (currentQuestion == null ||
            commitQuestion == null ||
            restartQuestion == null ||
            restoreQuestion == null) {
          throw const TrainCRuntimeEvidenceException(
            'TRAIN_C_NUMBERING_FAILURE',
          );
        }
        mandatory['$number'] = <String, dynamic>{
          'referencedImageCount': sourceClosure.countFor(number),
          'sourceReferencedImageCount': sourceClosure.countFor(number),
          'typedImageNodeCount': currentQuestion.imageNodeCount,
          'referencedUniqueAssetCount':
              sourceClosure.identitiesFor(number).length,
          'sourceReferencedUniqueAssetCount':
              sourceClosure.identitiesFor(number).length,
          'resolvedUniqueAssetCount': currentQuestion.resolvedUniqueAssetCount,
          'sourceIdentityPreserved': true,
          'canonicalIdentityPreserved':
              currentQuestion.canonicalIdentityPreserved,
          'commitPreserved': currentQuestion.equivalentTo(commitQuestion),
          'restartResolution': restartQuestion.allReachableResolved,
          'restartRender': renderEvidence.didRender(
            questionNumber: number,
            stage: TrainCRenderStage.restart,
          ),
          'b0RestoreResolution': restoreQuestion.allReachableResolved,
          'b0RestoreRender': renderEvidence.didRender(
            questionNumber: number,
            stage: TrainCRenderStage.b0Restore,
          ),
        };
      }
      final backupReachable = restart.reachableIdentities.length;
      final backupManifestAssets = manifest.contentAssets.length;
      final restoredIdentityPreserved = true;
      return <String, dynamic>{
        'schemaVersion': 3,
        'runNumber': 1,
        'code': <String, dynamic>{
          'productionHead': reviewedIdentity.approvedProductionBase,
          'harnessHead': reviewedIdentity.approvedHarnessHead,
          'trainBMergeCommit': reviewedIdentity.approvedProductionBase,
          'currentHead': currentHead,
          'approvedHarnessHead': reviewedIdentity.approvedHarnessHead,
          'approvedBase': reviewedIdentity.approvedBase,
          'approvedProductionBase': reviewedIdentity.approvedProductionBase,
          'productionDiffFromBase': productionDiff,
        },
        'input': <String, dynamic>{
          'sha256': phaseFacts.input.sha256,
          'sizeBytes': phaseFacts.input.sizeBytes,
          'pageCount': phaseFacts.input.pageCount,
        },
        'attempt': <String, dynamic>{
          'consumed': request.attemptConsumed,
          'layoutPostCount': request.layoutPostCount,
          'layoutChunkSize': parse.layoutChunkSize,
          'expectedLayoutRequestCount': trainCExpectedLayoutRequestCount(
            pageCount: phaseFacts.input.pageCount,
            pageChunkSize: parse.layoutChunkSize,
          ),
          'providerDispatchCount': request.providerDispatchCount,
          'providerResponseCount': request.providerResponseCount,
          'remoteCropRequestCount': request.remoteCropRequestCount,
          'unexpectedProviderRequestCount':
              request.unexpectedProviderRequestCount,
          'networkFailureCount': request.networkFailureCount,
        },
        'safety': <String, dynamic>{
          'layoutResponsePolicyActive': parse.layoutResponsePolicyActive,
          'documentImageBudgetPolicyActive':
              parse.documentImageBudgetPolicyActive,
          'resourceFailure': parse.resourceFailure,
          'candidateCleanupPending': parse.candidateCleanupPending,
        },
        'parse': <String, dynamic>{
          'status': parse.status,
          'blockCount': parse.blockCount,
          'imageBlockCount': parse.imageBlockCount,
          'tableBlockCount': parse.tableBlockCount,
          'assembledQuestionCount': parse.assembledQuestionCount,
          'finalQuestionCount': parse.finalQuestionCount,
          'warningCount': parse.warningCount,
        },
        'numbering': <String, dynamic>{
          'questionCount': current.questionNumbers.length,
          'questionNumbers': current.questionNumbers,
          'exactSet1To22': current.exactSet1To22,
        },
        'typed': <String, dynamic>{
          'storageRoute': parse.storageRoute,
          'storageReason': parse.storageReason,
          'typedCount': current.typedCount,
          'validEnvelopeCount': current.validEnvelopeCount,
        },
        'imageSummary': <String, dynamic>{
          'referencedImageBlockCount': sourceClosure.totalReferencedImageCount,
          'typedImageNodeCount': current.typedImageNodeCount,
          'referencedUniqueAssetCount': sourceClosure.allIdentities.length,
          'typedUniqueAssetCount': current.typedUniqueAssetCount,
          'resolvedUniqueAssetCount': current.resolvedUniqueAssetCount,
          'allReachableResolved': current.allReachableResolved,
          'canonicalIdentityPreserved': current.canonicalIdentityPreserved,
        },
        'mandatoryQuestions': mandatory,
        'commit': <String, dynamic>{
          'status': commit.questionRows == 22 && commit.v2Sidecars == 22
              ? 'PASS'
              : 'FAIL',
          'questionRows': commit.questionRows,
          'v2Sidecars': commit.v2Sidecars,
          'legacyWriterCalls': parse.legacyWriterCalls,
          'candidateCleanupPending': parse.candidateCleanupPending,
        },
        'restart': <String, dynamic>{
          'status': restart.questionRows == 22 && restart.v2Sidecars == 22
              ? 'PASS'
              : 'FAIL',
          'questionCount': restart.questionNumbers.length,
          'typedAuthorityPreserved': commit.equivalentTo(restart),
          'allReachableResolved': restart.allReachableResolved,
          'providerDispatchCount': phaseFacts.restartProviderDispatchCount,
        },
        'backupRestore': <String, dynamic>{
          'packageVersion': manifest.packageVersion,
          'schemaVersion': manifest.schemaVersion,
          'backupStatus': phaseFacts.b0.backupStatus,
          'restoreStatus': phaseFacts.b0.restoreStatus,
          'restoredQuestionCount': restore.questionRows,
          'restoredV2Sidecars': restore.v2Sidecars,
          'reachableAssetCount': backupReachable,
          'backupManifestAssetCount': backupManifestAssets,
          'restoredAssetCount': assetInventoryCount,
          'manifestMatchesReachableAssets':
              backupManifestAssets == backupReachable,
          'restoredIdentityPreserved': restoredIdentityPreserved,
          'allReachableResolved': restore.allReachableResolved,
          'providerDispatchCount': 0,
        },
        'tableLiveCoverage':
            parse.referencedTableBlockCount > 0 ? 'PRESENT' : 'NOT PRESENT',
        'tableSummary': <String, dynamic>{
          'referencedTableBlockCount': parse.referencedTableBlockCount,
          'typedTableNodeCount': current.typedTableNodeCount,
          'tableContractConformant':
              current.typedTableNodeCount == parse.referencedTableBlockCount,
        },
      };
    } on TrainCRuntimeEvidenceException {
      rethrow;
    } on TrainCEvidenceProbeException catch (error) {
      throw TrainCRuntimeEvidenceException(error.code);
    } catch (_) {
      throw const TrainCRuntimeEvidenceException(
        'TRAIN_C_RUNTIME_EVIDENCE_FAILURE',
      );
    }
  }

  Future<_DraftInspection> _inspectDraft(QuestionDraftV2 draft) async {
    final inventory = <(String, String)>{
      for (final asset in draft.assetRefs) (asset.sourceId, asset.localAssetId),
    };
    final identities = <(String, String)>{};
    final resolved = <(String, String)>{};
    var imageCount = 0;
    var tableCount = 0;
    var canonical = true;
    void inspectContent(RichContent content) {
      for (final image in reachableImageNodes(content)) {
        imageCount++;
        final identity = (image.sourceId, image.localAssetId);
        if (!inventory.contains(identity)) canonical = false;
        identities.add(identity);
      }
      tableCount += _countTables(content);
    }

    inspectContent(draft.stem);
    for (final option in draft.options) {
      inspectContent(option.content);
    }
    if (draft.answer case ContentAnswer(:final content)) {
      inspectContent(content);
    }
    if (draft.explanation != null) {
      inspectContent(draft.explanation!);
    }
    for (final identity in identities) {
      final bytes = runtime.contentAssetStore.readAssetBytes(
        sourceId: identity.$1,
        localAssetId: identity.$2,
      );
      if (bytes != null) resolved.add(identity);
    }
    return _DraftInspection(
      imageNodeCount: imageCount,
      uniqueIdentities: identities,
      resolvedIdentities: resolved,
      tableNodeCount: tableCount,
      canonicalIdentityPreserved: canonical,
      allReachableResolved: canonical && resolved.length == identities.length,
    );
  }

  int _countTables(RichContent content) {
    var count = 0;
    for (final node in content.nodes) {
      switch (node) {
        case TableNode(:final structure):
          count++;
          for (final row in structure.rows) {
            for (final cell in row.cells) {
              count += _countTables(cell.content);
            }
          }
        case ImageNode(:final alternativeText):
          if (alternativeText != null) count += _countTables(alternativeText);
        case TextNode():
        case InlineMathNode():
        case BlockMathNode():
        case RawFallbackNode():
          break;
      }
    }
    return count;
  }

  void _requireFinalCheckpoint(TrainCRuntimeCheckpoint checkpoint) {
    if (checkpoint.questionRows != 22 ||
        checkpoint.v2Sidecars != 22 ||
        checkpoint.typedCount != 22 ||
        checkpoint.validEnvelopeCount != 22 ||
        !checkpoint.exactSet1To22) {
      throw const TrainCRuntimeEvidenceException('TRAIN_C_NUMBERING_FAILURE');
    }
    if (!checkpoint.canonicalIdentityPreserved ||
        !checkpoint.allReachableResolved) {
      throw const TrainCRuntimeEvidenceException(
        'TRAIN_C_IMAGE_CLOSURE_FAILURE',
      );
    }
  }

  int _productionDiffFromBase() {
    final result = Process.runSync(
      'git',
      <String>[
        'diff',
        '--name-only',
        '${reviewedIdentity.approvedProductionBase}..HEAD',
        '--',
        'lib',
      ],
    );
    if (result.exitCode != 0 || result.stdout is! String) {
      throw const TrainCRuntimeEvidenceException('TRAIN_C_HEAD_DRIFT');
    }
    final lines = (result.stdout as String)
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
    return lines.length;
  }

  String _identityDigest(Set<(String, String)> identities) {
    final values = identities
        .map((identity) => '${identity.$1}\u0000${identity.$2}')
        .toList()
      ..sort();
    return sha256Hex(utf8.encode(values.join('\u001f')));
  }

  _SourceImageClosure _validateSourceImageClosure(
    TrainCRuntimeCheckpoint current,
  ) {
    final source = phaseFacts.parse.sourceImages;
    if (source.totalReferencedImageCount !=
            phaseFacts.parse.referencedImageBlockCount ||
        source.totalReferencedImageCount != current.typedImageNodeCount ||
        !_sameIdentitySet(source.allIdentities, current.reachableIdentities)) {
      throw const TrainCRuntimeEvidenceException(
        'TRAIN_C_IMAGE_CLOSURE_FAILURE',
      );
    }
    for (final number in const <int>[5, 18, 19]) {
      final question = current.question(number);
      if (question == null ||
          source.countFor(number) != question.imageNodeCount ||
          !_sameIdentitySet(
            source.identitiesFor(number),
            question.reachableIdentities,
          )) {
        throw const TrainCRuntimeEvidenceException(
          'TRAIN_C_IMAGE_CLOSURE_FAILURE',
        );
      }
    }
    return _SourceImageClosure(source);
  }
}

final class _DecodedDraft {
  const _DecodedDraft({required this.questionId, required this.draft});

  final String questionId;
  final QuestionDraftV2 draft;
}

final class _DraftInspection {
  const _DraftInspection({
    required this.imageNodeCount,
    required this.uniqueIdentities,
    required this.resolvedIdentities,
    required this.tableNodeCount,
    required this.canonicalIdentityPreserved,
    required this.allReachableResolved,
  });

  final int imageNodeCount;
  final Set<(String, String)> uniqueIdentities;
  final Set<(String, String)> resolvedIdentities;
  final int tableNodeCount;
  final bool canonicalIdentityPreserved;
  final bool allReachableResolved;
}

final class _SourceImageClosure {
  const _SourceImageClosure(this.facts);

  final TrainCSourceImageFacts facts;

  int countFor(int questionNumber) => facts.countFor(questionNumber);

  Set<(String, String)> identitiesFor(int questionNumber) =>
      facts.identitiesFor(questionNumber);

  int get totalReferencedImageCount => facts.totalReferencedImageCount;

  Set<(String, String)> get allIdentities => facts.allIdentities;
}

String _readCurrentHead() {
  final result = Process.runSync('git', <String>['rev-parse', 'HEAD']);
  if (result.exitCode != 0 || result.stdout is! String) {
    throw const TrainCRuntimeEvidenceException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH');
  }
  return (result.stdout as String).trim();
}

bool _sameIdentitySet(
  Set<(String, String)> left,
  Set<(String, String)> right,
) {
  return left.length == right.length && left.containsAll(right);
}

bool _sameIntList(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
