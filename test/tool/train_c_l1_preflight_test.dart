import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';

import '../../tool/train_c_evidence_collector.dart';
import '../../tool/train_c_evidence_probe.dart';
import '../../tool/train_c_l1_preflight.dart';
import '../../tool/train_c_l1b_review_authorization.dart';
import '../../tool/train_c_l1b_source_observer.dart';
import '../../tool/train_c_review_authorization.dart';
import '../../tool/train_c_runtime_evidence_source.dart';

final class _NoopGate implements TrainCExecutionStateGate {
  const _NoopGate();

  @override
  void verify() {}
}

final class _FailureGate implements TrainCExecutionStateGate {
  const _FailureGate(this.code);

  final String code;

  @override
  void verify() {
    throw TrainCEvidenceProbeException(code);
  }
}

final class _FixedRegionizer extends OcrQuestionRegionizer {
  const _FixedRegionizer(this.result);

  final OcrQuestionRegionizerResult result;

  @override
  OcrQuestionRegionizerResult regionize(OcrDocument document) => result;
}

final class _FixedOcrClient implements OcrDocumentClient {
  const _FixedOcrClient(this.document);

  final OcrDocument document;

  @override
  String get modelId => 'fixed';

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async =>
      document;
}

void main() {
  test('offline mechanical identity follows the current checkout only', () {
    final identity = TrainCReviewedIdentity.forOfflineCurrentRepository();

    expect(identity.approvedHarnessHead, hasLength(40));
    expect(identity.approvedHarnessHead, matches(RegExp(r'^[0-9a-f]{40}$')));
    expect(identity.approvedBase, trainCL1BaseMaster);
    expect(identity.approvedProductionBase, trainCL1TrainBMerge);
  });

  test('clean pre-execution state passes before runtime creation', () {
    final reviewed = _reviewedForTest();
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: _NoopGate(),
      reviewedIdentity: reviewed,
      currentHeadReader: () => reviewed.approvedHarnessHead,
      fetchMaster: () {},
      masterReader: () => trainCL1BaseMaster,
      productionDiffReader: () => 0,
    );

    expect(gate.verify, returnsNormally);
  });

  for (final dirtyState in const <String>[
    'tracked',
    'staged',
    'untracked',
  ]) {
    test('$dirtyState dirty worktree is blocked', () {
      final reviewed = _reviewedForTest();
      final gate = TrainCPreExecutionGitGate(
        executionStateGate: _FailureGate('TRAIN_C_DIRTY_WORKTREE'),
        reviewedIdentity: reviewed,
        currentHeadReader: () => reviewed.approvedHarnessHead,
        fetchMaster: () {},
        masterReader: () => trainCL1BaseMaster,
        productionDiffReader: () => 0,
      );

      expect(
        gate.verify,
        throwsA(
          predicate<TrainCEvidenceProbeException>(
            (error) => error.code == 'TRAIN_C_DIRTY_WORKTREE',
          ),
        ),
      );
    });
  }

  test('unreadable Git state is blocked with safe identity code', () {
    final reviewed = _reviewedForTest();
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: _FailureGate('TRAIN_C_CODE_IDENTITY_MISMATCH'),
      reviewedIdentity: reviewed,
      currentHeadReader: () => reviewed.approvedHarnessHead,
      fetchMaster: () {},
      masterReader: () => trainCL1BaseMaster,
      productionDiffReader: () => 0,
    );

    expect(
      gate.verify,
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_CODE_IDENTITY_MISMATCH',
        ),
      ),
    );
  });

  test('production lib diff is blocked before any runtime boundary', () {
    final reviewed = _reviewedForTest();
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: const _NoopGate(),
      reviewedIdentity: reviewed,
      currentHeadReader: () => reviewed.approvedHarnessHead,
      fetchMaster: () {},
      masterReader: () => trainCL1BaseMaster,
      productionDiffReader: () => 1,
    );

    expect(
      gate.verify,
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_HEAD_DRIFT',
        ),
      ),
    );
  });

  test('L1B preflight accepts only the minimal observer production seam', () {
    expect(
      trainCL1BAllowedProductionPaths,
      contains(
        'lib/services/import_pipeline/import_pipeline_service.dart',
      ),
    );
    expect(
      trainCL1BAllowedProductionPaths,
      isNot(contains('lib/main.dart')),
    );
  });

  test('L1B production allowlist rejects unrelated production paths', () {
    const changed = <String>[
      'lib/services/import_pipeline/import_pipeline_service.dart',
      'lib/core/database/database_helper.dart',
    ];
    final unexpected = changed
        .where((path) => !trainCL1BAllowedProductionPaths.contains(path))
        .toList();
    expect(unexpected, <String>['lib/core/database/database_helper.dart']);
  });

  test('unexpected origin master is blocked', () {
    final reviewed = _reviewedForTest();
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: const _NoopGate(),
      reviewedIdentity: reviewed,
      currentHeadReader: () => reviewed.approvedHarnessHead,
      fetchMaster: () {},
      masterReader: () => '0000000000000000000000000000000000000000',
      productionDiffReader: () => 0,
    );

    expect(
      gate.verify,
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_HEAD_DRIFT',
        ),
      ),
    );
  });

  test('L1B review identity requires independent head and base', () {
    final reviewed = TrainCL1BReviewAuthorization.requireFromEnvironment(
      environment: const <String, String>{
        trainCApprovedHarnessHeadEnvironment:
            'b000000000000000000000000000000000000000',
        trainCL1BApprovedBaseEnvironment:
            'c000000000000000000000000000000000000000',
      },
    );

    expect(
      reviewed.approvedHarnessHead,
      'b000000000000000000000000000000000000000',
    );
    expect(
      reviewed.approvedBase,
      'c000000000000000000000000000000000000000',
    );
    expect(reviewed.approvedProductionBase, trainCApprovedProductionBase);
  });

  test('L1B review identity fails closed when base is absent', () {
    expect(
      () => TrainCL1BReviewAuthorization.requireFromEnvironment(
        environment: const <String, String>{
          trainCApprovedHarnessHeadEnvironment:
              'b000000000000000000000000000000000000000',
        },
      ),
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_CODE_IDENTITY_MISMATCH',
        ),
      ),
    );
  });

  test('same-parse observer returns the production document unchanged',
      () async {
    final document = _singleImageDocument();
    final observer = TrainCL1BObservingOcrClient(_FixedOcrClient(document));
    final result = await observer.parseFile(
      profile: _profile(),
      filePath: 'unused.pdf',
      sourceName: 'unused.pdf',
    );

    expect(result, same(document));
    expect(observer.observedDocument, same(document));
    expect(observer.parseCount, 1);
  });

  test('source observation binds image bytes and canonical question order', () {
    final document = _singleImageDocument();
    final region = OcrQuestionRegion(
      number: 5,
      stemParts: const <String>['[图片]'],
      answerParts: const <String>[],
      explanationParts: const <String>[],
      sourcePageIndices: const <int>[1],
      sourceBlockIds: const <String>['image_5'],
      diagnostics: const <String>[],
      ownedSources: const <OcrQuestionRegionSource>[
        OcrQuestionRegionSource(
          blockId: 'image_5',
          field: OcrRegionField.stem,
          text: '[图片]',
        ),
      ],
    );
    final observation = buildTrainCL1BSourceObservation(
      document: document,
      retainedLease: ContentAssetCandidateLease(
        sourceId: 'source_5',
        localAssetIds: const <String>['image_5'],
      ),
      acceptedQuestionNumbers: const <int>{5},
      regionizer: _FixedRegionizer(
        OcrQuestionRegionizerResult(
          regions: <OcrQuestionRegion>[region],
          diagnostics: const <String, dynamic>{},
        ),
      ),
    );

    final evidence = observation.sourceImages.evidenceFor(5);
    expect(observation.blockCount, 1);
    expect(observation.imageBlockCount, 1);
    expect(observation.tableBlockCount, 0);
    expect(observation.referencedTableBlockCount, 0);
    expect(evidence, hasLength(1));
    expect(evidence.single.questionNumber, 5);
    expect(evidence.single.sourceId, 'source_5');
    expect(evidence.single.blockId, 'image_5');
    expect(evidence.single.localAssetId, 'image_5');
    expect(evidence.single.readingOrder, 0);
    expect(evidence.single.contentHash, matches(RegExp(r'^[0-9a-f]{64}$')));
  });
}

TrainCReviewedIdentity _reviewedForTest() {
  return const TrainCReviewedIdentity(
    approvedHarnessHead: 'a000000000000000000000000000000000000000',
    approvedBase: trainCL1BaseMaster,
    approvedProductionBase: trainCL1TrainBMerge,
  );
}

OcrDocument _singleImageDocument() {
  return OcrDocument(
    sourceName: 'fixture.pdf',
    pages: <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          OcrBlock(
            blockId: 'image_5',
            pageIndex: 1,
            type: 'image',
            text: '[图片]',
            bbox: const <double>[],
            readingOrder: 7,
            imagePayload: OcrImagePayload(
              bytes: const <int>[1, 2, 3, 4],
              mimeType: 'image/png',
            ),
          ),
        ],
      ),
    ],
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

AiEngineProfile _profile() {
  return const AiEngineProfile(
    id: 'train-c-test-ocr',
    engineType: AiEngineType.ocr,
    name: 'train-c-test',
    apiKey: 'test-key',
    baseUrl: 'https://open.bigmodel.cn/api/paas',
    modelName: 'glm-ocr',
    temperature: 0,
    reasoningEffort: '',
    isActive: true,
  );
}
