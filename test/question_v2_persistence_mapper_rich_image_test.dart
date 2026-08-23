import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('question_image_mapper_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('configured mapper requires and accepts durable image bytes', () {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final mapper = QuestionV2PersistenceMapper(
      contentAssetAuthority: store,
    );
    final draft = _imageDraft();

    expect(
      () => mapper.freezeForWrite(
        storageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
        bankName: 'synthetic_bank',
        createdAt: 1,
        draft: draft,
      ),
      throwsA(isA<QuestionV2PayloadException>()),
    );

    store.storeBytesSync(
      sourceId: 'source_001',
      localAssetId: 'asset_000001',
      bytes: <int>[137, 80, 78, 71, 1, 2, 3],
      mimeType: 'image/png',
    );
    final frozen = mapper.freezeForWrite(
      storageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
      bankName: 'synthetic_bank',
      createdAt: 1,
      draft: draft,
    );
    expect(frozen.payloadRow['payload_json'], isA<String>());
  });
}

QuestionDraftV2 _imageDraft() {
  return QuestionDraftV2(
    questionId: 'image_question',
    kind: QuestionKind.shortAnswer,
    stem: RichContent(nodes: <ContentNode>[
      ImageNode(sourceId: 'source_001', localAssetId: 'asset_000001'),
    ]),
    sourceRefs: <SourceRef>[
      SourceRef.document(sourceId: 'source_001'),
    ],
    assetRefs: <SourcedAssetRef>[
      SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(assetId: 'asset_000001', kind: AssetKind.image),
      ),
    ],
  );
}
