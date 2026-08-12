import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/ocr_parsed_artifact_generation_adapter.dart';

const _zhipuProfile = AiEngineProfile(
  id: 'test-ocr',
  engineType: AiEngineType.ocr,
  name: 'Test OCR',
  apiKey: 'fixture-api-key',
  baseUrl: 'https://open.bigmodel.cn/api/paas',
  modelName: 'glm-ocr',
  temperature: 0,
  reasoningEffort: '',
  isActive: true,
);

class _FakeOcrClient implements OcrDocumentClient {
  Object? nextResult;
  int callCount = 0;
  String? lastFilePath;
  String? lastSourceName;
  AiEngineProfile? lastProfile;

  @override
  String get modelId => 'glm-ocr';

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    callCount++;
    lastProfile = profile;
    lastFilePath = filePath;
    lastSourceName = sourceName;
    final result = nextResult;
    if (result is OcrDocument) return result;
    throw result as Object;
  }
}

void main() {
  late Directory tempDir;
  late ManagedFileStorageAdapter managedStorage;
  late _FakeOcrClient ocrClient;
  AiEngineProfile? activeProfile;
  late OcrParsedArtifactGenerationAdapter adapter;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('i2_ocr_adapter_');
    managedStorage = ManagedFileStorageAdapter(managedRoot: tempDir);
    ocrClient = _FakeOcrClient();
    activeProfile = _zhipuProfile;
    adapter = OcrParsedArtifactGenerationAdapter(
      managedFileStorage: managedStorage,
      ocrClient: ocrClient,
      activeOcrProfileLoader: () async => activeProfile,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  LibraryFile libraryFile({
    String displayName = 'page.png',
    String? mimeType,
    String storageKey = 'library/file-1',
  }) {
    return LibraryFile(
      fileId: 'file-1',
      displayName: displayName,
      mimeType: mimeType ?? 'image/png',
      sizeBytes: 3,
      sha256:
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      storageKey: storageKey,
      createdAt: DateTime.utc(2026, 8, 13),
    );
  }

  Future<void> seedManagedFile(String storageKey) async {
    final fixture = File(
        p.join(tempDir.path, 'fixture_${storageKey.replaceAll('/', '_')}'));
    await fixture.writeAsBytes(<int>[137, 80, 78, 71, 1, 2, 3, 4]);
    await managedStorage.copyIntoManagedStorage(
      externalPath: fixture.path,
      storageKey: storageKey,
    );
    await fixture.delete();
  }

  Future<ParsedArtifactGenerationPlan> resolvePlan(
    LibraryFile file,
    ParsedArtifactRouteSelection selection,
  ) {
    return adapter.resolvePlan(
      file: file,
      options: ParsedArtifactParseOptions(routeSelection: selection),
    );
  }

  ParsedArtifactGenerationPlan plan(String route) {
    return ParsedArtifactGenerationPlan(
      parserRoute: route,
      parserVersion: 'glm-ocr.ocr-source-adapter.v1',
      optionsSchemaVersion: 1,
    );
  }

  OcrDocument textDocument({
    String sourceName = 'artifact.png',
  }) {
    return OcrDocument(
      sourceName: sourceName,
      pages: <OcrPage>[
        OcrPage(
          pageIndex: 1,
          blocks: <OcrBlock>[
            OcrBlock(
              blockId: 'p001_b0001',
              pageIndex: 1,
              type: 'text',
              text: 'formal ocr text',
              bbox: const <double>[],
              readingOrder: 0,
            ),
          ],
        ),
      ],
      markdown: '',
      rawResponses: const <Map<String, dynamic>>[],
      usage: const <String, dynamic>{},
    );
  }

  group('route admission', () {
    test('explicit OCR selections resolve offline without profile access',
        () async {
      var loaderCalls = 0;
      final offlineAdapter = OcrParsedArtifactGenerationAdapter(
        managedFileStorage: managedStorage,
        ocrClient: ocrClient,
        activeOcrProfileLoader: () async {
          loaderCalls++;
          return activeProfile;
        },
      );

      final pdf = await offlineAdapter.resolvePlan(
        file: libraryFile(
          displayName: 'a.pdf',
          mimeType: 'application/pdf',
        ),
        options: const ParsedArtifactParseOptions(
          routeSelection: ParsedArtifactRouteSelection.ocrPdf,
        ),
      );
      final png = await offlineAdapter.resolvePlan(
        file: libraryFile(displayName: 'a.png', mimeType: 'image/png'),
        options: const ParsedArtifactParseOptions(
          routeSelection: ParsedArtifactRouteSelection.ocrImage,
        ),
      );
      final jpg = await offlineAdapter.resolvePlan(
        file: libraryFile(displayName: 'a.jpg', mimeType: 'image/jpeg'),
        options: const ParsedArtifactParseOptions(
          routeSelection: ParsedArtifactRouteSelection.ocrImage,
        ),
      );
      final jpeg = await offlineAdapter.resolvePlan(
        file: libraryFile(displayName: 'a.jpeg', mimeType: 'image/jpeg'),
        options: const ParsedArtifactParseOptions(
          routeSelection: ParsedArtifactRouteSelection.ocrImage,
        ),
      );

      expect(pdf.parserRoute, 'ocr_pdf');
      expect(png.parserRoute, 'ocr_image');
      expect(jpg.parserRoute, 'ocr_image');
      expect(jpeg.parserRoute, 'ocr_image');
      expect(pdf.parserVersion, 'glm-ocr.ocr-source-adapter.v1');
      expect(pdf.optionsSchemaVersion, 1);
      expect(loaderCalls, 0);
    });

    test('unknown extension with pdf/image MIME is admitted', () async {
      final pdf = await resolvePlan(
        libraryFile(displayName: 'noext', mimeType: 'application/pdf'),
        ParsedArtifactRouteSelection.ocrPdf,
      );
      final png = await resolvePlan(
        libraryFile(displayName: 'noext', mimeType: 'image/png'),
        ParsedArtifactRouteSelection.ocrImage,
      );
      final jpeg = await resolvePlan(
        libraryFile(displayName: 'noext', mimeType: 'image/jpeg'),
        ParsedArtifactRouteSelection.ocrImage,
      );
      expect(pdf.parserRoute, 'ocr_pdf');
      expect(png.parserRoute, 'ocr_image');
      expect(jpeg.parserRoute, 'ocr_image');
    });

    test('Amendment A rejections', () async {
      final cases = <(String, String?, ParsedArtifactRouteSelection)>[
        (
          'noext',
          'application/octet-stream',
          ParsedArtifactRouteSelection.ocrPdf
        ),
        (
          'noext',
          'application/octet-stream',
          ParsedArtifactRouteSelection.ocrImage
        ),
        ('noext', 'image/gif', ParsedArtifactRouteSelection.ocrImage),
        ('noext', 'image/webp', ParsedArtifactRouteSelection.ocrImage),
        ('a.jpg', 'application/pdf', ParsedArtifactRouteSelection.ocrImage),
        ('a.pdf', 'image/jpeg', ParsedArtifactRouteSelection.ocrPdf),
        ('a.png', 'image/jpeg', ParsedArtifactRouteSelection.ocrImage),
        ('a.pdf', 'image/png', ParsedArtifactRouteSelection.ocrPdf),
        ('a.docx', 'application/pdf', ParsedArtifactRouteSelection.ocrPdf),
      ];
      for (final (name, mime, selection) in cases) {
        await expectLater(
          resolvePlan(
            libraryFile(displayName: name, mimeType: mime),
            selection,
          ),
          throwsA(
            isA<ParsedArtifactGenerationException>().having(
              (error) => error.failure,
              'failure',
              ParsedArtifactGenerationFailure.unsupportedRoute,
            ),
          ),
          reason: '$name $mime $selection',
        );
      }
    });

    test('non-OCR selections are unsupported in the OCR adapter', () async {
      for (final selection in <ParsedArtifactRouteSelection>[
        ParsedArtifactRouteSelection.auto,
        ParsedArtifactRouteSelection.pdfText,
        ParsedArtifactRouteSelection.docxText,
        ParsedArtifactRouteSelection.txt,
        ParsedArtifactRouteSelection.markdown,
      ]) {
        await expectLater(
          resolvePlan(
            libraryFile(displayName: 'a.pdf'),
            selection,
          ),
          throwsA(
            isA<ParsedArtifactGenerationException>().having(
              (error) => error.failure,
              'failure',
              ParsedArtifactGenerationFailure.unsupportedRoute,
            ),
          ),
        );
      }
    });

    test('generate defensively rejects non-OCR routes', () async {
      await expectLater(
        adapter.generate(
          file: libraryFile(),
          artifactId: 'artifact-1',
          plan: plan('pdf_text'),
        ),
        throwsA(
          isA<ParsedArtifactGenerationException>().having(
            (error) => error.failure,
            'failure',
            ParsedArtifactGenerationFailure.unsupportedRoute,
          ),
        ),
      );
    });
  });

  group('profile admission', () {
    Future<Object?> generateWithProfile(AiEngineProfile? profile) async {
      activeProfile = profile;
      await seedManagedFile('library/file-1');
      ocrClient.nextResult = textDocument();
      try {
        return await adapter.generate(
          file: libraryFile(),
          artifactId: 'artifact-1',
          plan: plan('ocr_image'),
        );
      } catch (error) {
        return error;
      }
    }

    test('missing profile is temporarilyUnavailable', () async {
      final result = await generateWithProfile(null);
      expect(result, isA<ParsedArtifactGenerationException>());
      expect(
        (result as ParsedArtifactGenerationException).failure,
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    });

    test('incomplete profile is temporarilyUnavailable', () async {
      final incomplete = AiEngineProfile(
        id: 'x',
        engineType: AiEngineType.ocr,
        name: 'x',
        apiKey: '',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: '',
        temperature: 0,
        reasoningEffort: '',
        isActive: true,
      );
      final result = await generateWithProfile(incomplete);
      expect(
        (result as ParsedArtifactGenerationException).failure,
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    });

    test('non-OCR engine type is temporarilyUnavailable', () async {
      final textProfile = AiEngineProfile(
        id: 'x',
        engineType: AiEngineType.text,
        name: 'x',
        apiKey: 'k',
        baseUrl: 'https://open.bigmodel.cn/api/paas',
        modelName: 'm',
        temperature: 0,
        reasoningEffort: '',
        isActive: true,
      );
      final result = await generateWithProfile(textProfile);
      expect(
        (result as ParsedArtifactGenerationException).failure,
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    });

    test('non-zhipu base URL is temporarilyUnavailable', () async {
      final openAiProfile = AiEngineProfile(
        id: 'x',
        engineType: AiEngineType.ocr,
        name: 'x',
        apiKey: 'k',
        baseUrl: 'https://api.example.com',
        modelName: 'm',
        temperature: 0,
        reasoningEffort: '',
        isActive: true,
      );
      final result = await generateWithProfile(openAiProfile);
      expect(
        (result as ParsedArtifactGenerationException).failure,
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    });
  });

  group('source and content', () {
    test('missing managed file is sourceUnavailable', () async {
      try {
        await adapter.generate(
          file: libraryFile(),
          artifactId: 'artifact-1',
          plan: plan('ocr_image'),
        );
        fail('expected sourceUnavailable');
      } on ParsedArtifactGenerationException catch (error) {
        expect(
          error.failure,
          ParsedArtifactGenerationFailure.sourceUnavailable,
        );
        expect(error.toString(), isNot(contains(tempDir.path)));
        expect(error.toString(), isNot(contains('library/file-1')));
      }
    });

    test('empty OCR result is sourceUnavailable', () async {
      await seedManagedFile('library/file-1');
      ocrClient.nextResult = OcrDocument(
        sourceName: 'artifact.png',
        pages: const <OcrPage>[],
        markdown: '',
        rawResponses: const <Map<String, dynamic>>[],
        usage: const <String, dynamic>{},
      );
      try {
        await adapter.generate(
          file: libraryFile(),
          artifactId: 'artifact-1',
          plan: plan('ocr_image'),
        );
        fail('expected sourceUnavailable');
      } on ParsedArtifactGenerationException catch (error) {
        expect(
          error.failure,
          ParsedArtifactGenerationFailure.sourceUnavailable,
        );
      }
    });

    test('markdown-only OCR becomes a safe markdown fallback part', () async {
      await seedManagedFile('library/file-1');
      ocrClient.nextResult = OcrDocument(
        sourceName: 'artifact.png',
        pages: const <OcrPage>[],
        markdown: '# Title\n\nformal markdown body',
        rawResponses: const <Map<String, dynamic>>[],
        usage: const <String, dynamic>{},
      );

      final document = await adapter.generate(
        file: libraryFile(),
        artifactId: 'artifact-1',
        plan: plan('ocr_image'),
      );

      expect(document.documentRef.sourceId, 'artifact-1');
      expect(document.documentRef.displayLabel, 'page.png');
      final part = document.parts.single as UnsupportedSourcePart;
      expect(part.kindCode, 'ocr_markdown_fallback');
      expect(
        (part.fallbackContent.nodes.single as TextNode).text,
        contains('formal markdown body'),
      );
    });

    test('table/image/unknown blocks become valid unsupported parts', () async {
      await seedManagedFile('library/file-1');
      ocrClient.nextResult = OcrDocument(
        sourceName: 'artifact.png',
        pages: <OcrPage>[
          OcrPage(
            pageIndex: 1,
            blocks: <OcrBlock>[
              OcrBlock(
                blockId: 'p001_b0001',
                pageIndex: 1,
                type: 'table',
                text: 'row|cell',
                bbox: const <double>[],
                readingOrder: 0,
              ),
              OcrBlock(
                blockId: 'p001_b0002',
                pageIndex: 1,
                type: 'image',
                text: 'figure caption',
                bbox: const <double>[],
                readingOrder: 1,
              ),
              OcrBlock(
                blockId: 'p001_b0003',
                pageIndex: 1,
                type: 'widget',
                text: 'unknown payload',
                bbox: const <double>[],
                readingOrder: 2,
              ),
            ],
          ),
        ],
        markdown: '',
        rawResponses: const <Map<String, dynamic>>[],
        usage: const <String, dynamic>{},
      );

      final document = await adapter.generate(
        file: libraryFile(),
        artifactId: 'artifact-1',
        plan: plan('ocr_image'),
      );

      expect(
        document.parts.map(
          (part) => (part as UnsupportedSourcePart).kindCode,
        ),
        <String>['ocr_table', 'ocr_image', 'ocr_unknown'],
      );
      expect(
        document.issues
            .where((issue) => issue.code == 'ocr_structure_unsupported'),
        hasLength(3),
      );
    });

    test('privacy-neutral runtime sourceName reaches the client', () async {
      await seedManagedFile('library/file-1');
      ocrClient.nextResult = textDocument();

      await adapter.generate(
        file: libraryFile(displayName: 'user-secret-name.png'),
        artifactId: 'artifact-1',
        plan: plan('ocr_image'),
      );

      expect(ocrClient.lastSourceName, 'artifact-1.png');
      expect(ocrClient.lastSourceName, isNot(contains('user-secret-name')));

      await adapter.generate(
        file: libraryFile(displayName: 'a.jpg', mimeType: 'image/jpeg'),
        artifactId: 'artifact-2',
        plan: plan('ocr_image'),
      );
      expect(ocrClient.lastSourceName, 'artifact-2.jpg');

      await adapter.generate(
        file: libraryFile(
          displayName: 'a.pdf',
          mimeType: 'application/pdf',
        ),
        artifactId: 'artifact-3',
        plan: plan('ocr_pdf'),
      );
      expect(ocrClient.lastSourceName, 'artifact-3.pdf');
    });
  });

  group('provider failure mapping', () {
    Future<ParsedArtifactGenerationFailure?> generateWith(Object error) async {
      await seedManagedFile('library/file-1');
      ocrClient.nextResult = error;
      try {
        await adapter.generate(
          file: libraryFile(),
          artifactId: 'artifact-1',
          plan: plan('ocr_image'),
        );
        return null;
      } on ParsedArtifactGenerationException catch (caught) {
        return caught.failure;
      }
    }

    test('authentication is temporarilyUnavailable', () async {
      expect(
        await generateWith(const ZhipuOcrAuthenticationException()),
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    });

    test('request failure is temporarilyUnavailable', () async {
      expect(
        await generateWith(const ZhipuOcrRequestException()),
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    });

    test('timeout is temporarilyUnavailable', () async {
      expect(
        await generateWith(TimeoutException('timed out')),
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    });

    test('socket failure is temporarilyUnavailable', () async {
      expect(
        await generateWith(const SocketException('connection refused')),
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    });

    test('malformed response is parseFailed', () async {
      expect(
        await generateWith(const ZhipuOcrResponseFormatException()),
        ParsedArtifactGenerationFailure.parseFailed,
      );
    });

    test('invalid PDF is parseFailed', () async {
      expect(
        await generateWith(const ZhipuOcrInvalidPdfException()),
        ParsedArtifactGenerationFailure.parseFailed,
      );
    });

    test('unclassified client-boundary failure is temporarilyUnavailable',
        () async {
      expect(
        await generateWith(StateError('unknown client failure')),
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    });
  });

  group('privacy', () {
    test('provider and geometry canaries never persist', () async {
      await seedManagedFile('library/file-1');
      ocrClient.nextResult = OcrDocument(
        sourceName: 'fake-private-path-canary.png',
        pages: <OcrPage>[
          OcrPage(
            pageIndex: 1,
            width: 123456789,
            height: 987654321,
            blocks: <OcrBlock>[
              OcrBlock(
                blockId: 'p001_b0001',
                pageIndex: 1,
                type: 'text',
                text: 'formal ocr text survives',
                bbox: const <double>[111.5, 222.5, 333.5, 444.5],
                readingOrder: 0,
                confidence: 0.98765,
                raw: <String, dynamic>{'secret-canary': 'block-raw'},
              ),
            ],
          ),
        ],
        markdown: 'markdown-canary',
        rawResponses: <Map<String, dynamic>>[
          <String, dynamic>{'provider-secret-canary': 'raw-response'},
        ],
        usage: const <String, dynamic>{'secret': 'usage-canary'},
      );

      final document = await adapter.generate(
        file: libraryFile(),
        artifactId: 'artifact-1',
        plan: plan('ocr_image'),
      );

      final strings = <String>[];
      for (final part in document.parts) {
        if (part is SourceContentPart) {
          for (final node in part.content.nodes) {
            if (node is TextNode) strings.add(node.text);
          }
        }
      }
      expect(strings, contains('formal ocr text survives'));
      for (final forbidden in <String>[
        'provider-secret-canary',
        'raw-response',
        'usage-canary',
        'secret-canary',
        'block-raw',
        '123456789',
        '987654321',
        '111.5',
        '0.98765',
        'fake-private-path-canary',
      ]) {
        expect(
          strings.any((value) => value.contains(forbidden)),
          isFalse,
          reason: forbidden,
        );
      }
    });
  });
}
