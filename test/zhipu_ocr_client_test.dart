import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
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

    group('PDF Page Chunking & Reliability Tests (Phase 3)', () {
      File createSyntheticPdf(int pageCount) {
        final doc = PdfDocument();
        for (var i = 0; i < pageCount; i++) {
          final page = doc.pages.add();
          page.graphics.drawString(
            'Page ${i + 1}',
            PdfStandardFont(PdfFontFamily.helvetica, 12),
          );
        }
        final bytes = doc.saveSync();
        doc.dispose();
        final file = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'pdf_test_${DateTime.now().microsecondsSinceEpoch}_$pageCount.pdf',
        )..writeAsBytesSync(bytes);
        return file;
      }

      const mockResponseJson = '''
{
  "md_results": "Page Content",
  "layout_details": [[{"index": 1, "label": "text", "content": "hello"}]],
  "data_info": {"num_pages": 1, "pages": [{"width": 600, "height": 800}]}
}
''';

      test(
          '1-page PDF sends 1 HTTP request without start_page_id / end_page_id',
          () async {
        final pdfFile = createSyntheticPdf(1);
        addTearDown(() => pdfFile.deleteSync());

        final requests = <http.Request>[];
        final client = ZhipuOcrClient(
          httpClient: MockClient((req) async {
            requests.add(req);
            return http.Response(mockResponseJson, 200);
          }),
        );

        final doc = await client.parseFile(
          profile: profile,
          filePath: pdfFile.path,
          sourceName: '1page.pdf',
        );

        expect(doc.pages, isNotEmpty);
        expect(requests, hasLength(1));

        final body = jsonDecode(requests.first.body) as Map<String, dynamic>;
        expect(body.containsKey('start_page_id'), isFalse);
        expect(body.containsKey('end_page_id'), isFalse);
      });

      test('30-page PDF sends 1 HTTP request', () async {
        final pdfFile = createSyntheticPdf(30);
        addTearDown(() => pdfFile.deleteSync());

        final requests = <http.Request>[];
        final client = ZhipuOcrClient(
          httpClient: MockClient((req) async {
            requests.add(req);
            return http.Response(mockResponseJson, 200);
          }),
        );

        final doc = await client.parseFile(
          profile: profile,
          filePath: pdfFile.path,
          sourceName: '30page.pdf',
        );

        expect(doc.pages, isNotEmpty);
        expect(requests, hasLength(1));
      });

      test('31-page PDF splits into 2 HTTP requests (1-30 and 31-31)',
          () async {
        final pdfFile = createSyntheticPdf(31);
        addTearDown(() => pdfFile.deleteSync());

        final requests = <http.Request>[];
        final client = ZhipuOcrClient(
          httpClient: MockClient((req) async {
            requests.add(req);
            return http.Response(mockResponseJson, 200);
          }),
        );

        final doc = await client.parseFile(
          profile: profile,
          filePath: pdfFile.path,
          sourceName: '31page.pdf',
        );

        expect(doc.pages, isNotEmpty);
        expect(requests, hasLength(2));

        final req1Body = jsonDecode(requests[0].body) as Map<String, dynamic>;
        expect(req1Body['start_page_id'], 1);
        expect(req1Body['end_page_id'], 30);

        final req2Body = jsonDecode(requests[1].body) as Map<String, dynamic>;
        expect(req2Body['start_page_id'], 31);
        expect(req2Body['end_page_id'], 31);
      });

      test(
          'invalid PDF throws ZhipuOcrInvalidPdfException with 0 HTTP requests',
          () async {
        final fakeFile = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'invalid_${DateTime.now().microsecondsSinceEpoch}.pdf',
        )..writeAsStringSync('not-a-real-pdf-content');
        addTearDown(() => fakeFile.deleteSync());

        var httpCalled = false;
        final client = ZhipuOcrClient(
          httpClient: MockClient((_) async {
            httpCalled = true;
            return http.Response(mockResponseJson, 200);
          }),
        );

        await expectLater(
          client.parseFile(
            profile: profile,
            filePath: fakeFile.path,
            sourceName: 'invalid.pdf',
          ),
          throwsA(isA<ZhipuOcrInvalidPdfException>()),
        );

        expect(httpCalled, isFalse);
      });
    });
  });
}
