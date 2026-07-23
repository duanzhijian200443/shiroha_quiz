import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';

void main() {
  const profile = AiEngineProfile(
    id: 'test-ocr',
    engineType: AiEngineType.ocr,
    name: 'Test OCR',
    apiKey: 'fixture-api-key',
    baseUrl: 'https://example.test/api/paas',
    modelName: ZhipuOcrClient.model,
    temperature: 0,
    reasoningEffort: '',
    isActive: true,
  );

  group('ZhipuOcrClient / OcrDocument', () {
    test('buildLayoutParsingUrl appends the right endpoint suffix', () {
      expect(
        ZhipuOcrClient.buildLayoutParsingUrl(
            'https://open.bigmodel.cn/api/paas'),
        'https://open.bigmodel.cn/api/paas/v4/layout_parsing',
      );
      expect(
        ZhipuOcrClient.buildLayoutParsingUrl('https://api.z.ai/api/paas/v4'),
        'https://api.z.ai/api/paas/v4/layout_parsing',
      );
    });

    test('parses layout_parsing response into pages and blocks', () {
      final document = OcrDocument.fromLayoutParsingResponse(
        {
          'md_results': '# Title\n\n1 Question',
          'layout_details': [
            [
              {
                'index': 1,
                'label': 'text',
                'bbox_2d': [0.1, 0.2, 0.8, 0.3],
                'content': '1 设 lim f(x)/ln x = 1，则（ ）',
                'height': 800,
                'width': 600,
              }
            ],
            [
              {
                'index': 1,
                'label': 'text',
                'bbox_2d': [0.1, 0.2, 0.8, 0.4],
                'content': '答案：B',
                'height': 800,
                'width': 600,
              }
            ],
          ],
          'data_info': {
            'num_pages': 2,
            'pages': [
              {'width': 600, 'height': 800},
              {'width': 600, 'height': 800},
            ],
          },
          'usage': {'total_tokens': 12},
        },
        sourceName: 'sample.pdf',
      );

      expect(document.pages, hasLength(2));
      expect(document.flattenedBlocks, hasLength(2));
      expect(document.pages.first.blocks.first.pageIndex, 1);
      expect(document.pages.last.blocks.first.pageIndex, 2);
      expect(document.pages.first.blocks.first.type, 'text');
      expect(document.pages.first.blocks.first.text, contains('1 设 lim'));
      expect(document.toDiagnostics()['pageCount'], 2);
    });

    test('uses a typed authentication failure without response-body leakage',
        () async {
      final image = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'zhipu-ocr-auth-${DateTime.now().microsecondsSinceEpoch}.png',
      )..writeAsBytesSync(const [1]);
      addTearDown(() => image.deleteSync());
      final client = ZhipuOcrClient(
        httpClient: MockClient(
          (_) async => http.Response('PRIVATE_PROVIDER_BODY', 401),
        ),
      );

      await expectLater(
        client.parseFile(
          profile: profile,
          filePath: image.path,
          sourceName: 'fixture.png',
        ),
        throwsA(isA<ZhipuOcrAuthenticationException>()),
      );
    });

    test('uses a typed response-format failure for malformed JSON', () async {
      final image = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'zhipu-ocr-format-${DateTime.now().microsecondsSinceEpoch}.png',
      )..writeAsBytesSync(const [1]);
      addTearDown(() => image.deleteSync());
      final client = ZhipuOcrClient(
        httpClient: MockClient((_) async => http.Response('not-json', 200)),
      );

      await expectLater(
        client.parseFile(
          profile: profile,
          filePath: image.path,
          sourceName: 'fixture.png',
        ),
        throwsA(isA<ZhipuOcrResponseFormatException>()),
      );
    });
  });
}
