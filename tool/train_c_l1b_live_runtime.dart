import 'dart:async';
import 'dart:convert';
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
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';
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
import 'package:shiroha_quiz/services/import_review/typed_review_result_builder.dart';
import 'package:shiroha_quiz/services/llm_providers/llm_provider_registry.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/ai_engine_management_screen.dart';
import 'package:shiroha_quiz/ui/pages/task_center_screen.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

import 'train_c_evidence_collector.dart';
import 'train_c_evidence_probe.dart';
import 'train_c_http_observer.dart';
import 'train_c_http_overrides.dart';
import 'train_c_isolated_runtime.dart';
import 'train_c_l1b_phase_controller.dart';
import 'train_c_l1b_source_observer.dart';
import 'train_c_l1b_supervisor.dart';
import 'train_c_l1b_transport.dart';
import 'train_c_live_attempt_authority.dart';
import 'train_c_live_entrypoint.dart';
import 'train_c_restart_proof.dart';
import 'train_c_runtime_evidence_source.dart';

/// Real production composition used by one guarded L1B child process.
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
    bool commitEnabled = false,
    TrainCL1BPhaseController? phaseController,
  }) async {
    if (requireBlankStore) {
      final blank = await runtime.verifyBlankStore();
      if (!blank.passed) {
        throw const TrainCL1BLiveRuntimeException('TRAIN_C_ISOLATION_FAILURE');
      }
    }
    if (commitEnabled && phaseController == null) {
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_HARNESS_NOT_READY');
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
    final importCommitService = commitEnabled
        ? _TrainCPhaseAwareCommitService(
            questionRepository: questionRepository,
            taskManager: taskManager,
            contentAssetStore: contentAssetStore,
            phaseController: phaseController!,
          )
        : _TrainCCommitDisabledService(
            questionRepository: questionRepository,
            taskManager: taskManager,
            contentAssetStore: contentAssetStore,
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

  Future<ImportTaskHandle> dispatchSinglePdf({required String filePath}) {
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

  ImportTask uniquePendingReviewTask() {
    final pending = taskManager.tasks
        .where((task) => task.status == TaskStatus.pendingReview)
        .toList(growable: false);
    if (pending.length != 1) {
      throw const TrainCL1BLiveRuntimeException(
        'TRAIN_C_PENDING_REVIEW_FAILURE',
      );
    }
    return pending.single;
  }

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
        throw const TrainCL1BLiveRuntimeException('TRAIN_C_NUMBERING_FAILURE');
      }
    }
    if (questionNumbers.length != 22 ||
        !List<int>.generate(22, (index) => index + 1)
            .every(questionNumbers.contains)) {
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_NUMBERING_FAILURE');
    }
    return buildTrainCL1BSourceObservation(
      document: observingOcrClient.observedDocument,
      retainedLease: lease,
      acceptedQuestionNumbers: questionNumbers,
    );
  }

  TrainCCandidateCheckpoint captureCandidateCheckpoint(String taskId) {
    final task = _task(taskId);
    final parsed = task?.parsedData;
    if (task == null ||
        task.status != TaskStatus.pendingReview ||
        parsed == null ||
        parsed.length != 22) {
      throw const TrainCL1BLiveRuntimeException(
        'TRAIN_C_TYPED_ENVELOPE_FAILURE',
      );
    }
    final route = decodeImportStorageRoute(
      task.diagnostics?[TaskManager.keyImportStorageRoute],
    );
    final reason = task.diagnostics?[TaskManager.keyImportStorageReason];
    if (route != ImportStorageRoute.typedV2 ||
        reason != 'typed_candidate_ready') {
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_TYPED_ROUTE_FAILURE');
    }
    const codec = TypedReviewSnapshotCodec();
    final drafts = <QuestionDraftV2>[];
    try {
      for (final question in parsed) {
        drafts.add(codec
            .decodeRequired(question[TypedReviewSnapshotCodec.mapKey])
            .draft);
      }
    } catch (_) {
      throw const TrainCL1BLiveRuntimeException(
        'TRAIN_C_TYPED_ENVELOPE_FAILURE',
      );
    }
    final checkpoint = TrainCCandidateCheckpoint.fromDrafts(drafts);
    if (checkpoint.typedCount != 22 ||
        checkpoint.validEnvelopeCount != 22 ||
        checkpoint.questionNumbers.length != 22 ||
        !checkpoint.questionNumbers
            .asMap()
            .entries
            .every((entry) => entry.value == entry.key + 1)) {
      throw const TrainCL1BLiveRuntimeException(
        'TRAIN_C_TYPED_ENVELOPE_FAILURE',
      );
    }
    return checkpoint;
  }

  ImportTask? _task(String taskId) {
    for (final task in taskManager.tasks) {
      if (task.id == taskId) return task;
    }
    return null;
  }
}

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

final class _TrainCCommitDisabledService extends ImportCommitService {
  _TrainCCommitDisabledService({
    required super.questionRepository,
    required super.taskManager,
    required super.contentAssetStore,
  });

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
  }) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_COMMIT_FAILURE');
  }
}

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
      phaseController.markCommitReady();
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
    phaseController.markCommitted();
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

final class TrainCL1BReviewApp extends StatelessWidget {
  const TrainCL1BReviewApp({super.key, required this.composition});

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

final class TrainCL1BParseProgressApp extends StatelessWidget {
  const TrainCL1BParseProgressApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(child: Text('TRAIN C OCR running')),
      ),
    );
  }
}

final class TrainCL1BOcrConfigureApp extends StatelessWidget {
  const TrainCL1BOcrConfigureApp({super.key, required this.composition});

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
  TrainCL1BSupervisorClient? client;
  TrainCL1BPhaseController? controller;
  try {
    client = TrainCL1BSupervisorClient.fromEnvironment();
    switch (client.phase) {
      case TrainCL1BChildPhase.parse:
        controller = await _runParseChild(client);
      case TrainCL1BChildPhase.commit:
        controller = await _runCommitChild(client);
      case TrainCL1BChildPhase.restart:
        controller = await _runRestartChild(client);
      case TrainCL1BChildPhase.finalize:
        controller = await _runFinalizeChild(client);
    }
    exit(0);
  } on TrainCL1BLiveRuntimeException catch (error) {
    _markConsumedFailure(controller);
    await _safeReportFailure(client, error.code);
    exit(1);
  } on TrainCEvidenceProbeException catch (error) {
    _markConsumedFailure(controller);
    await _safeReportFailure(client, error.code);
    exit(1);
  } on TrainCProtocolException catch (error) {
    _markConsumedFailure(controller);
    await _safeReportFailure(client, error.code);
    exit(1);
  } on TrainCRuntimeEvidenceException catch (error) {
    await _safeReportFailure(client, error.code);
    exit(1);
  } on TrainCRestartException catch (error) {
    await _safeReportFailure(client, error.code);
    exit(1);
  } on TrainCIsolationException {
    _markConsumedFailure(controller);
    await _safeReportFailure(client, 'TRAIN_C_ISOLATION_FAILURE');
    exit(1);
  } on TrainCL1BSupervisorException catch (error) {
    await _safeReportFailure(client, error.code);
    exit(1);
  } catch (_) {
    _markConsumedFailure(controller);
    await _safeReportFailure(client, 'TRAIN_C_HARNESS_NOT_READY');
    exit(1);
  }
}

Future<TrainCL1BPhaseController> _runParseChild(
  TrainCL1BSupervisorClient client,
) async {
  final reviewed = TrainCL1BLiveLaunchGuard.verify();
  final capabilityValue = _capabilityValue();
  final authority = TrainCLiveAttemptAuthority.fromCapability(capabilityValue);
  final controller = TrainCL1BPhaseController.forLive(
    capability: authority,
    reviewedHarnessHead: reviewed.approvedHarnessHead,
    reviewedBase: reviewed.approvedBase,
  );
  final inputPath =
      Platform.environment[trainCL1BPrivateInputPathEnvironment]?.trim() ?? '';
  if (inputPath.isEmpty) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_INPUT_INVALID');
  }
  final runtime = await controller.createOrReattachRuntime();
  final composition = await TrainCL1BProductionComposition.create(
    runtime: runtime,
    requireBlankStore: controller.status.phase == TrainCLiveRunPhase.prepared,
    commitEnabled: false,
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
  authority.verifyUnused(
    reviewedHarnessHead: reviewed.approvedHarnessHead,
    reviewedBase: reviewed.approvedBase,
  );
  controller.markParseRunning();
  final ledger = TrainCRequestLedger(attemptAuthority: authority);
  HttpOverrides.global = TrainCHttpOverrides(ledger);
  runApp(const TrainCL1BParseProgressApp());

  final rechecked = await readTrainCL1BLiveInputFacts(inputPath);
  if (rechecked.sha256 != input.sha256 ||
      rechecked.sizeBytes != input.sizeBytes ||
      rechecked.pageCount != input.pageCount) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_INPUT_HASH_MISMATCH');
  }
  ledger.beginParse(
    expectedLayoutRequests: trainCExpectedLayoutRequestCount(
      pageCount: input.pageCount,
      pageChunkSize: trainCProductionPdfPageChunkSize,
    ),
  );
  final handle = await composition.dispatchSinglePdf(filePath: inputPath);
  final task = await composition.waitForPendingReview(handle.taskId);
  final observation = composition.observePendingReview(handle.taskId);
  final candidate = composition.captureCandidateCheckpoint(handle.taskId);
  ledger.finishParse(successful: true);
  if (task.status != TaskStatus.pendingReview) {
    throw const TrainCL1BLiveRuntimeException(
      'TRAIN_C_PENDING_REVIEW_FAILURE',
    );
  }
  final route = decodeImportStorageRoute(
    task.diagnostics?[TaskManager.keyImportStorageRoute],
  );
  final reason = task.diagnostics?[TaskManager.keyImportStorageReason];
  if (route != ImportStorageRoute.typedV2 ||
      reason != 'typed_candidate_ready') {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_TYPED_ROUTE_FAILURE');
  }
  controller.markPendingReview();
  await client.reportPass(<String, Object?>{
    'input': <String, Object?>{
      'sha256': input.sha256,
      'sizeBytes': input.sizeBytes,
      'pageCount': input.pageCount,
    },
    'parse': <String, Object?>{
      'blockCount': observation.blockCount,
      'imageBlockCount': observation.imageBlockCount,
      'tableBlockCount': observation.tableBlockCount,
      'referencedImageBlockCount':
          observation.sourceImages.totalReferencedImageCount,
      'referencedTableBlockCount': observation.referencedTableBlockCount,
      'assembledQuestionCount': candidate.typedCount,
      'finalQuestionCount': candidate.typedCount,
      'storageRoute': importStorageRouteSerialization(route),
      'storageReason': reason,
      'sourceImages': encodeTrainCSourceImages(observation.sourceImages),
    },
    'candidate': encodeTrainCCandidateCheckpoint(candidate),
    'request': ledger.transportSnapshot(),
  });
  await runtime.closeForRestart();
  return controller;
}

Future<TrainCL1BPhaseController> _runCommitChild(
  TrainCL1BSupervisorClient client,
) async {
  final reviewed = TrainCL1BLiveLaunchGuard.verifyContinuation();
  final authority =
      TrainCLiveAttemptAuthority.fromCapability(_capabilityValue());
  final controller = TrainCL1BPhaseController.forContinuation(
    capability: authority,
    reviewedHarnessHead: reviewed.approvedHarnessHead,
    reviewedBase: reviewed.approvedBase,
  );
  if (controller.status.phase != TrainCLiveRunPhase.pendingReview) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_COMMIT_FAILURE');
  }
  controller.requireProviderForbidden();
  HttpOverrides.global = TrainCHttpOverrides(
    TrainCRequestLedger(providerDisabled: true),
  );
  final runtime = await controller.reattachRuntime();
  final composition = await TrainCL1BProductionComposition.create(
    runtime: runtime,
    requireBlankStore: false,
    commitEnabled: true,
    phaseController: controller,
  );
  composition.uniquePendingReviewTask();
  runApp(TrainCL1BReviewApp(composition: composition));
  await _waitForPhase(
    controller,
    TrainCLiveRunPhase.committed,
    timeout: const Duration(minutes: 30),
  );
  final checkpoint = await _captureCheckpoint(runtime, reviewed);
  if (checkpoint.questionRows != 22 ||
      checkpoint.v2Sidecars != 22 ||
      !checkpoint.exactSet1To22) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_COMMIT_FAILURE');
  }
  await client.reportPass(<String, Object?>{
    'checkpoint': encodeTrainCRuntimeCheckpoint(checkpoint),
  });
  await runtime.closeForRestart();
  return controller;
}

Future<TrainCL1BPhaseController> _runRestartChild(
  TrainCL1BSupervisorClient client,
) async {
  final reviewed = TrainCL1BLiveLaunchGuard.verifyContinuation();
  final authority =
      TrainCLiveAttemptAuthority.fromCapability(_capabilityValue());
  final controller = TrainCL1BPhaseController.forContinuation(
    capability: authority,
    reviewedHarnessHead: reviewed.approvedHarnessHead,
    reviewedBase: reviewed.approvedBase,
  );
  if (controller.status.phase != TrainCLiveRunPhase.committed) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_RESTART_FAILURE');
  }
  controller.requireProviderForbidden();
  HttpOverrides.global = TrainCHttpOverrides(
    TrainCRequestLedger(providerDisabled: true),
  );
  var runtime = await controller.reattachRuntime();
  final persistentRuntimeCapability = authority.runtimeCapabilityForReattach;
  final expected = await captureTrainCDurableRestartCheckpoint(
    database: await runtime.database,
    managedDirectory: runtime.managedDirectory,
  );
  await runtime.closeForRestart();
  final proof = await _runPersistentRestartProof(
    persistentRuntimeCapability,
    expected,
  );
  runtime = await TrainCIsolatedRuntime.reattachFromCapability(
    persistentRuntimeCapability,
    deleteRootOnDispose: false,
  );
  final after = await captureTrainCDurableRestartCheckpoint(
    database: await runtime.database,
    managedDirectory: runtime.managedDirectory,
  );
  if (!proof.matches(after) || !expected.equivalentTo(after)) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_RESTART_FAILURE');
  }
  final checkpoint = await _captureCheckpoint(runtime, reviewed);
  final render = await _renderMandatoryQuestions(runtime);
  if (!render.values.every((value) => value)) {
    throw const TrainCL1BLiveRuntimeException(
      'TRAIN_C_ASSET_RESOLUTION_FAILURE',
    );
  }
  controller.markRestartProved();
  await client.reportPass(<String, Object?>{
    'checkpoint': encodeTrainCRuntimeCheckpoint(checkpoint),
    'render': <String, Object?>{
      for (final entry in render.entries) '${entry.key}': entry.value,
    },
  });
  await runtime.closeForRestart();
  return controller;
}

Future<TrainCL1BPhaseController> _runFinalizeChild(
  TrainCL1BSupervisorClient client,
) async {
  final reviewed = TrainCL1BLiveLaunchGuard.verifyContinuation();
  final capabilityValue = _capabilityValue();
  final authority = TrainCLiveAttemptAuthority.fromCapability(capabilityValue);
  final controller = TrainCL1BPhaseController.forContinuation(
    capability: authority,
    reviewedHarnessHead: reviewed.approvedHarnessHead,
    reviewedBase: reviewed.approvedBase,
  );
  if (controller.status.phase != TrainCLiveRunPhase.restartProved) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_B0_IDENTITY_MISMATCH');
  }
  controller.requireProviderForbidden();
  HttpOverrides.global = TrainCHttpOverrides(
    TrainCRequestLedger(providerDisabled: true),
  );

  final facts = await client.requestFacts();
  final parseReport = _map(facts[TrainCL1BChildPhase.parse.wireName]);
  final commitReport = _map(facts[TrainCL1BChildPhase.commit.wireName]);
  final restartReport = _map(facts[TrainCL1BChildPhase.restart.wireName]);
  final inputMap = _map(parseReport['input']);
  final parseMap = _map(parseReport['parse']);
  final input = TrainCInputFacts(
    sha256: _digest(inputMap['sha256']),
    sizeBytes: _positiveInt(inputMap['sizeBytes']),
    pageCount: _positiveInt(inputMap['pageCount']),
  );
  final sourceImages = decodeTrainCSourceImages(parseMap['sourceImages']);
  final candidate = decodeTrainCCandidateCheckpoint(parseReport['candidate']);
  final requestLedger =
      TrainCRequestLedger.fromTransportSnapshot(parseReport['request']);
  final commit = decodeTrainCRuntimeCheckpoint(commitReport['checkpoint']);
  final restart = decodeTrainCRuntimeCheckpoint(restartReport['checkpoint']);
  final restartRender = _renderMap(restartReport['render']);
  if (!candidate.matches(commit) || !commit.equivalentTo(restart)) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_COMMIT_FAILURE');
  }

  var sourceRuntime = await controller.reattachRuntime();
  final preB0 = await _captureCheckpoint(sourceRuntime, reviewed);
  if (!preB0.equivalentTo(restart)) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_RESTART_FAILURE');
  }
  final packagePath = p.join(
    sourceRuntime.exportDirectory.path,
    'train_c_run_1.shiroha',
  );
  if (File(packagePath).existsSync()) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_BACKUP_FAILURE');
  }
  await sourceRuntime.buildBackupRuntime().exportTo(packagePath);
  controller.markB0Exported();
  final sourceRoot = p.normalize(p.absolute(sourceRuntime.root.path));
  await sourceRuntime.closeForRestart();

  var restoreRuntime = await TrainCIsolatedRuntime.create();
  final restoreRoot = p.normalize(p.absolute(restoreRuntime.root.path));
  if (p.equals(sourceRoot, restoreRoot)) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_ISOLATION_FAILURE');
  }
  await restoreRuntime.open();
  final blank = await restoreRuntime.verifyBlankStore();
  if (!blank.passed) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_ISOLATION_FAILURE');
  }
  final restorePort = restoreRuntime.buildBackupRuntime();
  await restorePort.prepareRestore(packagePath);
  await restorePort.commitPreparedRestore();
  restoreRuntime = await restoreRuntime.reopenFresh();
  final restore = await _captureCheckpoint(restoreRuntime, reviewed);
  final restoreRender = await _renderMandatoryQuestions(restoreRuntime);
  if (!restore.equivalentTo(restart) ||
      !restoreRender.values.every((value) => value)) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_B0_IDENTITY_MISMATCH');
  }
  controller.markB0Restored();
  await restoreRuntime.dispose();

  sourceRuntime = await controller.reattachRuntime();
  final persistentRuntimeCapability = authority.runtimeCapabilityForReattach;
  await _retirePersistentRuntimeCapability(
    sourceRuntime,
    persistentRuntimeCapability,
  );
  sourceRuntime = await sourceRuntime.reopenFresh();
  final finalSourceCheckpoint =
      await _captureCheckpoint(sourceRuntime, reviewed);
  if (!finalSourceCheckpoint.equivalentTo(restart)) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_RESTART_FAILURE');
  }

  final parseFacts = TrainCParseFacts(
    blockCount: _nonNegativeInt(parseMap['blockCount']),
    imageBlockCount: _nonNegativeInt(parseMap['imageBlockCount']),
    tableBlockCount: _nonNegativeInt(parseMap['tableBlockCount']),
    referencedImageBlockCount:
        _nonNegativeInt(parseMap['referencedImageBlockCount']),
    referencedTableBlockCount:
        _nonNegativeInt(parseMap['referencedTableBlockCount']),
    assembledQuestionCount: _positiveInt(parseMap['assembledQuestionCount']),
    finalQuestionCount: _positiveInt(parseMap['finalQuestionCount']),
    storageRoute: _string(parseMap['storageRoute']),
    storageReason: _string(parseMap['storageReason']),
    sourceImages: sourceImages,
    layoutChunkSize: trainCProductionPdfPageChunkSize,
  );
  final renderEvidence = _TrainCL1BRenderEvidence(
    restart: restartRender,
    restore: restoreRender,
  );
  final phaseFacts = TrainCRuntimePhaseFacts(
    input: input,
    parse: parseFacts,
    candidateCheckpoint: candidate,
    requestLedger: requestLedger,
    commitCheckpoint: commit,
    restartCheckpoint: restart,
    b0: TrainCB0PhaseFacts(
      packagePath: packagePath,
      preB0Checkpoint: preB0,
      restoreCheckpoint: restore,
    ),
    restartProviderDispatchCount: 0,
  );
  final source = TrainCRuntimeEvidenceSource(
    runtime: sourceRuntime,
    phaseFacts: phaseFacts,
    reviewedIdentity: reviewed,
    renderEvidence: renderEvidence,
  );
  final result = await TrainCTrustedEvidenceCollector(
    reviewedIdentity: reviewed,
  ).collect(source);
  if (!result.schemaValid ||
      !result.acceptanceAuthorized ||
      result.evidence['result'] != 'PASS') {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_FIRST_LOSS_UNKNOWN');
  }
  publishTrainCSafeEvidenceAfterFinalization(
    attemptCapability: capabilityValue,
    evidence: result.evidence,
    finalizeDurably: controller.markFinalized,
  );
  await client.reportPass(const <String, Object?>{
    'result': 'PASS',
    'acceptanceAuthorized': true,
  });
  return controller;
}

Future<void> _waitForPhase(
  TrainCL1BPhaseController controller,
  TrainCLiveRunPhase expected, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final phase = controller.status.phase;
    if (phase == expected) return;
    if (phase == TrainCLiveRunPhase.failedConsumed) {
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_COMMIT_FAILURE');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw const TrainCL1BLiveRuntimeException('TRAIN_C_COMMIT_FAILURE');
}

Future<TrainCRuntimeCheckpoint> _captureCheckpoint(
  TrainCIsolatedRuntime runtime,
  TrainCReviewedIdentity reviewed,
) {
  final empty = TrainCRuntimeCheckpoint.empty();
  return TrainCRuntimeEvidenceSource(
    runtime: runtime,
    reviewedIdentity: reviewed,
    phaseFacts: TrainCRuntimePhaseFacts(
      input: const TrainCInputFacts(
        sha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
        sizeBytes: 1,
        pageCount: 1,
      ),
      parse: const TrainCParseFacts(
        blockCount: 0,
        imageBlockCount: 0,
        tableBlockCount: 0,
        referencedImageBlockCount: 0,
        referencedTableBlockCount: 0,
        assembledQuestionCount: 0,
        finalQuestionCount: 0,
        storageRoute: 'typedV2',
        storageReason: 'typed_candidate_ready',
      ),
      candidateCheckpoint: TrainCCandidateCheckpoint.empty(),
      requestLedger: TrainCRequestLedger(),
      commitCheckpoint: empty,
      restartCheckpoint: empty,
      b0: TrainCB0PhaseFacts(
        packagePath: '',
        preB0Checkpoint: empty,
        restoreCheckpoint: empty,
      ),
    ),
  ).captureCheckpoint();
}

Future<Map<int, bool>> _renderMandatoryQuestions(
  TrainCIsolatedRuntime runtime,
) async {
  final db = await runtime.database;
  final rows = await db.query(
    'question_v2_payloads',
    columns: const <String>['payload_json'],
  );
  final drafts = <int, QuestionDraftV2>{};
  for (final row in rows) {
    final payload = row['payload_json'];
    if (payload is! String || payload.isEmpty) continue;
    try {
      final draft = const QuestionDraftV2Codec().decode(jsonDecode(payload));
      final number = draft.questionNumber;
      if (number != null && const <int>{5, 18, 19}.contains(number)) {
        drafts[number] = draft;
      }
    } catch (_) {
      throw const TrainCL1BLiveRuntimeException(
        'TRAIN_C_TYPED_ENVELOPE_FAILURE',
      );
    }
  }
  if (drafts.length != 3) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_NUMBERING_FAILURE');
  }
  final result = <int, bool>{};
  for (final number in const <int>[5, 18, 19]) {
    result[number] = await _renderQuestionDraft(
      drafts[number]!,
      runtime.contentAssetStore,
    );
  }
  return result;
}

Future<bool> _renderQuestionDraft(
  QuestionDraftV2 draft,
  ManagedContentAssetStore resolver,
) async {
  final contents = <RichContent>[
    draft.stem,
    for (final option in draft.options) option.content,
    if (draft.answer case ContentAnswer(:final content)) content,
    if (draft.explanation != null) draft.explanation!,
  ];
  final expectedImages = contents.fold<int>(
    0,
    (sum, content) => sum + reachableImageNodes(content).length,
  );
  if (expectedImages <= 0) return false;
  var flutterFailure = false;
  final previousHandler = FlutterError.onError;
  FlutterError.onError = (_) {
    flutterFailure = true;
  };
  try {
    runApp(_TrainCL1BRenderProbeApp(contents: contents, resolver: resolver));
    for (var attempt = 0; attempt < 100; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) continue;
      var rawImages = 0;
      void visit(Element element) {
        if (element.widget is RawImage) rawImages++;
        element.visitChildren(visit);
      }

      visit(root);
      if (!flutterFailure && rawImages >= expectedImages) return true;
    }
    return false;
  } finally {
    FlutterError.onError = previousHandler;
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
  }
}

final class _TrainCL1BRenderProbeApp extends StatelessWidget {
  const _TrainCL1BRenderProbeApp({
    required this.contents,
    required this.resolver,
  });

  final List<RichContent> contents;
  final ManagedContentAssetStore resolver;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: <Widget>[
              for (final content in contents)
                RichContentRenderer(content: content, assetResolver: resolver),
            ],
          ),
        ),
      ),
    );
  }
}

final class _TrainCL1BRenderEvidence implements TrainCRenderEvidencePort {
  const _TrainCL1BRenderEvidence({
    required this.restart,
    required this.restore,
  });

  final Map<int, bool> restart;
  final Map<int, bool> restore;

  @override
  bool didRender({
    required int questionNumber,
    required TrainCRenderStage stage,
  }) {
    return switch (stage) {
      TrainCRenderStage.restart => restart[questionNumber] ?? false,
      TrainCRenderStage.b0Restore => restore[questionNumber] ?? false,
    };
  }
}

Future<TrainCOsProcessRestartProof> _runPersistentRestartProof(
  String capability,
  TrainCDurableRestartCheckpoint expected,
) {
  return runTrainCRestartProcess(
    timeout: const Duration(seconds: 30),
    parentPid: pid,
    expectedCheckpoint: expected,
    start: () async {
      final dart = _resolveDartExecutable();
      final packageConfig = p.join(
        Directory.current.path,
        '.dart_tool',
        'package_config.json',
      );
      final script = p.join(
        Directory.current.path,
        'tool',
        'train_c_restart_probe.dart',
      );
      final process = await Process.start(
        dart,
        <String>[
          '--packages=$packageConfig',
          'run',
          '--verbosity=error',
          script,
          '--child',
        ],
        workingDirectory: Directory.current.path,
        environment: buildTrainCRestartChildEnvironment(
          capability,
          parentEnvironment: Platform.environment,
        ),
        includeParentEnvironment: false,
        runInShell: false,
      );
      return (
        stdout: process.stdout,
        stderr: process.stderr,
        exitCode: process.exitCode,
        kill: process.kill,
      );
    },
  );
}

String _resolveDartExecutable() {
  final candidates = <String>[
    if ((Platform.environment['DART_SDK'] ?? '').trim().isNotEmpty)
      p.join(
        Platform.environment['DART_SDK']!.trim(),
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      ),
    if ((Platform.environment['FLUTTER_ROOT'] ?? '').trim().isNotEmpty)
      p.join(
        Platform.environment['FLUTTER_ROOT']!.trim(),
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      ),
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return Platform.isWindows ? 'dart.exe' : 'dart';
}

Future<void> _retirePersistentRuntimeCapability(
  TrainCIsolatedRuntime runtime,
  String capability,
) async {
  try {
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(capability))),
    );
    if (decoded is! Map ||
        decoded['root'] is! String ||
        decoded['nonce'] is! String) {
      throw const FormatException();
    }
    final root = p.normalize(p.absolute(decoded['root'] as String));
    final ownedRoot = p.normalize(p.absolute(runtime.root.path));
    final nonce = decoded['nonce'] as String;
    if (!p.equals(root, ownedRoot) || nonce.isEmpty) {
      throw const FormatException();
    }
    final capabilityFile = File(p.join(ownedRoot, '.train_c_reattach_v1'));
    if (!capabilityFile.existsSync() ||
        capabilityFile.readAsStringSync() != '$nonce\n') {
      throw const FormatException();
    }
    capabilityFile.deleteSync();
  } catch (_) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_RESTART_FAILURE');
  }
}

/// Stages final TRAIN C evidence privately, advances the durable terminal
/// phase, and only then publishes the user-visible JSON + digest pair.
///
/// If durable finalization fails, no final PASS evidence path is created. If
/// publication fails after finalization, any partial final pair is removed so
/// consumers can never observe a complete PASS artifact before `FINALIZED`.
void publishTrainCSafeEvidenceAfterFinalization({
  required String attemptCapability,
  required Map<String, dynamic> evidence,
  required void Function() finalizeDurably,
}) {
  final publication = _stageSafeEvidence(attemptCapability, evidence);
  try {
    finalizeDurably();
  } catch (_) {
    publication.discard();
    rethrow;
  }
  publication.publish();
}

_TrainCSafeEvidencePublication _stageSafeEvidence(
  String attemptCapability,
  Map<String, dynamic> evidence,
) {
  File? stagedEvidence;
  File? stagedDigest;
  try {
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(attemptCapability))),
    );
    if (decoded is! Map || decoded['directory'] is! String) {
      throw const FormatException();
    }
    final directory = Directory(decoded['directory'] as String);
    if (!directory.isAbsolute || !directory.existsSync()) {
      throw const FormatException();
    }
    final encoded = '${const JsonEncoder.withIndent('  ').convert(evidence)}\n';
    final evidenceFile = File(
      p.join(directory.path, 'train_c_run_1_evidence.json'),
    );
    final digestFile = File(
      p.join(directory.path, 'train_c_run_1_evidence.json.sha256'),
    );
    stagedEvidence = File('${evidenceFile.path}.pending');
    stagedDigest = File('${digestFile.path}.pending');
    if (evidenceFile.existsSync() ||
        digestFile.existsSync() ||
        stagedEvidence.existsSync() ||
        stagedDigest.existsSync()) {
      throw const FormatException();
    }

    stagedEvidence.createSync(exclusive: true);
    stagedEvidence.writeAsStringSync(encoded, flush: true);
    stagedDigest.createSync(exclusive: true);
    stagedDigest.writeAsStringSync(
      '${sha256Hex(utf8.encode(encoded))}\n',
      flush: true,
    );
    return _TrainCSafeEvidencePublication(
      evidenceFile: evidenceFile,
      digestFile: digestFile,
      stagedEvidence: stagedEvidence,
      stagedDigest: stagedDigest,
    );
  } catch (_) {
    _deleteFileBestEffort(stagedEvidence);
    _deleteFileBestEffort(stagedDigest);
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_PRIVACY_FAILURE');
  }
}

final class _TrainCSafeEvidencePublication {
  const _TrainCSafeEvidencePublication({
    required this.evidenceFile,
    required this.digestFile,
    required this.stagedEvidence,
    required this.stagedDigest,
  });

  final File evidenceFile;
  final File digestFile;
  final File stagedEvidence;
  final File stagedDigest;

  void publish() {
    try {
      if (evidenceFile.existsSync() ||
          digestFile.existsSync() ||
          !stagedEvidence.existsSync() ||
          !stagedDigest.existsSync()) {
        throw const FormatException();
      }
      stagedEvidence.renameSync(evidenceFile.path);
      stagedDigest.renameSync(digestFile.path);
    } catch (_) {
      _deleteFileBestEffort(evidenceFile);
      _deleteFileBestEffort(digestFile);
      _deleteFileBestEffort(stagedEvidence);
      _deleteFileBestEffort(stagedDigest);
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_PRIVACY_FAILURE');
    }
  }

  void discard() {
    _deleteFileBestEffort(stagedEvidence);
    _deleteFileBestEffort(stagedDigest);
  }
}

void _deleteFileBestEffort(File? file) {
  if (file == null) return;
  try {
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
}

void _markConsumedFailure(TrainCL1BPhaseController? controller) {
  if (controller == null) return;
  try {
    final state = controller.status;
    if (state.attemptState == TrainCLiveRunAttemptState.consumed &&
        state.phase == TrainCLiveRunPhase.parseRunning) {
      controller.markFailedConsumed();
    }
  } catch (_) {}
}

Future<void> _safeReportFailure(
  TrainCL1BSupervisorClient? client,
  String code,
) async {
  if (client == null) return;
  try {
    await client.reportFailure(code);
  } catch (_) {}
}

String _capabilityValue() {
  final value =
      Platform.environment[trainCLiveAttemptCapabilityEnvironment]?.trim() ??
          '';
  if (value.isEmpty) {
    throw const TrainCL1BLiveRuntimeException(
      'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
    );
  }
  return value;
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_HARNESS_NOT_READY');
  }
  return Map<String, Object?>.from(value);
}

Map<int, bool> _renderMap(Object? value) {
  final map = _map(value);
  final result = <int, bool>{};
  for (final number in const <int>[5, 18, 19]) {
    final rendered = map['$number'];
    if (rendered is! bool) {
      throw const TrainCL1BLiveRuntimeException('TRAIN_C_HARNESS_NOT_READY');
    }
    result[number] = rendered;
  }
  return result;
}

String _string(Object? value) {
  if (value is! String || value.isEmpty) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_HARNESS_NOT_READY');
  }
  return value;
}

String _digest(Object? value) {
  final text = _string(value);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(text)) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_HARNESS_NOT_READY');
  }
  return text;
}

int _nonNegativeInt(Object? value) {
  if (value is! int || value < 0) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_HARNESS_NOT_READY');
  }
  return value;
}

int _positiveInt(Object? value) {
  if (value is! int || value <= 0) {
    throw const TrainCL1BLiveRuntimeException('TRAIN_C_HARNESS_NOT_READY');
  }
  return value;
}
