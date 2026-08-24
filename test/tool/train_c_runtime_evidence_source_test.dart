import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../tool/train_c_evidence_collector.dart';
import '../../tool/train_c_evidence_probe.dart';
import '../../tool/train_c_http_observer.dart';
import '../../tool/train_c_isolated_runtime.dart';
import '../../tool/train_c_runtime_evidence_source.dart';

const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=';

List<int> _tinyPng() => base64Decode(_tinyPngBase64);

final class _AllRenderEvidence implements TrainCRenderEvidencePort {
  const _AllRenderEvidence();

  @override
  bool didRender({
    required int questionNumber,
    required TrainCRenderStage stage,
  }) =>
      true;
}

final class _CleanGate implements TrainCExecutionStateGate {
  const _CleanGate();

  @override
  void verify() {}
}

TrainCRuntimePhaseFacts _placeholderFacts() {
  final empty = TrainCRuntimeCheckpoint.empty();
  return TrainCRuntimePhaseFacts(
    input: const TrainCInputFacts(
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      sizeBytes: 1,
      pageCount: 20,
    ),
    parse: const TrainCParseFacts(
      blockCount: 0,
      imageBlockCount: 0,
      tableBlockCount: 0,
      referencedImageBlockCount: 0,
      referencedTableBlockCount: 0,
      assembledQuestionCount: 0,
      finalQuestionCount: 0,
      storageRoute: 'legacyV1',
      storageReason: 'placeholder',
    ),
    requestLedger: TrainCRequestLedger(),
    commitCheckpoint: empty,
    restartCheckpoint: empty,
    b0: TrainCB0PhaseFacts(
      packagePath: '',
      restoreCheckpoint: empty,
    ),
  );
}

Future<TrainCRuntimeCheckpoint> _capture(TrainCIsolatedRuntime runtime) {
  return TrainCRuntimeEvidenceSource(
    runtime: runtime,
    phaseFacts: _placeholderFacts(),
  ).captureCheckpoint();
}

QuestionDraftV2 _draft(int number) {
  final sourceId = 'synthetic_source';
  final imageAsset = switch (number) {
    5 => 'asset_q5',
    18 => 'asset_q18',
    19 => 'asset_q19',
    _ => null,
  };
  final image = imageAsset == null
      ? null
      : ImageNode(sourceId: sourceId, localAssetId: imageAsset);
  final stem = number == 5
      ? RichContent(nodes: <ContentNode>[image!])
      : number == 19
          ? RichContent(
              nodes: <ContentNode>[
                TableNode(
                  structure: TableStructure(
                    rows: <TableRow>[
                      TableRow(
                        cells: <TableCell>[
                          TableCell(
                            content: RichContent(nodes: <ContentNode>[image!]),
                            rowSpan: 1,
                            columnSpan: 1,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            )
          : RichContent(nodes: <ContentNode>[TextNode('question $number')]);
  final explanation =
      number == 18 ? RichContent(nodes: <ContentNode>[image!]) : null;
  return QuestionDraftV2(
    questionId: 'question_$number',
    questionNumber: number,
    kind: QuestionKind.shortAnswer,
    stem: stem,
    explanation: explanation,
    sourceRefs: <SourceRef>[
      SourceRef.document(sourceId: sourceId),
    ],
    assetRefs: imageAsset == null
        ? const <SourcedAssetRef>[]
        : <SourcedAssetRef>[
            SourcedAssetRef(
              sourceId: sourceId,
              asset: AssetRef(
                assetId: imageAsset,
                kind: AssetKind.image,
              ),
            ),
          ],
  );
}

Future<void> _seedTwentyTwo(TrainCIsolatedRuntime runtime) async {
  final store = runtime.contentAssetStore;
  for (final assetId in const <String>['asset_q5', 'asset_q18', 'asset_q19']) {
    store.storeBytesSync(
      sourceId: 'synthetic_source',
      localAssetId: assetId,
      bytes: _tinyPng(),
      mimeType: 'image/png',
    );
  }
  final db = await runtime.database;
  final mapper = QuestionV2PersistenceMapper(contentAssetAuthority: store);
  for (var number = 1; number <= 22; number++) {
    final frozen = mapper.freezeForWrite(
      storageId:
          'a3f9c2e4-5b6d-4e7f-8a9b-${number.toString().padLeft(12, '0')}',
      bankName: 'synthetic',
      createdAt: number,
      draft: _draft(number),
    );
    await db.insert('questions', frozen.questionRow);
    await db.insert('question_v2_payloads', frozen.payloadRow);
  }
}

Future<TrainCRequestLedger> _syntheticLedger() async {
  final ledger = TrainCRequestLedger();
  ledger.beginParse(expectedLayoutRequests: 1);
  final layout = ledger.recordDispatch(TrainCRequestKind.layoutPost);
  ledger.recordResponse(eventIndex: layout, statusCode: 200, durationMs: 1);
  for (var index = 0; index < 3; index++) {
    final crop = ledger.recordDispatch(TrainCRequestKind.remoteCropGet);
    ledger.recordResponse(eventIndex: crop, statusCode: 200, durationMs: 1);
  }
  ledger.finishParse(successful: true);
  return ledger;
}

TrainCRuntimePhaseFacts _finalFacts({
  required TrainCRuntimeCheckpoint commit,
  required TrainCRuntimeCheckpoint restart,
  required TrainCRuntimeCheckpoint restore,
  required String packagePath,
  required TrainCRequestLedger ledger,
}) {
  return TrainCRuntimePhaseFacts(
    input: const TrainCInputFacts(
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      sizeBytes: 123,
      pageCount: 20,
    ),
    parse: const TrainCParseFacts(
      blockCount: 4,
      imageBlockCount: 3,
      tableBlockCount: 1,
      referencedImageBlockCount: 3,
      referencedTableBlockCount: 1,
      assembledQuestionCount: 22,
      finalQuestionCount: 22,
      storageRoute: 'typedV2',
      storageReason: 'typed_candidate_ready',
      layoutChunkSize: 20,
    ),
    requestLedger: ledger,
    commitCheckpoint: commit,
    restartCheckpoint: restart,
    b0: TrainCB0PhaseFacts(
      packagePath: packagePath,
      restoreCheckpoint: restore,
    ),
  );
}

Future<void> _expectDecodable(List<int> bytes) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  try {
    await codec.getNextFrame();
  } finally {
    codec.dispose();
  }
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

  test('concrete source derives typed closure, restart and B0 facts', () async {
    final blank = await runtime.verifyBlankStore();
    expect(blank.passed, isTrue);
    await _seedTwentyTwo(runtime);
    final commit = await _capture(runtime);
    expect(commit.questionRows, 22);
    expect(commit.v2Sidecars, 22);
    expect(commit.typedImageNodeCount, 3);
    expect(commit.typedUniqueAssetCount, 3);
    expect(commit.resolvedUniqueAssetCount, 3);
    expect(commit.typedTableNodeCount, 1);
    expect(commit.question(5)?.imageNodeCount, 1);
    expect(commit.question(18)?.imageNodeCount, 1);
    expect(commit.question(19)?.imageNodeCount, 1);

    await runtime.closeForRestart();
    await runtime.reopen();
    final restart = await _capture(runtime);
    expect(restart.equivalentTo(commit), isTrue);
    await _expectDecodable(
      runtime.contentAssetStore.readAssetBytes(
        sourceId: 'synthetic_source',
        localAssetId: 'asset_q19',
      )!,
    );

    final packagePath = p.join(
      runtime.exportDirectory.path,
      'synthetic.shiroha',
    );
    final b0 = runtime.buildBackupRuntime();
    await b0.exportTo(packagePath);
    final manifest = await BackupArchiveIo.readManifestOnly(packagePath);
    expect(manifest.packageVersion, BackupValues.currentPackageVersion);
    expect(manifest.contentAssets, hasLength(3));
    await runtime.contentAssetStore.deleteCandidateAssets(
      ContentAssetCandidateLease(
        sourceId: 'synthetic_source',
        localAssetIds: const <String>['asset_q5', 'asset_q18', 'asset_q19'],
      ),
    );
    expect(await runtime.contentAssetStore.listAssets(), isEmpty);
    await b0.prepareRestore(packagePath);
    await b0.commitPreparedRestore();
    final restore = await _capture(runtime);
    expect(restore.equivalentTo(commit), isTrue);
    expect(await runtime.contentAssetStore.listAssets(), hasLength(3));
    for (final assetId in const <String>[
      'asset_q5',
      'asset_q18',
      'asset_q19',
    ]) {
      await _expectDecodable(
        runtime.contentAssetStore.readAssetBytes(
          sourceId: 'synthetic_source',
          localAssetId: assetId,
        )!,
      );
    }

    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _finalFacts(
        commit: commit,
        restart: restart,
        restore: restore,
        packagePath: packagePath,
        ledger: await _syntheticLedger(),
      ),
      renderEvidence: const _AllRenderEvidence(),
    );
    final snapshot = await source.readAuthoritativeSnapshot();
    expect(snapshot['imageSummary'], isA<Map<String, dynamic>>());
    final result = await TrainCTrustedEvidenceCollector(
      TrainCEvidenceProbe.forCurrentRepository(),
      executionStateGate: const _CleanGate(),
    ).collect(source);
    expect(result.schemaValid, isTrue);
    expect(result.acceptanceAuthorized, isTrue);
    expect(result.evidence['result'], 'PASS');
  });

  test('default render source cannot claim final acceptance', () async {
    await _seedTwentyTwo(runtime);
    final commit = await _capture(runtime);
    final ledger = await _syntheticLedger();
    await runtime.closeForRestart();
    await runtime.reopen();
    final restart = await _capture(runtime);
    final packagePath = p.join(runtime.exportDirectory.path, 'render.shiroha');
    final b0 = runtime.buildBackupRuntime();
    await b0.exportTo(packagePath);
    final restore = await _capture(runtime);
    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _finalFacts(
        commit: commit,
        restart: restart,
        restore: restore,
        packagePath: packagePath,
        ledger: ledger,
      ),
    );
    final result = TrainCEvidenceProbe.forCurrentRepository().inspect(
      await source.readAuthoritativeSnapshot(),
    );
    expect(result.schemaValid, isFalse);
    expect(result.evidence['failureCode'], 'TRAIN_C_IMAGE_CLOSURE_FAILURE');
  });

  test('missing managed bytes fail closed', () async {
    await _seedTwentyTwo(runtime);
    await runtime.contentAssetStore.deleteCandidateAssets(
      ContentAssetCandidateLease(
        sourceId: 'synthetic_source',
        localAssetIds: const <String>['asset_q5'],
      ),
    );
    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _placeholderFacts(),
    );
    await expectLater(
      source.readAuthoritativeSnapshot(),
      throwsA(
        predicate<TrainCRuntimeEvidenceException>(
          (error) => error.code == 'TRAIN_C_IMAGE_CLOSURE_FAILURE',
        ),
      ),
    );
  });

  test('malformed sidecar fails closed through the codec', () async {
    await _seedTwentyTwo(runtime);
    final db = await runtime.database;
    await db.update(
      'question_v2_payloads',
      <String, Object?>{'payload_json': '{}'},
      where: 'question_id = ?',
      whereArgs: <Object?>[
        'a3f9c2e4-5b6d-4e7f-8a9b-000000000001',
      ],
    );
    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _placeholderFacts(),
    );
    await expectLater(
      source.captureCheckpoint(),
      throwsA(
        predicate<TrainCRuntimeEvidenceException>(
          (error) => error.code == 'TRAIN_C_RUNTIME_EVIDENCE_FAILURE',
        ),
      ),
    );
  });

  test('missing question number fails closed by questionNumber authority',
      () async {
    await _seedTwentyTwo(runtime);
    final db = await runtime.database;
    await db.delete(
      'questions',
      where: 'id = ?',
      whereArgs: <Object?>['a3f9c2e4-5b6d-4e7f-8a9b-000000000022'],
    );
    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _placeholderFacts(),
    );
    await expectLater(
      source.readAuthoritativeSnapshot(),
      throwsA(
        predicate<TrainCRuntimeEvidenceException>(
          (error) => error.code == 'TRAIN_C_NUMBERING_FAILURE',
        ),
      ),
    );
  });

  test('B0 manifest count mismatch is reported by the probe', () async {
    await _seedTwentyTwo(runtime);
    final commit = await _capture(runtime);
    final packagePath = p.join(runtime.exportDirectory.path, 'b0.shiroha');
    final b0 = runtime.buildBackupRuntime();
    await b0.exportTo(packagePath);
    final ledger = await _syntheticLedger();
    final altered = TrainCRuntimeCheckpoint(
      questionRows: commit.questionRows,
      v2Sidecars: commit.v2Sidecars,
      typedCount: commit.typedCount,
      validEnvelopeCount: commit.validEnvelopeCount,
      questionNumbers: commit.questionNumbers,
      typedImageNodeCount: commit.typedImageNodeCount,
      typedUniqueAssetCount: commit.typedUniqueAssetCount,
      resolvedUniqueAssetCount: commit.resolvedUniqueAssetCount,
      allReachableResolved: true,
      canonicalIdentityPreserved: true,
      typedTableNodeCount: commit.typedTableNodeCount,
      payloadDigest: commit.payloadDigest,
      reachableIdentities: <(String, String)>{
        ...commit.reachableIdentities,
      }..remove(('synthetic_source', 'asset_q19')),
      questions: commit.questions,
    );
    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _finalFacts(
        commit: commit,
        restart: commit,
        restore: altered,
        packagePath: packagePath,
        ledger: ledger,
      ),
      renderEvidence: const _AllRenderEvidence(),
    );
    final result = TrainCEvidenceProbe.forCurrentRepository().inspect(
      await source.readAuthoritativeSnapshot(),
    );
    expect(result.schemaValid, isFalse);
    expect(result.evidence['failureCode'], 'TRAIN_C_B0_ASSET_SET_FAILURE');
  });
}
