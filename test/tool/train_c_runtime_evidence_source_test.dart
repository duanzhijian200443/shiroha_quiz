import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';
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

String get _tinyPngDigest => sha256Hex(_tinyPng());

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

final class _FailureGate implements TrainCExecutionStateGate {
  const _FailureGate({this.code, this.unexpected = false});

  final String? code;
  final bool unexpected;

  @override
  void verify() {
    if (unexpected) throw StateError('not surfaced');
    throw TrainCEvidenceProbeException(code!);
  }
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
    candidateCheckpoint: TrainCCandidateCheckpoint.empty(),
    requestLedger: TrainCRequestLedger(),
    commitCheckpoint: empty,
    restartCheckpoint: empty,
    b0: TrainCB0PhaseFacts(
      packagePath: '',
      preB0Checkpoint: empty,
      restoreCheckpoint: empty,
    ),
  );
}

Future<TrainCRuntimeCheckpoint> _capture(TrainCIsolatedRuntime runtime) {
  return TrainCRuntimeEvidenceSource(
    runtime: runtime,
    phaseFacts: _placeholderFacts(),
    reviewedIdentity: _reviewedForCurrentHead(),
  ).captureCheckpoint();
}

QuestionDraftV2 _draft(
  int number, {
  bool includeNonMandatoryImages = false,
  bool dualImageQuestion5 = false,
}) {
  final sourceId = 'synthetic_source';
  final imageAsset = switch (number) {
    1 when includeNonMandatoryImages => 'asset_q1',
    2 when includeNonMandatoryImages => 'asset_q2',
    5 when !dualImageQuestion5 => 'asset_q5',
    18 => 'asset_q18',
    19 => 'asset_q19',
    _ => null,
  };
  final image = imageAsset == null
      ? null
      : ImageNode(sourceId: sourceId, localAssetId: imageAsset);
  final stem = number == 5 && dualImageQuestion5
      ? RichContent(
          nodes: <ContentNode>[
            ImageNode(
              sourceId: 'synthetic_source',
              localAssetId: 'asset_q5_a',
            ),
            ImageNode(
              sourceId: 'synthetic_source',
              localAssetId: 'asset_q5_b',
            ),
          ],
        )
      : number == 5
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
                                content:
                                    RichContent(nodes: <ContentNode>[image!]),
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
              : RichContent(
                  nodes: <ContentNode>[TextNode('question $number')],
                );
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
    assetRefs: number == 5 && dualImageQuestion5
        ? <SourcedAssetRef>[
            SourcedAssetRef(
              sourceId: sourceId,
              asset: AssetRef(
                assetId: 'asset_q5_a',
                kind: AssetKind.image,
              ),
            ),
            SourcedAssetRef(
              sourceId: sourceId,
              asset: AssetRef(
                assetId: 'asset_q5_b',
                kind: AssetKind.image,
              ),
            ),
          ]
        : imageAsset == null
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

TrainCCandidateCheckpoint _candidateForSynthetic({
  bool includeNonMandatoryImages = false,
  bool dualImageQuestion5 = false,
}) {
  return TrainCCandidateCheckpoint.fromDrafts(
    List<QuestionDraftV2>.generate(
      22,
      (index) => _draft(
        index + 1,
        includeNonMandatoryImages: includeNonMandatoryImages,
        dualImageQuestion5: dualImageQuestion5,
      ),
    ),
  );
}

Future<void> _seedTwentyTwo(
  TrainCIsolatedRuntime runtime, {
  bool includeNonMandatoryImages = false,
  bool dualImageQuestion5 = false,
}) async {
  final store = runtime.contentAssetStore;
  final assetIds = <String>[
    if (includeNonMandatoryImages) 'asset_q1',
    if (includeNonMandatoryImages) 'asset_q2',
    if (dualImageQuestion5) ...<String>['asset_q5_a', 'asset_q5_b'] else
      'asset_q5',
    'asset_q18',
    'asset_q19',
  ];
  for (final assetId in assetIds) {
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
      draft: _draft(
        number,
        includeNonMandatoryImages: includeNonMandatoryImages,
        dualImageQuestion5: dualImageQuestion5,
      ),
    );
    await db.insert('questions', frozen.questionRow);
    await db.insert('question_v2_payloads', frozen.payloadRow);
  }
}

TrainCPreTypedSourceImageEvidence _sourceEvidence({
  required int questionNumber,
  required String localAssetId,
  required int readingOrder,
  String? blockId,
  String? contentHash,
}) {
  return TrainCPreTypedSourceImageEvidence(
    questionNumber: questionNumber,
    sourceId: 'synthetic_source',
    blockId: blockId ?? 'block_${questionNumber}_$readingOrder',
    localAssetId: localAssetId,
    contentHash: contentHash ?? _tinyPngDigest,
    readingOrder: readingOrder,
  );
}

TrainCSourceImageFacts _sourceFacts(
  List<TrainCPreTypedSourceImageEvidence> evidence,
) {
  final counts = <int, int>{};
  final identities = <int, Set<(String, String)>>{};
  for (final item in evidence) {
    counts[item.questionNumber] = (counts[item.questionNumber] ?? 0) + 1;
    identities
        .putIfAbsent(item.questionNumber, () => <(String, String)>{})
        .add(item.identity);
  }
  return TrainCSourceImageFacts(
    referencedImageCounts: counts,
    referencedIdentitiesByQuestion: identities,
    orderedEvidence: evidence,
  );
}

TrainCSourceImageFacts _defaultSourceFacts() {
  return _sourceFacts(<TrainCPreTypedSourceImageEvidence>[
    _sourceEvidence(
        questionNumber: 5, localAssetId: 'asset_q5', readingOrder: 0),
    _sourceEvidence(
      questionNumber: 18,
      localAssetId: 'asset_q18',
      readingOrder: 0,
    ),
    _sourceEvidence(
      questionNumber: 19,
      localAssetId: 'asset_q19',
      readingOrder: 0,
    ),
  ]);
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
  TrainCSourceImageFacts? sourceImages,
  TrainCCandidateCheckpoint? candidateCheckpoint,
  int imageBlockCount = 3,
  int referencedImageBlockCount = 3,
  int blockCount = 4,
}) {
  return TrainCRuntimePhaseFacts(
    input: const TrainCInputFacts(
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      sizeBytes: 123,
      pageCount: 20,
    ),
    parse: TrainCParseFacts(
      blockCount: blockCount,
      imageBlockCount: imageBlockCount,
      tableBlockCount: 1,
      referencedImageBlockCount: referencedImageBlockCount,
      referencedTableBlockCount: 1,
      assembledQuestionCount: 22,
      finalQuestionCount: 22,
      storageRoute: 'typedV2',
      storageReason: 'typed_candidate_ready',
      layoutChunkSize: 20,
      sourceImages: sourceImages ?? _defaultSourceFacts(),
    ),
    candidateCheckpoint: candidateCheckpoint ?? _candidateForSynthetic(),
    requestLedger: ledger,
    commitCheckpoint: commit,
    restartCheckpoint: restart,
    b0: TrainCB0PhaseFacts(
      packagePath: packagePath,
      preB0Checkpoint: restart,
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

    runtime = await runtime.reopenFresh();
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

    final reviewed = _reviewedForCurrentHead();
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
      reviewedIdentity: reviewed,
    );
    final snapshot = await source.readAuthoritativeSnapshot();
    expect(snapshot['imageSummary'], isA<Map<String, dynamic>>());
    final result = await TrainCTrustedEvidenceCollector(
      reviewedIdentity: reviewed,
      executionStateGate: const _CleanGate(),
    ).collect(source);
    expect(result.schemaValid, isTrue);
    expect(result.acceptanceAuthorized, isTrue);
    expect(result.evidence['result'], 'PASS');

    final wrongReviewedIdentity = TrainCReviewedIdentity(
      approvedHarnessHead: '0' * 40,
      approvedBase: reviewed.approvedBase,
      approvedProductionBase: reviewed.approvedProductionBase,
    );
    final wrongReviewResult = await TrainCTrustedEvidenceCollector(
      reviewedIdentity: wrongReviewedIdentity,
      executionStateGate: const _CleanGate(),
    ).collect(source);
    expect(wrongReviewResult.acceptanceAuthorized, isFalse);
    expect(
      wrongReviewResult.evidence['failureCode'],
      'TRAIN_C_CODE_IDENTITY_MISMATCH',
    );

    final dirtyResult = await TrainCTrustedEvidenceCollector(
      reviewedIdentity: reviewed,
      executionStateGate: const _FailureGate(
        code: 'TRAIN_C_DIRTY_WORKTREE',
      ),
    ).collect(source);
    expect(dirtyResult.acceptanceAuthorized, isFalse);
    expect(dirtyResult.evidence['failureCode'], 'TRAIN_C_DIRTY_WORKTREE');

    final unreadableResult = await TrainCTrustedEvidenceCollector(
      reviewedIdentity: reviewed,
      executionStateGate: const _FailureGate(unexpected: true),
    ).collect(source);
    expect(unreadableResult.acceptanceAuthorized, isFalse);
    expect(
      unreadableResult.evidence['failureCode'],
      'TRAIN_C_CODE_IDENTITY_MISMATCH',
    );
  });

  test('source ownership mismatch fails when global image counts still match',
      () async {
    await _seedTwentyTwo(runtime);
    final commit = await _capture(runtime);
    runtime = await runtime.reopenFresh();
    final restart = await _capture(runtime);
    final packagePath =
        p.join(runtime.exportDirectory.path, 'ownership.shiroha');
    final b0 = runtime.buildBackupRuntime();
    await b0.exportTo(packagePath);
    final sourceImages = _sourceFacts(<TrainCPreTypedSourceImageEvidence>[
      _sourceEvidence(
        questionNumber: 5,
        localAssetId: 'asset_q18',
        readingOrder: 0,
      ),
      _sourceEvidence(
        questionNumber: 18,
        localAssetId: 'asset_q5',
        readingOrder: 0,
      ),
      _sourceEvidence(
        questionNumber: 19,
        localAssetId: 'asset_q19',
        readingOrder: 0,
      ),
    ]);
    final reviewed = _reviewedForCurrentHead();
    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _finalFacts(
        commit: commit,
        restart: restart,
        restore: restart,
        packagePath: packagePath,
        ledger: await _syntheticLedger(),
        sourceImages: sourceImages,
      ),
      reviewedIdentity: reviewed,
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

  test('source identity mismatch on a non-mandatory question fails closed',
      () async {
    await _seedTwentyTwo(runtime, includeNonMandatoryImages: true);
    final commit = await _capture(runtime);
    runtime = await runtime.reopenFresh();
    final restart = await _capture(runtime);
    final packagePath =
        p.join(runtime.exportDirectory.path, 'non_mandatory_ownership.shiroha');
    final b0 = runtime.buildBackupRuntime();
    await b0.exportTo(packagePath);
    final sourceImages = _sourceFacts(<TrainCPreTypedSourceImageEvidence>[
      _sourceEvidence(
        questionNumber: 1,
        localAssetId: 'asset_q2',
        readingOrder: 0,
      ),
      _sourceEvidence(
        questionNumber: 2,
        localAssetId: 'asset_q1',
        readingOrder: 0,
      ),
      _sourceEvidence(
        questionNumber: 5,
        localAssetId: 'asset_q5',
        readingOrder: 0,
      ),
      _sourceEvidence(
        questionNumber: 18,
        localAssetId: 'asset_q18',
        readingOrder: 0,
      ),
      _sourceEvidence(
        questionNumber: 19,
        localAssetId: 'asset_q19',
        readingOrder: 0,
      ),
    ]);
    final reviewed = _reviewedForCurrentHead();
    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _finalFacts(
        commit: commit,
        restart: restart,
        restore: restart,
        packagePath: packagePath,
        ledger: await _syntheticLedger(),
        sourceImages: sourceImages,
        candidateCheckpoint:
            _candidateForSynthetic(includeNonMandatoryImages: true),
        blockCount: 6,
        imageBlockCount: 5,
        referencedImageBlockCount: 5,
      ),
      reviewedIdentity: reviewed,
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

  test('source reading order mismatch fails when identity set still matches',
      () async {
    await _seedTwentyTwo(runtime, dualImageQuestion5: true);
    final commit = await _capture(runtime);
    expect(
      commit.question(5)?.orderedImageIdentities,
      <(String, String)>[
        ('synthetic_source', 'asset_q5_a'),
        ('synthetic_source', 'asset_q5_b'),
      ],
    );
    runtime = await runtime.reopenFresh();
    final restart = await _capture(runtime);
    final packagePath = p.join(runtime.exportDirectory.path, 'order.shiroha');
    final b0 = runtime.buildBackupRuntime();
    await b0.exportTo(packagePath);
    final sourceImages = _sourceFacts(<TrainCPreTypedSourceImageEvidence>[
      _sourceEvidence(
        questionNumber: 5,
        localAssetId: 'asset_q5_b',
        readingOrder: 0,
        blockId: 'block_q5_b',
      ),
      _sourceEvidence(
        questionNumber: 5,
        localAssetId: 'asset_q5_a',
        readingOrder: 1,
        blockId: 'block_q5_a',
      ),
      _sourceEvidence(
        questionNumber: 18,
        localAssetId: 'asset_q18',
        readingOrder: 0,
      ),
      _sourceEvidence(
        questionNumber: 19,
        localAssetId: 'asset_q19',
        readingOrder: 0,
      ),
    ]);
    final reviewed = _reviewedForCurrentHead();
    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _finalFacts(
        commit: commit,
        restart: restart,
        restore: restart,
        packagePath: packagePath,
        ledger: await _syntheticLedger(),
        sourceImages: sourceImages,
        candidateCheckpoint: _candidateForSynthetic(dualImageQuestion5: true),
        blockCount: 5,
        imageBlockCount: 4,
        referencedImageBlockCount: 4,
      ),
      reviewedIdentity: reviewed,
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

  test('source content hash mismatch fails before B0 can mask it', () async {
    await _seedTwentyTwo(runtime);
    final commit = await _capture(runtime);
    runtime = await runtime.reopenFresh();
    final restart = await _capture(runtime);
    final packagePath = p.join(runtime.exportDirectory.path, 'hash.shiroha');
    final b0 = runtime.buildBackupRuntime();
    await b0.exportTo(packagePath);
    final sourceImages = _sourceFacts(<TrainCPreTypedSourceImageEvidence>[
      _sourceEvidence(
        questionNumber: 5,
        localAssetId: 'asset_q5',
        readingOrder: 0,
        contentHash:
            '0000000000000000000000000000000000000000000000000000000000000000',
      ),
      _sourceEvidence(
        questionNumber: 18,
        localAssetId: 'asset_q18',
        readingOrder: 0,
      ),
      _sourceEvidence(
        questionNumber: 19,
        localAssetId: 'asset_q19',
        readingOrder: 0,
      ),
    ]);
    final reviewed = _reviewedForCurrentHead();
    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _finalFacts(
        commit: commit,
        restart: restart,
        restore: restart,
        packagePath: packagePath,
        ledger: await _syntheticLedger(),
        sourceImages: sourceImages,
      ),
      reviewedIdentity: reviewed,
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

  test('candidate checkpoint is independent of the final database', () async {
    await _seedTwentyTwo(runtime);
    final candidate = _candidateForSynthetic();
    final db = await runtime.database;
    final rows = await db.query(
      'question_v2_payloads',
      columns: <String>['payload_json'],
      where: 'question_id = ?',
      whereArgs: <Object?>[
        'a3f9c2e4-5b6d-4e7f-8a9b-000000000001',
      ],
    );
    final payload = rows.single['payload_json'];
    if (payload is! String) fail('missing synthetic payload');
    await db.update(
      'question_v2_payloads',
      <String, Object?>{
        'payload_json':
            payload.replaceFirst('question 1', 'changed question 1'),
      },
      where: 'question_id = ?',
      whereArgs: <Object?>[
        'a3f9c2e4-5b6d-4e7f-8a9b-000000000001',
      ],
    );
    final commit = await _capture(runtime);
    runtime = await runtime.reopenFresh();
    final restart = await _capture(runtime);
    final packagePath =
        p.join(runtime.exportDirectory.path, 'candidate.shiroha');
    final b0 = runtime.buildBackupRuntime();
    await b0.exportTo(packagePath);
    final reviewed = _reviewedForCurrentHead();
    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _finalFacts(
        commit: commit,
        restart: restart,
        restore: restart,
        packagePath: packagePath,
        ledger: await _syntheticLedger(),
        candidateCheckpoint: candidate,
      ),
      reviewedIdentity: reviewed,
    );

    await expectLater(
      source.readAuthoritativeSnapshot(),
      throwsA(
        predicate<TrainCRuntimeEvidenceException>(
          (error) => error.code == 'TRAIN_C_COMMIT_FAILURE',
        ),
      ),
    );
  });

  test('default render source cannot claim final acceptance', () async {
    await _seedTwentyTwo(runtime);
    final commit = await _capture(runtime);
    final ledger = await _syntheticLedger();
    runtime = await runtime.reopenFresh();
    final restart = await _capture(runtime);
    final packagePath = p.join(runtime.exportDirectory.path, 'render.shiroha');
    final b0 = runtime.buildBackupRuntime();
    await b0.exportTo(packagePath);
    final restore = await _capture(runtime);
    final reviewed = _reviewedForCurrentHead();
    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _finalFacts(
        commit: commit,
        restart: restart,
        restore: restore,
        packagePath: packagePath,
        ledger: ledger,
      ),
      reviewedIdentity: reviewed,
    );
    final result = TrainCEvidenceProbe(
      expectedIdentity: reviewed.toExpectedCodeIdentity(),
    ).inspect(
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
      reviewedIdentity: _reviewedForCurrentHead(),
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
      reviewedIdentity: _reviewedForCurrentHead(),
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
      reviewedIdentity: _reviewedForCurrentHead(),
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

  test('B0 restore compares exact identity and digest with restart baseline',
      () async {
    await _seedTwentyTwo(runtime);
    final commit = await _capture(runtime);
    final packagePath = p.join(runtime.exportDirectory.path, 'b0.shiroha');
    final b0 = runtime.buildBackupRuntime();
    await b0.exportTo(packagePath);
    final ledger = await _syntheticLedger();
    runtime = await runtime.reopenFresh();
    final restart = await _capture(runtime);
    final altered = TrainCRuntimeCheckpoint(
      questionRows: commit.questionRows,
      v2Sidecars: commit.v2Sidecars,
      typedCount: commit.typedCount,
      validEnvelopeCount: commit.validEnvelopeCount,
      questionNumbers: commit.questionNumbers,
      typedImageNodeCount: commit.typedImageNodeCount,
      typedUniqueAssetCount: commit.typedUniqueAssetCount,
      resolvedUniqueAssetCount: commit.resolvedUniqueAssetCount,
      allReachableResolved: commit.allReachableResolved,
      canonicalIdentityPreserved: commit.canonicalIdentityPreserved,
      typedTableNodeCount: commit.typedTableNodeCount,
      payloadDigest: commit.payloadDigest,
      reachableIdentities: commit.reachableIdentities,
      assetSizes: commit.assetSizes,
      assetDigests: <(String, String), String>{
        ...commit.assetDigests,
        ('synthetic_source', 'asset_q5'): List.filled(64, '0').join(),
      },
      questions: commit.questions,
    );
    final reviewed = _reviewedForCurrentHead();
    final source = TrainCRuntimeEvidenceSource(
      runtime: runtime,
      phaseFacts: _finalFacts(
        commit: commit,
        restart: restart,
        restore: altered,
        packagePath: packagePath,
        ledger: ledger,
      ),
      renderEvidence: const _AllRenderEvidence(),
      reviewedIdentity: reviewed,
    );
    await expectLater(
      source.readAuthoritativeSnapshot(),
      throwsA(
        predicate<TrainCRuntimeEvidenceException>(
          (error) => error.code == 'TRAIN_C_B0_IDENTITY_MISMATCH',
        ),
      ),
    );
  });
}

TrainCReviewedIdentity _reviewedForCurrentHead() {
  final headResult = Process.runSync('git', <String>['rev-parse', 'HEAD']);
  final baseResult =
      Process.runSync('git', <String>['rev-parse', 'origin/master']);
  final head = (headResult.stdout as String).trim();
  final base = (baseResult.stdout as String).trim();
  return TrainCReviewedIdentity(
    approvedHarnessHead: head,
    approvedBase:
        base.isNotEmpty ? base : '03e8fc6d0d65ef906e4cd306d37c166a0e55cd35',
    approvedProductionBase: '711fd33f564b9fb6bb3c992d6458b0075990646c',
    approvedProductionSeamBlobSha:
        TrainCL1BProductionDiffAuthority.readProductionSeamBlobSha(head),
  );
}
