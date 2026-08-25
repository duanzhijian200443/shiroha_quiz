import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/credentials/ai_engine_credential_activation.dart';
import 'package:shiroha_quiz/data/credentials/secure_engine_credential_store.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/models/question_identity.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/services/ai_service.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/import_pipeline/candidate_asset_lease.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_request_scheduler.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/import_review/import_review_item.dart';
import 'package:shiroha_quiz/services/import_review/typed_review_result_builder.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';
import 'package:shiroha_quiz/services/llm_providers/llm_provider_registry.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/ai_engine_management_screen.dart';
import 'package:shiroha_quiz/ui/pages/task_center_screen.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

import 'train_c_http_observer.dart';
import 'train_c_http_overrides.dart';
import 'train_c_evidence_probe.dart';
import 'train_c_isolated_runtime.dart';
import 'train_c_l1b_source_observer.dart';
import 'train_c_l1b_phase_controller.dart';
import 'train_c_l1b_review_authorization.dart';
import 'train_c_live_attempt_authority.dart';
import 'train_c_live_entrypoint.dart';

/// Real production composition used by the guarded L1B target.
///
/// This is deliberately a tool-side composition root. It wires the same
/// production services used by the application, while the isolated runtime
/// supplies the database and managed-asset roots. No test constructor, fake
/// OCR client, synthetic candidate, or direct SQL authority is available from
/// this composition.
final class TrainCL1BProductionComposition {
  TrainCL1BProductionComposition._({
    required this.engineRepository,
    required this.questionRepository,
    required this.contentAssetStore,
    required this.taskManager,
    required this.requestScheduler,
    required this.observingOcrClient,
    required this.importPipelineService,
    required this.importTaskCoordinator,
    required this.importCommitService,
  });

  final AiEngineRepository engineRepository;
  final QuestionRepository questionRepository;
  final ManagedContentAssetStore contentAssetStore;
  final TaskManager taskManager;
  final OcrRequestScheduler requestScheduler;
  final TrainCL1BObservingOcrClient observingOcrClient;
  final ImportPipelineService importPipelineService;
  final ImportTaskCoordinator importTaskCoordinator;
  final ImportCommitService importCommitService;

  Future<AiEngineProfile> requireConfiguredOcrProfile() async {
    final engines = await engineRepository.getEngines(AiEngineType.ocr);
    final active = await engineRepository.getActiveOcrEngine();
    if (engines.length != 1 ||
        active == null ||
        !active.isComplete ||
        active.modelName != ZhipuOcrClient.model ||
        LlmProviderRegistry.kindForBaseUrl(active.baseUrl) !=
            LlmProviderKind.zhipu) {
      throw const TrainCL1BLiveRuntimeException(
        'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
      );
    }
    return active;
  }

  Future<AiEngineProfile> waitForConfiguredOcrProfile({
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        return await requireConfiguredOcrProfile();
      } on TrainCL1BLiveRuntimeException {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    throw const TrainCL1BLiveRuntimeException(
      'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
    );
  }

  static Future<TrainCL1BProductionComposition> create({
    required TrainCIsolatedRuntime runtime,
    bool requireBlankStore = true,
    TrainCL1BPhaseController? phaseController,
  }) async {
    // Blank proof is intentionally before secure credential/profile
    // activation and before any provider-capable client can be dispatched.
    if (requireBlankStore) {
      final blank = await runtime.verifyBlankStore();
      if (!blank.passed) {
        throw const TrainCL1BLiveRuntimeException(
          'TRAIN_C_ISOLATION_FAILURE',
        );
      }
    }

    final contentAssetStore = runtime.contentAssetStore;
    final mapper = QuestionV2PersistenceMapper(
      contentAssetAuthority: contentAssetStore,
    );
    final questionRepository = QuestionRepository(
      databaseHelper: DatabaseHelper.instance,
      mapper: mapper,
    );
    final engineRepository = await activateAiEngineRepository(
      openDatabase: () async {
        await DatabaseHelper.instance.database;
      },
      store: DatabaseHelper.instance,
      migrationStore: DatabaseHelper.instance,
      createCredentialStore: SecureEngineCredentialStore.new,
    );
    final taskManager = TaskManager.instance;
    await taskManager.ready;
    final aiService = AiService(
      engineRepository: engineRepository,
      taskManager: taskManager,
      questionRepository: questionRepository,
    );
    final requestScheduler = OcrRequestScheduler(maxConcurrentRequests: 1);
    final observingOcrClient = TrainCL1BObservingOcrClient(
      const ZhipuOcrClient(),
    );
    final importPipelineService = ImportPipelineService(
      aiService: aiService,
      engineRepository: engineRepository,
      taskManager: taskManager,
      ocrRequestScheduler: requestScheduler,
      contentAssetStore: contentAssetStore,
      ocrClient: observingOcrClient,
    );
    final importTaskCoordinator = ImportTaskCoordinator(
      taskManager: taskManager,
      parser: importPipelineService.parseFiles,
      requestScheduler: requestScheduler,
      contentAssetStore: contentAssetStore,
    );
    final baseImportCommitService = ImportCommitService(
      questionRepository: questionRepository,
      taskManager: taskManager,
      contentAssetStore: contentAssetStore,
    );
    final importCommitService = phaseController == null
        ? baseImportCommitService
        : _TrainCPhaseAwareCommitService(
            questionRepository: questionRepository,
            taskManager: taskManager,
            contentAssetStore: contentAssetStore,
            phaseController: phaseController,
          );
    return TrainCL1BProductionComposition._(
      engineRepository: engineRepository,
      questionRepository: questionRepository,
      contentAssetStore: contentAssetStore,
      taskManager: taskManager,
      requestScheduler: requestScheduler,
      observingOcrClient: observingOcrClient,
      importPipelineService: importPipelineService,
      importTaskCoordinator: importTaskCoordinator,
      importCommitService: importCommitService,
    );
  }

  Future<ImportTaskHandle> dispatchSinglePdf({
    required String filePath,
  }) {
    return importTaskCoordinator.dispatchRequest(
      sourceDescription: 'TRAIN-C-L1 input',
      filePaths: <String>[filePath],
      fileNames: const <String>['train_c_input.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );
  }

  Future<ImportTask> waitForPendingReview(
    String taskId, {
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final task = _task(taskId);
      if (task == null) {
        throw const TrainCL1BLiveRuntimeException(
          'TRAIN_C_PENDING_REVIEW_FAILURE',
        );
      }
      if (task.status == TaskStatus.pendingReview) return task;
      if (task.status == TaskStatus.error) {
        throw const TrainCL1BLiveRuntimeException(
          'TRAIN_C_PENDING_REVIEW_FAILURE',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw const TrainCL1BLiveRuntimeException(
      'TRAIN_C_PENDING_REVIEW_FAILURE',
    );
  }

  /// Captures same-parse source authority from the observer and the durable
  /// pending-review task. The task only supplies accepted question numbers
  /// and the candidate lease; source bytes/ownership remain from the exact
  /// [OcrDocument] returned by the real OCR call.
  TrainCL1BSourceObservation observePendingReview(String taskId) {
    final task = _task(taskId);
    if (task == null || task.status != TaskStatus.pendingReview) {
      throw const TrainCL1BLiveRuntimeException(
        'TRAIN_C_PENDING_REVIEW_FAILURE',
      );
    }
    final lease = decodeCandidateAssetLeaseFromDiagnostics(task.diagnostics);
    final parsed = task.parsedData;
    if (lease == null || parsed == null || parsed.isEmpty) {
      throw const TrainCL1BLiveRuntimeException(
        'TRAIN_C_IMAGE_CLOSURE_FAILURE',
      );
    }
    final questionNumbers = <int>{};
    for (final question in parsed) {
      final number = QuestionIdentity.tryParseExplicitQuestionNumber(
        question['q_num'],
      );
      if (number == null || !questionNumbers.add(number)) {
        throw const TrainCL1BLiveRuntimeException(
          'TRAIN_C_NUMBERING_FAILURE',
        );
      }
    }
    return buildTrainCL1BSourceObservation(
      document: observingOcrClient.observedDocument,
      retainedLease: lease,
      acceptedQuestionNumbers: questionNumbers,
    );
  }

  /// Production review commit helper for the guarded review controller.
  /// It uses the durable task snapshot and the real typed commit service; it
  /// does not fabricate a pending task or bypass the review/attempt guards.
  Future<ImportCommitResult> commitPendingReview({
    required String taskId,
    required String bankName,
    required String folderName,
  }) async {
    final task = _task(taskId);
    if (task == null || task.status != TaskStatus.pendingReview) {
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_COMMIT_FAILURE');
    }
    final parsed = task.parsedData;
    final diagnostics = task.diagnostics;
    final attemptToken = diagnostics?[TaskManager.keyAttemptToken];
    final attemptNumber = diagnostics?[TaskManager.keyAttemptNumber];
    final revision = taskManager.reviewDraftRevision(taskId);
    if (parsed == null ||
        parsed.isEmpty ||
        attemptToken is! String ||
        attemptToken.isEmpty ||
        attemptNumber is! int ||
        attemptNumber <= 0 ||
        revision <= 0) {
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_COMMIT_FAILURE');
    }
    final inputs = <TypedReviewCommitInput>[];
    for (var index = 0; index < parsed.length; index++) {
      final question = parsed[index];
      final reviewItemId = question[TaskManager.keyReviewItemId];
      if (reviewItemId is! String || reviewItemId.trim().isEmpty) {
        throw const TrainCL1BLiveRuntimeException('TRAIN_C_COMMIT_FAILURE');
      }
      inputs.add(
        TypedReviewCommitInput(
          reviewItemId: reviewItemId,
          envelope: question[TypedReviewSnapshotCodec.mapKey],
          currentDraft: ImportReviewItem.fromMap(question, index).draft,
        ),
      );
    }
    final route = decodeImportStorageRoute(
      diagnostics?[TaskManager.keyImportStorageRoute],
    );
    final reason = diagnostics?[TaskManager.keyImportStorageReason];
    if (reason is! String) {
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_COMMIT_FAILURE');
    }
    return importCommitService.commitTyped(
      bankName: bankName,
      folderName: folderName,
      items: inputs,
      taskId: taskId,
      attemptToken: attemptToken,
      attemptNumber: attemptNumber,
      expectedReviewDraftRevision: revision,
      storageRoute: route,
      storageReason: reason,
      explanationRetentionMode: task.explanationRetentionMode,
    );
  }

  ImportTask? _task(String taskId) {
    for (final task in taskManager.tasks) {
      if (task.id == taskId) return task;
    }
    return null;
  }
}

/// Runs the production repository/credential state machine for the isolated
/// configure phase. The credential is supplied by a production UI/input
/// boundary and is never written directly to SQLite; [AiEngineRepository]
/// routes it through its configured [EngineCredentialStore].
Future<AiEngineProfile> configureTrainCL1BOcrProfile({
  required AiEngineRepository repository,
  required AiEngineProfile profile,
}) async {
  if (profile.engineType != AiEngineType.ocr ||
      profile.modelName != ZhipuOcrClient.model ||
      LlmProviderRegistry.kindForBaseUrl(profile.baseUrl) !=
          LlmProviderKind.zhipu ||
      profile.apiKey.isEmpty) {
    throw const TrainCL1BLiveRuntimeException(
      'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
    );
  }
  await repository.saveEngine(profile);
  await repository.setActiveEngine(profile.id, AiEngineType.ocr);
  final active = await repository.getActiveOcrEngine();
  if (active == null ||
      !active.isComplete ||
      active.id != profile.id ||
      active.modelName != ZhipuOcrClient.model ||
      LlmProviderRegistry.kindForBaseUrl(active.baseUrl) !=
          LlmProviderKind.zhipu) {
    throw const TrainCL1BLiveRuntimeException(
      'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
    );
  }
  return active;
}

/// Keeps the durable phase controller attached to the real production typed
/// commit call. It does not build commit inputs or write questions itself; it
/// advances only after [super.commitTyped] reports the production commit's
/// safe question-count result.
final class _TrainCPhaseAwareCommitService extends ImportCommitService {
  _TrainCPhaseAwareCommitService({
    required super.questionRepository,
    required super.taskManager,
    required super.contentAssetStore,
    required this.phaseController,
  });

  final TrainCL1BPhaseController phaseController;

  @override
  Future<ImportCommitResult> commitTyped({
    required String bankName,
    required String folderName,
    required List<TypedReviewCommitInput> items,
    required String taskId,
    required String attemptToken,
    required int attemptNumber,
    required int expectedReviewDraftRevision,
    required ImportStorageRoute storageRoute,
    required String storageReason,
    required ExplanationRetentionMode explanationRetentionMode,
    List<QuestionExplanationOverride>? explanationOverrides,
  }) async {
    final phase = phaseController.status.phase;
    if (phase == TrainCLiveRunPhase.pendingReview) {
      phaseController.transitionTo(TrainCLiveRunPhase.commitReady);
    } else if (phase != TrainCLiveRunPhase.commitReady) {
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_COMMIT_FAILURE');
    }
    final result = await super.commitTyped(
      bankName: bankName,
      folderName: folderName,
      items: items,
      taskId: taskId,
      attemptToken: attemptToken,
      attemptNumber: attemptNumber,
      expectedReviewDraftRevision: expectedReviewDraftRevision,
      storageRoute: storageRoute,
      storageReason: storageReason,
      explanationRetentionMode: explanationRetentionMode,
      explanationOverrides: explanationOverrides,
    );
    if (result.questionCount != 22) {
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_COMMIT_FAILURE');
    }
    phaseController.transitionTo(TrainCLiveRunPhase.committed);
    return result;
  }
}

final class TrainCL1BLiveRuntimeException implements Exception {
  const TrainCL1BLiveRuntimeException(this.code);

  final String code;

  @override
  String toString() => code;
}

final class TrainCL1BLiveInputFacts {
  const TrainCL1BLiveInputFacts({
    required this.sha256,
    required this.sizeBytes,
    required this.pageCount,
  });

  final String sha256;
  final int sizeBytes;
  final int pageCount;
}

Future<TrainCL1BLiveInputFacts> readTrainCL1BLiveInputFacts(
  String inputPath,
) async {
  if (p.extension(inputPath).toLowerCase() != '.pdf') {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_INPUT_INVALID');
  }
  final file = File(inputPath);
  if (!await file.exists()) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_INPUT_INVALID');
  }
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty || bytes.length > 50 * 1024 * 1024) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_INPUT_INVALID');
  }
  if (bytes.length < 5 || String.fromCharCodes(bytes.take(5)) != '%PDF-') {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_INPUT_INVALID');
  }
  PdfDocument? document;
  try {
    document = PdfDocument(inputBytes: bytes);
    final pageCount = document.pages.count;
    if (pageCount <= 0) {
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_INPUT_INVALID');
    }
    return TrainCL1BLiveInputFacts(
      sha256: sha256Hex(bytes),
      sizeBytes: bytes.length,
      pageCount: pageCount,
    );
  } catch (error) {
    if (error is TrainCL1BLiveRuntimeException) rethrow;
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_INPUT_INVALID');
  } finally {
    document?.dispose();
  }
}

/// Production review surface for the guarded target. The review and commit
/// widgets are the existing application widgets; this target only supplies
/// the real isolated composition and resolver.
final class TrainCL1BLiveRuntimeApp extends StatelessWidget {
  const TrainCL1BLiveRuntimeApp({
    super.key,
    required this.composition,
  });

  final TrainCL1BProductionComposition composition;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ContentAssetResolverScope(
        resolver: composition.contentAssetStore,
        child: TaskCenterScreen(
          taskManager: composition.taskManager,
          taskCoordinator: composition.importTaskCoordinator,
          commitService: composition.importCommitService,
        ),
      ),
    );
  }
}

/// The configure stage uses the production engine-management surface and the
/// production repository/secure credential authority. It is shown only when
/// the new isolated database has no active OCR profile; it is never a fake
/// profile or a direct SQLite/credential shortcut.
final class TrainCL1BOcrConfigureApp extends StatelessWidget {
  const TrainCL1BOcrConfigureApp({
    super.key,
    required this.composition,
  });

  final TrainCL1BProductionComposition composition;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: AiEngineManagementScreen(
        engineType: 'ocr',
        engineRepository: composition.engineRepository,
      ),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  TrainCL1BPhaseController? liveController;
  try {
    final continuation =
        Platform.environment[trainCL1BContinuationEnvironment] == '1';
    if (continuation) {
      await _runContinuationProcess();
      return;
    }

    final reviewed = TrainCL1BLiveLaunchGuard.verify();
    final attemptCapability =
        Platform.environment[trainCLiveAttemptCapabilityEnvironment];
    if (attemptCapability == null || attemptCapability.trim().isEmpty) {
      throw const TrainCL1BLiveRuntimeException(
        'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
      );
    }
    final controller = TrainCL1BPhaseController.forLive(
      capability: TrainCLiveAttemptAuthority.fromCapability(attemptCapability),
      reviewedHarnessHead: reviewed.approvedHarnessHead,
    );
    liveController = controller;
    final inputPath =
        Platform.environment[trainCL1BPrivateInputPathEnvironment];
    if (inputPath == null || inputPath.trim().isEmpty) {
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_INPUT_INVALID');
    }
    // Runtime creation/reattachment and blank proof happen before private
    // input admission. A restart can only reattach the capability-bound root.
    final runtime = await controller.createOrReattachRuntime();
    final composition = await TrainCL1BProductionComposition.create(
      runtime: runtime,
      requireBlankStore: controller.status.phase == TrainCLiveRunPhase.prepared,
      phaseController: controller,
    );
    if (controller.status.phase == TrainCLiveRunPhase.prepared) {
      try {
        await composition.requireConfiguredOcrProfile();
      } on TrainCL1BLiveRuntimeException {
        runApp(TrainCL1BOcrConfigureApp(composition: composition));
        await composition.waitForConfiguredOcrProfile();
      }
      controller.markConfigured();
    } else {
      await composition.requireConfiguredOcrProfile();
    }
    final input = await readTrainCL1BLiveInputFacts(inputPath);
    final attemptAuthority =
        TrainCLiveAttemptAuthority.fromCapability(attemptCapability);
    attemptAuthority.verifyUnused(
      reviewedHarnessHead: reviewed.approvedHarnessHead,
    );
    controller.markParseRunning();
    final ledger = TrainCRequestLedger(
      attemptAuthority: attemptAuthority,
    );
    HttpOverrides.global = TrainCHttpOverrides(ledger);
    runApp(TrainCL1BLiveRuntimeApp(composition: composition));

    final rechecked = await readTrainCL1BLiveInputFacts(inputPath);
    if (rechecked.sha256 != input.sha256 ||
        rechecked.sizeBytes != input.sizeBytes ||
        rechecked.pageCount != input.pageCount) {
      throw const TrainCL1BLiveRuntimeException(
        'TRAIN_C_INPUT_HASH_MISMATCH',
      );
    }
    ledger.beginParse(
      expectedLayoutRequests: trainCExpectedLayoutRequestCount(
        pageCount: input.pageCount,
        pageChunkSize: trainCProductionPdfPageChunkSize,
      ),
    );
    final handle = await composition.dispatchSinglePdf(filePath: inputPath);
    final task = await composition.waitForPendingReview(handle.taskId);
    composition.observePendingReview(handle.taskId);
    ledger.finishParse(successful: true);
    // The production review UI remains open for the explicit no-edit review
    // and typed commit step. No retry or second top-level import is possible.
    if (task.status != TaskStatus.pendingReview) {
      throw const TrainCL1BLiveRuntimeException(
        'TRAIN_C_PENDING_REVIEW_FAILURE',
      );
    }
    controller.markPendingReview();
  } on TrainCL1BLiveRuntimeException catch (error) {
    _markConsumedFailure(liveController);
    runApp(_TrainCL1BFailureApp(code: error.code));
  } on TrainCEvidenceProbeException catch (error) {
    _markConsumedFailure(liveController);
    runApp(_TrainCL1BFailureApp(code: error.code));
  } on TrainCIsolationException {
    _markConsumedFailure(liveController);
    runApp(const _TrainCL1BFailureApp(code: 'TRAIN_C_ISOLATION_FAILURE'));
  } catch (_) {
    _markConsumedFailure(liveController);
    runApp(const _TrainCL1BFailureApp(
      code: 'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
    ));
  }
}

void _markConsumedFailure(TrainCL1BPhaseController? controller) {
  if (controller == null) return;
  try {
    final state = controller.status;
    if (state.attemptState == TrainCLiveRunAttemptState.consumed &&
        state.phase == TrainCLiveRunPhase.parseRunning) {
      controller.markFailedConsumed();
    }
  } catch (_) {
    // The original safe failure is retained; control-state failure is never
    // allowed to expose raw process/provider details.
  }
}

Future<void> _runContinuationProcess() async {
  final reviewed = TrainCL1BReviewAuthorization.requireFromEnvironment();
  final capabilityValue =
      Platform.environment[trainCLiveAttemptCapabilityEnvironment]?.trim() ??
          '';
  if (capabilityValue.isEmpty) {
    throw const TrainCL1BLiveRuntimeException(
      'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
    );
  }
  final controller = TrainCL1BPhaseController.forContinuation(
    capability: TrainCLiveAttemptAuthority.fromCapability(capabilityValue),
    reviewedHarnessHead: reviewed.approvedHarnessHead,
  );
  controller.requireProviderForbidden();
  final runtime = await controller.reattachRuntime();
  final composition = await TrainCL1BProductionComposition.create(
    runtime: runtime,
    requireBlankStore: false,
    phaseController: controller,
  );
  HttpOverrides.global = TrainCHttpOverrides(
    TrainCRequestLedger(providerDisabled: true),
  );
  runApp(TrainCL1BLiveRuntimeApp(composition: composition));
}

final class _TrainCL1BFailureApp extends StatelessWidget {
  const _TrainCL1BFailureApp({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: Text(code)),
      ),
    );
  }
}
