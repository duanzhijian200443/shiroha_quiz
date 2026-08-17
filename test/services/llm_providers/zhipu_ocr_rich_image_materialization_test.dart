import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/typed_question_assembler.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';

void main() {
  const profile = AiEngineProfile(
    id: 'test-ocr',
    engineType: AiEngineType.ocr,
    name: 'Test OCR',
    apiKey: 'fixture-api-key',
    baseUrl: 'https://open.bigmodel.cn/api/paas',
    modelName: ZhipuOcrClient.model,
    temperature: 0,
    reasoningEffort: '',
    isActive: true,
  );

  late Directory tempDir;
  late File inputImage;
  late ManagedContentAssetStore assetStore;

  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ocr_rich_image_e2e_');
    inputImage = File('${tempDir.path}${Platform.pathSeparator}input.png')
      ..writeAsBytesSync(const <int>[1, 2, 3]);
    assetStore = ManagedContentAssetStore(managedRoot: tempDir);
    DefaultContentAssetResolver.instance.setStore(assetStore);
  });

  tearDown(() async {
    DefaultContentAssetResolver.instance.setStore(null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('provider HTTPS crop becomes a durable typed ImageNode', () async {
    const cropUrl = 'https://images.bigmodel.cn/crops/q1.png';
    var postCount = 0;
    var cropGetCount = 0;
    final client = ZhipuOcrClient(
      httpClient: MockClient((request) async {
        if (request.method == 'POST') {
          postCount++;
          return http.Response(
            jsonEncode(<String, Object?>{
              'md_results': 'synthetic',
              'layout_details': <Object?>[
                <Object?>[
                  <String, Object?>{
                    'index': 1,
                    'label': 'text',
                    'content': '一、选择题（本题共1小题）',
                  },
                  <String, Object?>{
                    'index': 2,
                    'label': 'text',
                    'content': '1. 设函数 f(x)=x，则下列正确的是（ ）',
                  },
                  <String, Object?>{
                    'index': 3,
                    'label': 'image',
                    'content': cropUrl,
                  },
                  <String, Object?>{
                    'index': 4,
                    'label': 'text',
                    'content': 'A. 1\nB. 2\nC. 3\nD. 4',
                  },
                  <String, Object?>{
                    'index': 5,
                    'label': 'text',
                    'content': '答案：A',
                  },
                ],
              ],
              'data_info': <String, Object?>{
                'num_pages': 1,
                'pages': <Object?>[
                  <String, Object?>{'width': 600, 'height': 800},
                ],
              },
            }),
            200,
          );
        }
        if (request.method == 'GET' && request.url.toString() == cropUrl) {
          cropGetCount++;
          return http.Response.bytes(
            pngBytes,
            200,
            headers: <String, String>{'content-type': 'image/png'},
          );
        }
        return http.Response('unexpected request', 500);
      }),
    );

    final document = await client.parseFile(
      profile: profile,
      filePath: inputImage.path,
      sourceName: 'input.png',
    );

    expect(postCount, 1);
    expect(cropGetCount, 1);
    final imageBlock = document.flattenedBlocks.singleWhere(
      (block) => block.type.trim().toLowerCase() == 'image',
    );
    expect(imageBlock.text, startsWith('data:image/png;base64,'));
    expect(document.rawResponses.toString(), isNot(contains(cropUrl)));

    final sourceDocument = const OcrSourceDocumentAdapter().convert(
      document,
      sourceId: 'source_rich_image',
    );
    final sourceAsset =
        sourceDocument.parts.whereType<SourceAssetPart>().single;
    final durableRef = 'content_assets/${sourceAsset.asset.assetId}';
    expect(durableRef, startsWith('content_assets/'));
    expect(durableRef, isNot(contains(cropUrl)));
    expect(assetStore.resolveAsset(durableRef), isNotNull);
    expect(assetStore.resolveAsset(durableRef)!.readAsBytesSync(), pngBytes);

    final regionized = const OcrQuestionRegionizer().regionize(document);
    expect(regionized.regions, hasLength(1));
    final typedRegion = const OcrQuestionRegionBridge().convert(
      regionized.regions.single,
      sourceDocument: sourceDocument,
    );
    final draft = const TypedQuestionAssembler().assemble(
      typedRegion,
      questionId: 'question_rich_image',
    );
    final typedImage = draft.stem.nodes.whereType<ImageNode>().single;
    expect(typedImage.assetRef, durableRef);
    expect(
      DefaultContentAssetResolver.instance.resolveAsset(typedImage.assetRef),
      isNotNull,
    );
  });

  test('unsafe crop URL is never fetched and degrades to a fixed placeholder',
      () async {
    const unsafeUrl = 'https://127.0.0.1/private/crop.png';
    var getCount = 0;
    final client = ZhipuOcrClient(
      httpClient: MockClient((request) async {
        if (request.method == 'GET') {
          getCount++;
          return http.Response.bytes(pngBytes, 200);
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'md_results': 'synthetic',
            'layout_details': <Object?>[
              <Object?>[
                <String, Object?>{
                  'index': 1,
                  'label': 'image',
                  'content': unsafeUrl,
                },
              ],
            ],
            'data_info': <String, Object?>{
              'num_pages': 1,
              'pages': <Object?>[
                <String, Object?>{'width': 600, 'height': 800},
              ],
            },
          }),
          200,
        );
      }),
    );

    final document = await client.parseFile(
      profile: profile,
      filePath: inputImage.path,
      sourceName: 'input.png',
    );

    expect(getCount, 0);
    expect(document.flattenedBlocks.single.text, '[图片]');
    expect(document.rawResponses.toString(), isNot(contains(unsafeUrl)));
  });
}
