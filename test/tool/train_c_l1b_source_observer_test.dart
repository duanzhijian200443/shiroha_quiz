import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';

import '../../tool/train_c_l1b_source_observer.dart';

void main() {
  test('observes the exact production document once and binds image facts',
      () async {
    final document = OcrDocument(
      sourceName: 'synthetic-input',
      markdown: '',
      rawResponses: const [],
      usage: const {},
      pages: [
        OcrPage(
          pageIndex: 1,
          blocks: [
            const OcrBlock(
              blockId: 'section',
              pageIndex: 1,
              type: 'text',
              text: '一、选择题（共 1 题）',
              bbox: [],
              readingOrder: 0,
            ),
            const OcrBlock(
              blockId: 'question',
              pageIndex: 1,
              type: 'text',
              text: '1. synthetic stem (A) one (B) two',
              bbox: [],
              readingOrder: 1,
            ),
            OcrBlock(
              blockId: 'image_1',
              pageIndex: 1,
              type: 'image',
              text: '[图片]',
              bbox: const [],
              readingOrder: 2,
              imagePayload: OcrImagePayload(
                bytes: const <int>[1, 2, 3],
                mimeType: 'image/png',
              ),
            ),
            const OcrBlock(
              blockId: 'answer',
              pageIndex: 1,
              type: 'text',
              text: '答案：A',
              bbox: [],
              readingOrder: 3,
            ),
            const OcrBlock(
              blockId: 'explanation',
              pageIndex: 1,
              type: 'text',
              text: '解析：synthetic explanation',
              bbox: [],
              readingOrder: 4,
            ),
          ],
        ),
      ],
    );
    final client = TrainCL1BObservingOcrClient(
      _FakeOcrDocumentClient(document),
    );
    const profile = AiEngineProfile(
      id: 'synthetic-profile',
      engineType: AiEngineType.ocr,
      name: 'synthetic',
      apiKey: 'synthetic-key',
      baseUrl: 'https://synthetic.invalid',
      modelName: 'synthetic-model',
      temperature: 0,
      reasoningEffort: '',
      isActive: true,
    );

    final returned = await client.parseFile(
      profile: profile,
      filePath: 'synthetic.pdf',
      sourceName: 'synthetic-input',
    );
    expect(identical(returned, document), isTrue);
    expect(client.parseCount, 1);

    final observation = buildTrainCL1BSourceObservation(
      document: returned,
      retainedLease: ContentAssetCandidateLease(
        sourceId: 'source_a',
        localAssetIds: const ['image_1'],
      ),
      acceptedQuestionNumbers: const {1},
    );
    expect(observation.sourceImages.totalReferencedImageCount, 1);
    expect(
      observation.sourceImages.orderedEvidence.single.localAssetId,
      'image_1',
    );
    expect(
      observation.sourceImages.orderedEvidence.single.contentHash,
      isNotEmpty,
    );

    await expectLater(
      client.parseFile(
        profile: profile,
        filePath: 'synthetic.pdf',
        sourceName: 'synthetic-input',
      ),
      throwsA(
        predicate<TrainCL1BSourceObservationException>(
          (error) => error.code == 'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
        ),
      ),
    );
  });
}

final class _FakeOcrDocumentClient implements OcrDocumentClient {
  _FakeOcrDocumentClient(this.document);

  final OcrDocument document;

  @override
  String get modelId => 'synthetic-model';

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    return document;
  }
}
