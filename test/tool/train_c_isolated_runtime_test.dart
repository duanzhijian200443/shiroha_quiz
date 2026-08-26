import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

import '../../tool/train_c_isolated_runtime.dart';
import '../../tool/train_c_restart_proof.dart';

const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=';

List<int> _tinyPng() => base64Decode(_tinyPngBase64);

QuestionDraftV2 _draft({int? number}) {
  return QuestionDraftV2(
    questionId: 'question_${number ?? 1}',
    questionNumber: number,
    kind: QuestionKind.shortAnswer,
    stem: RichContent(nodes: const <ContentNode>[TextNode('synthetic')]),
    sourceRefs: <SourceRef>[SourceRef.document(sourceId: 'synthetic_source')],
  );
}

void main() {
  late TrainCIsolatedRuntime runtime;

  setUp(() async {
    runtime = await TrainCIsolatedRuntime.create();
    await runtime.open();
  });

  tearDown(() async {
    await runtime.dispose();
  });

  test('fresh self-created explicit-file runtime proves blank', () async {
    final proof = await runtime.verifyBlankStore();

    expect(proof.passed, isTrue);
    expect(proof.questionRows, 0);
    expect(proof.v2Sidecars, 0);
    expect(proof.libraryFiles, 0);
    expect(proof.importTasks, 0);
    expect(proof.contentAssets, 0);
    final openedPath = (await runtime.database).path;
    expect(p.isWithin(runtime.dbDirectory.path, openedPath), isTrue);
  });

  test('existing question row fails closed without deleting it', () async {
    final frozen = const QuestionV2PersistenceMapper().freezeForWrite(
      storageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
      bankName: 'synthetic',
      createdAt: 1,
      draft: _draft(),
    );
    final db = await runtime.database;
    await db.insert('questions', frozen.questionRow);

    await expectLater(
      runtime.verifyBlankStore(),
      throwsA(isA<TrainCIsolationException>()),
    );
    expect(await db.query('questions'), hasLength(1));
  });

  test('existing typed sidecar fails closed without deleting it', () async {
    final frozen = const QuestionV2PersistenceMapper().freezeForWrite(
      storageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
      bankName: 'synthetic',
      createdAt: 1,
      draft: _draft(),
    );
    final db = await runtime.database;
    await db.insert('questions', frozen.questionRow);
    await db.insert('question_v2_payloads', frozen.payloadRow);

    await expectLater(
      runtime.verifyBlankStore(),
      throwsA(isA<TrainCIsolationException>()),
    );
    expect(await db.query('question_v2_payloads'), hasLength(1));
  });

  test('existing managed asset fails closed without deleting it', () async {
    runtime.contentAssetStore.storeBytesSync(
      sourceId: 'synthetic_source',
      localAssetId: 'asset_1',
      bytes: _tinyPng(),
      mimeType: 'image/png',
    );

    await expectLater(
      runtime.verifyBlankStore(),
      throwsA(isA<TrainCIsolationException>()),
    );
    expect(await runtime.contentAssetStore.listAssets(), hasLength(1));
  });

  test('path escape fails closed', () {
    expect(
      () => runtime.containedPath(p.join(runtime.root.path, '..', 'escape')),
      throwsA(isA<TrainCIsolationException>()),
    );
  });

  test('runtime database resolves under isolated db root', () async {
    final databasePath = (await runtime.database).path;
    expect(
      p.isWithin(
        p.normalize(p.absolute(runtime.dbDirectory.path)),
        p.normalize(p.absolute(databasePath)),
      ),
      isTrue,
    );
    expect(
      p.isWithin(
        p.normalize(p.absolute(runtime.root.path)),
        p.normalize(p.absolute(databasePath)),
      ),
      isTrue,
    );
  });

  test(
    'restart proves a new OS process can reattach to the same root',
    () async {
      final first = runtime;
      final rootPath = first.root.path;
      final firstDatabasePath = (await first.database).path;

      final second = await first.reopenFresh();
      runtime = second;

      expect(second, isNot(same(first)));
      expect(second.root.path, rootPath);
      expect((await second.database).path, firstDatabasePath);
      expect(second.contentAssetStore, isNot(same(first.contentAssetStore)));
      expect(second.fileStorage, isNot(same(first.fileStorage)));
      final restartProof = second.osProcessRestartProof;
      expect(restartProof, isNotNull);
      expect(restartProof!.childPid, isNot(pid));
      expect(restartProof.parentPid, pid);
      expect(restartProof.providerDispatchCount, 0);
      expect(
        restartProof.checkpoint.durableDigest,
        matches(RegExp(r'^[0-9a-f]{64}$')),
      );
      expect(await second.verifyBlankStore(), isA<TrainCBlankStoreProof>());
    },
  );

  test('restart child environment uses a strict capability-only allowlist', () {
    final environment = buildTrainCRestartChildEnvironment(
      'opaque-capability',
      parentEnvironment: const <String, String>{
        'TRAIN_C_TEST_SENTINEL_SECRET': 'must-not-propagate',
        'TEMP': 'safe-bootstrap',
      },
    );

    expect(environment.keys, contains('TRAIN_C_REATTACH_CAPABILITY'));
    expect(environment.keys, isNot(contains('TRAIN_C_TEST_SENTINEL_SECRET')));
    expect(environment.length, Platform.isWindows ? 2 : 1);
  });

  test('restart child with valid-looking wrong state fails closed', () async {
    final expected = _durableCheckpoint('a');
    final wrong = _durableCheckpoint('b');

    await expectLater(
      runTrainCRestartProcess(
        start: () async => _completedProcess(
          stdout: jsonEncode(
            trainCRestartProtocolMap(childPid: pid + 1, checkpoint: wrong),
          ),
        ),
        timeout: const Duration(seconds: 1),
        parentPid: pid,
        expectedCheckpoint: expected,
      ),
      _restartFailure(trainCRestartStateMismatch),
    );
  });

  test('malformed restart protocol has a fixed safe failure', () async {
    await expectLater(
      runTrainCRestartProcess(
        start: () async => _completedProcess(stdout: '{"status":"PASS"'),
        timeout: const Duration(seconds: 1),
        parentPid: pid,
        expectedCheckpoint: _durableCheckpoint('a'),
      ),
      _restartFailure(trainCRestartProtocolFailure),
    );
  });

  test('non-zero restart child has a fixed safe failure', () async {
    await expectLater(
      runTrainCRestartProcess(
        start: () async => _completedProcess(exitCode: 7),
        timeout: const Duration(seconds: 1),
        parentPid: pid,
        expectedCheckpoint: expected,
      ),
      _restartFailure(trainCRestartChildFailure),
    );
  });

  test('restart process start failure has a fixed safe failure', () async {
    await expectLater(
      runTrainCRestartProcess(
        start: () => Future<TrainCRestartStartedProcess>.error(
          StateError('not surfaced'),
        ),
        timeout: const Duration(seconds: 1),
        parentPid: pid,
        expectedCheckpoint: _durableCheckpoint('a'),
      ),
      _restartFailure(trainCRestartProcessStartFailure),
    );
  });

  test('restart process timeout is bounded and safely categorized', () async {
    final exitCode = Completer<int>();
    var killed = false;
    await expectLater(
      runTrainCRestartProcess(
        start: () async => (
          stdout: const Stream<List<int>>.empty(),
          stderr: const Stream<List<int>>.empty(),
          exitCode: exitCode.future,
          kill: () {
            killed = true;
            return true;
          },
        ),
        timeout: const Duration(milliseconds: 20),
        parentPid: pid,
        expectedCheckpoint: _durableCheckpoint('a'),
      ),
      _restartFailure(trainCRestartTimeout),
    );
    expect(killed, isTrue);
  });
}

TrainCDurableRestartCheckpoint _durableCheckpoint(String digestCharacter) {
  return TrainCDurableRestartCheckpoint(
    questionRows: 22,
    v2Sidecars: 22,
    managedFileCount: 3,
    durableDigest: List<String>.filled(64, digestCharacter).join(),
  );
}

TrainCRestartStartedProcess _completedProcess({
  int exitCode = 0,
  String stdout = '',
}) {
  return (
    stdout: Stream<List<int>>.value(utf8.encode(stdout)),
    stderr: const Stream<List<int>>.empty(),
    exitCode: Future<int>.value(exitCode),
    kill: () => true,
  );
}

Matcher _restartFailure(String code) {
  return throwsA(
    isA<TrainCRestartException>().having(
      (error) => error.code,
      'code',
      code,
    ),
  );
}
