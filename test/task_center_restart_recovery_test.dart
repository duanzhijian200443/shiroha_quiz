import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/task_center_projection.dart';
import 'package:shiroha_quiz/ui/pages/task_center_screen.dart';

/// Synthetic B1C-era processing OCR snapshot without B1D attempt metadata.
///
/// This represents the persisted state of a task that was mid-OCR when the
/// application was forcefully terminated under the old B1C code. The snapshot
/// intentionally omits [TaskManager.keyAttemptToken] and
/// [TaskManager.keyAttemptState] to exercise the compatibility bridge.
Map<String, dynamic> _legacyProcessingOcrSnapshot({
  required String taskId,
  String title = 'synthetic_legacy.pdf',
}) {
  return ImportTask(
    id: taskId,
    title: title,
    status: TaskStatus.processing,
    progressText: 'SYNTHETIC_LEGACY_PROGRESS',
    percent: 0.42,
    parsedData: const <Map<String, dynamic>>[
      <String, dynamic>{'content': 'SYNTHETIC_PARTIAL_PAYLOAD_SENTINEL'},
    ],
    pendingChunks: const <String>['SYNTHETIC_PENDING_CHUNK'],
    failedChunks: const <String>['SYNTHETIC_FAILED_CHUNK'],
    diagnostics: const <String, dynamic>{
      TaskManager.keyTraceId: 'legacy-trace-b1c',
      TaskManager.keyParseMode: 'ocr',
      // No keyAttemptToken — B1C snapshots did not persist attempt tokens.
      // No keyAttemptState — B1C snapshots did not persist attempt state.
      // attemptNumber defaults to 1 via ImportTask.attemptNumber getter.
    },
  ).toMap();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget createWidgetUnderTest({
    required TaskManager taskManager,
    ImportTaskCoordinator? taskCoordinator,
    TaskCenterRetryFilePicker? retryFilePicker,
  }) {
    return MaterialApp(
      home: TaskCenterScreen(
        taskManager: taskManager,
        taskCoordinator: taskCoordinator,
        retryFilePicker: retryFilePicker,
      ),
    );
  }

  Future<void> selectCategory(
    WidgetTester tester,
    TaskCenterCategory category,
  ) async {
    await tester.tap(
      find.byKey(ValueKey<String>('task-category-${category.name}')),
    );
    await tester.pump();
  }

  // -----------------------------------------------------------------------
  // Test 1: Legacy processing OCR snapshot becomes interrupted without auto
  //         parsing after simulated restart.
  // -----------------------------------------------------------------------
  testWidgets(
    'legacy processing OCR snapshot becomes interrupted without auto parsing',
    (WidgetTester tester) async {
      // Arrange: simulate persisted B1C snapshot loaded on startup.
      final saved = <Map<String, dynamic>>[];
      final legacySnapshot = _legacyProcessingOcrSnapshot(
        taskId: 'restart-legacy-task',
      );

      // A second unrelated task to verify it is not affected.
      final unrelatedSnapshot = ImportTask(
        id: 'unrelated-completed',
        title: 'synthetic_legacy.pdf', // same filename, different taskId
        status: TaskStatus.completed,
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'unrelated-completed-trace',
          TaskManager.keyParseMode: 'ocr',
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'unrelated-completed-token',
          TaskManager.keyAttemptState: 'readyForReview',
        },
      ).toMap();

      final taskManager = TaskManager.forTesting(
        loadTasks: () async => <Map<String, dynamic>>[
          legacySnapshot,
          unrelatedSnapshot,
        ],
        saveTask: (taskMap) async {
          saved.add(Map<String, dynamic>.from(taskMap));
        },
      );
      await taskManager.ready;

      // ----- Layer 1: TaskManager startup normalization -----

      // The legacy processing task must become error + interrupted.
      final interruptedTask =
          taskManager.tasks.singleWhere((t) => t.id == 'restart-legacy-task');
      expect(interruptedTask.status, TaskStatus.error);
      expect(interruptedTask.attemptState, ImportAttemptState.interrupted);
      expect(interruptedTask.attemptToken, isNull,
          reason: 'attempt token must be cleared on interrupt');
      expect(interruptedTask.parsedData, isNull,
          reason: 'partial payload must be purged');
      expect(interruptedTask.pendingChunks, isNull);
      expect(interruptedTask.failedChunks, isNull);
      expect(interruptedTask.attemptNumber, 1,
          reason: 'default attempt number preserved for B1C snapshot');

      // The unrelated same-name task must remain untouched.
      final unrelated =
          taskManager.tasks.singleWhere((t) => t.id == 'unrelated-completed');
      expect(unrelated.status, TaskStatus.completed);
      expect(unrelated.attemptState, ImportAttemptState.readyForReview);

      // Interrupted snapshot must have been persisted.
      expect(saved, hasLength(1));
      expect(saved.single['id'], 'restart-legacy-task');
      final restoredTask = ImportTask.fromMap(saved.single);
      expect(restoredTask.attemptState, ImportAttemptState.interrupted);
      expect(restoredTask.attemptToken, isNull);
      expect(saved.single['parsed_data'], isNull);
      expect(saved.single['pending_chunks'], isNull);
      expect(saved.single['failed_chunks'], isNull);

      // ----- Layer 2: Task Center projection -----

      final projection = TaskCenterProjection.fromTasks(taskManager.tasks);
      // The interrupted task should appear under the error category.
      expect(projection.countFor(TaskCenterCategory.error), 1);
      expect(projection.countFor(TaskCenterCategory.completed), 1);
      expect(projection.countFor(TaskCenterCategory.processing), 0);

      final presentation =
          TaskCenterProjection.presentationFor(interruptedTask);
      expect(presentation.statusLabel, '已中断');
      expect(presentation.canRetry, isTrue);
      expect(presentation.canCancel, isFalse);
      expect(presentation.summaryOverride, contains('应用重启后任务已中断'));

      // ----- Layer 3: Widget rendering -----

      // Parser must not be called — verifies no auto parsing.
      var parserCalled = false;
      final coordinator = ImportTaskCoordinator(
        taskManager: taskManager,
        readiness: taskManager.ready,
        parser: (_) async {
          parserCalled = true;
          return const ImportParseResult(
            questions: <Map<String, dynamic>>[],
          );
        },
      );

      await tester.pumpWidget(createWidgetUnderTest(
        taskManager: taskManager,
        taskCoordinator: coordinator,
      ));
      await tester.pump();

      // Switch to error category where the interrupted task lives.
      await selectCategory(tester, TaskCenterCategory.error);

      // Verify "已中断" status label is displayed.
      expect(find.text('已中断'), findsOneWidget);

      // Verify "重新选择文件重试" retry button is present.
      expect(
        find.byKey(
          const ValueKey<String>('task-retry-restart-legacy-task'),
        ),
        findsOneWidget,
      );

      // Verify summary override is displayed.
      expect(
        find.textContaining('应用重启后任务已中断'),
        findsOneWidget,
      );

      // Parser must not have been called during rendering.
      expect(parserCalled, isFalse,
          reason: 'interrupted task must not auto-parse');
    },
  );

  // -----------------------------------------------------------------------
  // Test 2: Interrupted task reselects files and restarts the same task
  //         identity.
  // -----------------------------------------------------------------------
  testWidgets(
    'interrupted task reselects files and restarts the same task identity',
    (WidgetTester tester) async {
      // Arrange: load the legacy snapshot and let TaskManager normalise it.
      final saved = <Map<String, dynamic>>[];
      final legacySnapshot = _legacyProcessingOcrSnapshot(
        taskId: 'retry-identity-task',
      );

      final taskManager = TaskManager.forTesting(
        loadTasks: () async => <Map<String, dynamic>>[legacySnapshot],
        saveTask: (taskMap) async {
          saved.add(Map<String, dynamic>.from(taskMap));
        },
      );
      await taskManager.ready;

      // Pre-condition: task is now interrupted.
      final interruptedTask = taskManager.tasks.single;
      expect(interruptedTask.status, TaskStatus.error);
      expect(interruptedTask.attemptState, ImportAttemptState.interrupted);
      expect(interruptedTask.attemptNumber, 1);
      saved.clear(); // Clear the startup save to isolate retry saves.

      // Track parser invocations with a gate to observe intermediate state.
      final capturedRequest = Completer<ImportParseRequest>();
      final parseGate = Completer<void>();
      var traceIndex = 0;
      var attemptIndex = 0;
      final coordinator = ImportTaskCoordinator(
        taskManager: taskManager,
        readiness: taskManager.ready,
        parser: (request) async {
          if (!capturedRequest.isCompleted) {
            capturedRequest.complete(request);
          }
          // Block until the test releases the gate.
          await parseGate.future;
          return const ImportParseResult(
            questions: <Map<String, dynamic>>[
              <String, dynamic>{
                'q_num': '1',
                'content': 'SYNTHETIC_REPLACEMENT_QUESTION',
                'standard_answer': 'A',
              },
            ],
          );
        },
        traceIdFactory: () => 'retry-trace-${traceIndex++}',
        attemptTokenFactory: () => 'retry-attempt-${attemptIndex++}',
      );

      // Simulate cancelled file pick first (user cancelled the dialog).
      FilePickerResult? nextPickerResult;
      Future<FilePickerResult?> fakePicker() async => nextPickerResult;

      await tester.pumpWidget(createWidgetUnderTest(
        taskManager: taskManager,
        taskCoordinator: coordinator,
        retryFilePicker: fakePicker,
      ));
      await tester.pump();
      await selectCategory(tester, TaskCenterCategory.error);

      // ----- Cancel scenario: user dismisses file picker -----
      nextPickerResult = null; // Simulate cancellation.
      await tester.tap(
        find.byKey(
          const ValueKey<String>('task-retry-retry-identity-task'),
        ),
      );
      await tester.pump();
      // Allow async microtasks.
      await tester.pump(const Duration(milliseconds: 50));

      // Task must remain interrupted — cancellation must not change attempt.
      expect(taskManager.tasks.single.status, TaskStatus.error);
      expect(
        taskManager.tasks.single.attemptState,
        ImportAttemptState.interrupted,
      );
      expect(taskManager.tasks.single.attemptNumber, 1,
          reason: 'cancelled pick must not increment attempt');
      expect(capturedRequest.isCompleted, isFalse,
          reason: 'parser must not be called on cancelled pick');

      // ----- Success scenario: user picks a synthetic PDF -----
      nextPickerResult = FilePickerResult(<PlatformFile>[
        PlatformFile(
          name: 'synthetic_retry.pdf',
          size: 1024,
          path: r'C:\synthetic_test\synthetic_retry.pdf',
        ),
      ]);

      await tester.tap(
        find.byKey(
          const ValueKey<String>('task-retry-retry-identity-task'),
        ),
      );
      await tester.pump();
      // Allow Coordinator async path to reach the parser (but parser is gated).
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // Task identity must be preserved.
      expect(taskManager.tasks.single.id, 'retry-identity-task');

      // Attempt must have incremented.
      expect(taskManager.tasks.single.attemptNumber, 2);

      // New traceId and attemptToken must be generated.
      expect(taskManager.tasks.single.traceId, isNot('legacy-trace-b1c'));
      expect(taskManager.tasks.single.traceId, startsWith('retry-trace-'));
      expect(taskManager.tasks.single.attemptToken, isNotNull);
      expect(
        taskManager.tasks.single.attemptToken,
        startsWith('retry-attempt-'),
      );

      // Task must be in processing state while parser is blocked.
      expect(taskManager.tasks.single.status, TaskStatus.processing);

      // Parser must have received the correct ImportParseRequest.
      final request =
          await capturedRequest.future.timeout(const Duration(seconds: 5));
      expect(request.taskId, 'retry-identity-task');
      expect(request.mode, ImportParseMode.ocr);
      expect(
        request.filePaths,
        <String>[r'C:\synthetic_test\synthetic_retry.pdf'],
      );
      expect(request.fileNames, <String>['synthetic_retry.pdf']);
      expect(request.maxConcurrency, 1);

      // Release the parser gate to let the pipeline complete.
      parseGate.complete();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // After parse completes the task transitions to pendingReview.
      expect(taskManager.tasks.single.id, 'retry-identity-task',
          reason: 'task identity must survive the full pipeline');
      expect(taskManager.tasks.single.attemptNumber, 2);

      // New path must not leak into persisted diagnostics.
      final persistedDiagnostics = taskManager.tasks.single.diagnostics;
      if (persistedDiagnostics != null) {
        final encoded = jsonEncode(persistedDiagnostics);
        expect(
          encoded,
          isNot(contains(r'C:\synthetic_test')),
          reason: 'synthetic file path must not appear in diagnostics',
        );
      }

      // Persisted snapshots: startup save (1) was cleared; retry triggers
      // at least one new save via restartAttempt persistence.
      expect(saved, isNotEmpty);
    },
  );
}
