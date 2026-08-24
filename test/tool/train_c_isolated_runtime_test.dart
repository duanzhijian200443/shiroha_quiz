import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../tool/train_c_isolated_runtime.dart';

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
    sourceRefs: <SourceRef>[
      SourceRef.document(sourceId: 'synthetic_source'),
    ],
  );
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

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
    expect(
      p.isWithin(runtime.dbDirectory.path, openedPath),
      isTrue,
    );
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
}
