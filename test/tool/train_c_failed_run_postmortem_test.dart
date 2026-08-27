import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/typed_import_commit_guard.dart';
import 'package:shiroha_quiz/data/repositories/import_task_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/candidate_asset_lease.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

import '../../tool/train_c_evidence_probe.dart';
import '../../tool/train_c_failed_run_postmortem.dart';
import '../../tool/train_c_isolated_runtime.dart';
import '../../tool/train_c_live_attempt_authority.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(DatabaseHelper.resetRuntimeProfileForTesting);

  test('legacy fallback is recovered without exposing parsed content', () async {
    final fixture = _failedCapability(runtimeCapability: 'runtime-fixture-a');
    addTearDown(fixture.dispose);
    final before = fixture.authority.snapshot;

    final report = await TrainCFailedRunPostmortem.inspect(
      capabilityValue: fixture.capabilityValue,
      taskReader: (_) async => <Map<String, dynamic>>[
        <String, dynamic>{
          'status': TypedImportCommitPersistence.pendingReviewStatusCode,
          'parsed_data': jsonEncode(
            List<Map<String, dynamic>>.generate(
              22,
              (index) => <String, dynamic>{'content': 'private-$index'},
            ),
          ),
          'diagnostics': jsonEncode(<String, dynamic>{
            TypedImportCommitPersistence.keyImportStorageRoute: 'legacyV1',
            TypedImportCommitPersistence.keyImportStorageReason:
                'typed_candidate_raw_explanation_diverged',
          }),
        },
      ],
    );

    expect(report['runNumber'], 1);
    expect(report['attemptState'], 'CONSUMED');
    expect(report['phase'], 'FAILED_CONSUMED');
    expect(report['revision'], 5);
    expect(report['parsedDataPresent'], isTrue);
    expect(report['parsedQuestionCount'], 22);
    expect(report['storageRoute'], 'legacyV1');
    expect(
      report['storageReason'],
      'typed_candidate_raw_explanation_diverged',
    );
    expect(report['candidateLeasePresent'], isFalse);
    expect(report['stateUnchanged'], isTrue);
    expect(fixture.authority.snapshot.revision, before.revision);

    final encoded = jsonEncode(report);
    expect(encoded, isNot(contains('private-')));
  });

  test('typed route reports only bounded lease facts', () async {
    final fixture = _failedCapability(runtimeCapability: 'runtime-fixture-b');
    addTearDown(fixture.dispose);

    final report = await TrainCFailedRunPostmortem.inspect(
      capabilityValue: fixture.capabilityValue,
      taskReader: (_) async => <Map<String, dynamic>>[
        <String, dynamic>{
          'status': TypedImportCommitPersistence.pendingReviewStatusCode,
          'parsed_data': jsonEncode(const <Map<String, dynamic>>[
            <String, dynamic>{},
          ]),
          'diagnostics': jsonEncode(<String, dynamic>{
            TypedImportCommitPersistence.keyImportStorageRoute: 'typedV2',
            TypedImportCommitPersistence.keyImportStorageReason:
                TypedImportCommitPersistence.typedCandidateReadyReasonValue,
            candidateAssetSourceIdKey: 'secret-source-id',
            candidateAssetLocalIdsKey: const <String>[
              'secret-asset-a',
              'secret-asset-b',
            ],
          }),
        },
      ],
    );

    expect(report['storageRoute'], 'typedV2');
    expect(
      report['storageReason'],
      TypedImportCommitPersistence.typedCandidateReadyReasonValue,
    );
    expect(report['candidateLeaseFieldsPresent'], isTrue);
    expect(report['candidateLeasePresent'], isTrue);
    expect(report['candidateLeaseMalformed'], isFalse);
    expect(report['candidateLeaseSourceIdPresent'], isTrue);
    expect(report['candidateLeaseLocalIdCount'], 2);

    final encoded = jsonEncode(report);
    expect(encoded, isNot(contains('secret-source-id')));
    expect(encoded, isNot(contains('secret-asset-a')));
    expect(encoded, isNot(contains('secret-asset-b')));
  });

  test('non-failed capability is refused before task inspection', () async {
    final stateDirectory = Directory.systemTemp.createTempSync(
      'train_c_postmortem_prepared_',
    );
    addTearDown(() {
      if (stateDirectory.existsSync()) {
        stateDirectory.deleteSync(recursive: true);
      }
    });
    final capabilityValue = TrainCLiveAttemptAuthority.authorize(
      stateDirectory: stateDirectory,
      approvedHarnessHead: _head,
      approvedBase: _base,
    );

    await expectLater(
      TrainCFailedRunPostmortem.inspect(
        capabilityValue: capabilityValue,
        taskReader: (_) async => fail('task reader must not run'),
      ),
      throwsA(_code(trainCPostmortemNotAvailable)),
    );
  });

  test('invalid storage metadata fails with a fixed safe code', () async {
    final fixture = _failedCapability(runtimeCapability: 'runtime-fixture-c');
    addTearDown(fixture.dispose);

    await expectLater(
      TrainCFailedRunPostmortem.inspect(
        capabilityValue: fixture.capabilityValue,
        taskReader: (_) async => <Map<String, dynamic>>[
          <String, dynamic>{
            'status': TypedImportCommitPersistence.pendingReviewStatusCode,
            'parsed_data': jsonEncode(const <Map<String, dynamic>>[]),
            'diagnostics': jsonEncode(<String, dynamic>{
              TypedImportCommitPersistence.keyImportStorageRoute:
                  'unsafe-route-value',
            }),
          },
        ],
      ),
      throwsA(_code(trainCPostmortemDataInvalid)),
    );
  });

  test('read-only runtime seam rejects sqlite writes', () async {
    final runtime = await TrainCIsolatedRuntime.create();
    await runtime.open();
    final runtimeCapability = await runtime.issuePersistentReattachCapability();
    addTearDown(() async {
      await DatabaseHelper.resetRuntimeProfileForTesting();
      if (await runtime.root.exists()) {
        await runtime.root.delete(recursive: true);
      }
    });
    await runtime.closeForRestart();
    final beforeEntries = await _sortedPaths(runtime.dbDirectory);

    // Model the postmortem process boundary after the failed Live child exits.
    await DatabaseHelper.resetRuntimeProfileForTesting();

    await expectLater(
      TrainCIsolatedRuntime.inspectReadOnlyFromCapability<void>(
        runtimeCapability,
        (db) async {
          await db.rawDelete('DELETE FROM import_tasks');
        },
      ),
      throwsA(
        isA<TrainCIsolationException>().having(
          (error) => error.safeDetail,
          'safeDetail',
          'TRAIN_C_REATTACH_READ_ONLY_DATABASE_FAILURE',
        ),
      ),
    );
    expect(
      DatabaseHelper.runtimeProfile,
      DatabaseRuntimeProfile.explicitReadOnly,
    );
    expect(await _sortedPaths(runtime.dbDirectory), beforeEntries);
  });

  test(
    'default reader preserves failed capability and durable task row',
    () async {
      final runtime = await TrainCIsolatedRuntime.create();
      await runtime.open();
      final repository = ImportTaskRepository(
        databaseHelper: DatabaseHelper.instance,
      );
      await repository.saveImportTask(
        ImportTask(
          id: 'postmortem-task',
          title: 'synthetic',
          status: TaskStatus.pendingReview,
          parsedData: List<Map<String, dynamic>>.generate(
            22,
            (_) => <String, dynamic>{},
          ),
          diagnostics: const <String, dynamic>{
            TypedImportCommitPersistence.keyImportStorageRoute: 'legacyV1',
            TypedImportCommitPersistence.keyImportStorageReason:
                'typed_candidate_raw_explanation_diverged',
            TypedImportCommitPersistence.keyAttemptState:
                TypedImportCommitPersistence.readyForReviewAttemptStateValue,
          },
        ).toMap(),
      );
      final beforeRows = await repository.getAllImportTasks();
      final runtimeCapability =
          await runtime.issuePersistentReattachCapability();
      final fixture = _failedCapability(runtimeCapability: runtimeCapability);
      addTearDown(fixture.dispose);
      addTearDown(() async {
        await DatabaseHelper.resetRuntimeProfileForTesting();
        if (await runtime.root.exists()) {
          await runtime.root.delete(recursive: true);
        }
      });
      await runtime.closeForRestart();
      final beforeDbEntries = await _sortedPaths(runtime.dbDirectory);

      // The real failed Live child has exited before postmortem starts. Reset
      // test-only singleton state to model that fresh OS process boundary.
      await DatabaseHelper.resetRuntimeProfileForTesting();

      final beforeState = fixture.authority.snapshot;
      final report = await TrainCFailedRunPostmortem.inspect(
        capabilityValue: fixture.capabilityValue,
      );
      final afterState = fixture.authority.snapshot;

      expect(report['importTaskCount'], 1);
      expect(report['pendingReviewTaskCount'], 1);
      expect(report['parsedQuestionCount'], 22);
      expect(report['storageRoute'], 'legacyV1');
      expect(report['candidateLeasePresent'], isFalse);
      expect(afterState.revision, beforeState.revision);
      expect(afterState.phase, beforeState.phase);
      expect(afterState.attemptState, beforeState.attemptState);
      expect(
        DatabaseHelper.runtimeProfile,
        DatabaseRuntimeProfile.explicitReadOnly,
      );
      expect(await _sortedPaths(runtime.dbDirectory), beforeDbEntries);

      // Reopen once more in a fresh simulated process to prove the postmortem
      // itself did not mutate the durable task row or consume the capability.
      await DatabaseHelper.resetRuntimeProfileForTesting();
      final reopened = await TrainCIsolatedRuntime.reattachFromCapability(
        runtimeCapability,
        deleteRootOnDispose: false,
      );
      final afterRows = await ImportTaskRepository(
        databaseHelper: DatabaseHelper.instance,
      ).getAllImportTasks();
      expect(afterRows, beforeRows);
      await reopened.closeForRestart();
    },
  );
}

const _head = 'a000000000000000000000000000000000000000';
const _base = 'b000000000000000000000000000000000000000';

final class _CapabilityFixture {
  const _CapabilityFixture({
    required this.stateDirectory,
    required this.capabilityValue,
    required this.authority,
  });

  final Directory stateDirectory;
  final String capabilityValue;
  final TrainCLiveRunCapability authority;

  void dispose() {
    if (stateDirectory.existsSync()) {
      stateDirectory.deleteSync(recursive: true);
    }
  }
}

_CapabilityFixture _failedCapability({required String runtimeCapability}) {
  final stateDirectory = Directory.systemTemp.createTempSync(
    'train_c_postmortem_failed_',
  );
  final capabilityValue = TrainCLiveAttemptAuthority.authorize(
    stateDirectory: stateDirectory,
    approvedHarnessHead: _head,
    approvedBase: _base,
  );
  final authority = TrainCLiveAttemptAuthority.fromCapability(capabilityValue)
    ..verifyUnused(
      reviewedHarnessHead: _head,
      reviewedBase: _base,
    )
    ..bindRuntimeCapability(runtimeCapability)
    ..markConfigured()
    ..markParseRunning()
    ..consumeAtDispatch()
    ..markFailedConsumed();
  expect(authority.snapshot.revision, 5);
  return _CapabilityFixture(
    stateDirectory: stateDirectory,
    capabilityValue: capabilityValue,
    authority: authority,
  );
}

Future<List<String>> _sortedPaths(Directory directory) async {
  final paths = await directory
      .list(followLinks: false)
      .map((entity) => entity.path)
      .toList();
  paths.sort();
  return paths;
}

Matcher _code(String code) => isA<TrainCEvidenceProbeException>().having(
      (error) => error.code,
      'code',
      code,
    );
