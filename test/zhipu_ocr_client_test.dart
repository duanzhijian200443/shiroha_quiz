import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';

const _validCropPng = <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  1,
];

const _validCropJpeg = <int>[0xff, 0xd8, 0xff];

Map<String, dynamic> _cropResponse({
  required int count,
  String url = 'https://cdn.example.com/crop.png',
}) {
  return <String, dynamic>{
    'md_results': '',
    'layout_details': <Object?>[
      [
        for (var index = 0; index < count; index++)
          <String, Object?>{
            'index': index + 1,
            'label': 'image',
            'content': url,
          },
      ],
    ],
    'data_info': <String, Object?>{
      'num_pages': 1,
      'pages': <Object?>[
        <String, Object?>{'width': 1, 'height': 1},
      ],
    },
  };
}

String _inlineImageDataUrl() =>
    'data:image/png;base64,${base64Encode(_validCropPng)}';

Map<String, dynamic> _mixedCropResponse({required String inlineDataUrl}) {
  return <String, dynamic>{
    'md_results': '',
    'layout_details': <Object?>[
      <Object?>[
        <String, Object?>{
          'index': 1,
          'label': 'image',
          'content': 'https://cdn.example.com/crop.png',
        },
        <String, Object?>{
          'index': 2,
          'label': 'figure',
          'content': inlineDataUrl,
        },
      ],
    ],
    'data_info': <String, Object?>{
      'num_pages': 1,
      'pages': <Object?>[
        <String, Object?>{'width': 1, 'height': 1},
      ],
    },
  };
}

File _syntheticPngFile(String prefix) {
  final file = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    '$prefix-${DateTime.now().microsecondsSinceEpoch}.png',
  )..writeAsBytesSync(const <int>[1]);
  return file;
}

final class _MemoryLogSink implements LogSink {
  final List<LogRecord> records = <LogRecord>[];

  @override
  Future<void> write(LogRecord record) async {
    records.add(record);
  }

  @override
  Future<void> flush() async {}
}

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

    test('crop materialization requires image bytes matching the MIME',
        () async {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'zhipu-ocr-crop-${DateTime.now().microsecondsSinceEpoch}.png',
      )..writeAsBytesSync(const <int>[1]);
      addTearDown(() => file.deleteSync());

      Future<OcrDocument> parseCrop(List<int> cropBytes) {
        final client = ZhipuOcrClient(
          httpClient: MockClient((request) async {
            if (request.method == 'GET') {
              return http.Response.bytes(
                cropBytes,
                200,
                headers: <String, String>{'content-type': 'image/png'},
              );
            }
            return http.Response(
              jsonEncode(<String, Object?>{
                'md_results': '',
                'layout_details': <Object?>[
                  <Object?>[
                    <String, Object?>{
                      'index': 1,
                      'label': 'image',
                      'content': 'https://cdn.example.com/crop.png',
                    },
                  ],
                ],
                'data_info': <String, Object?>{
                  'num_pages': 1,
                  'pages': <Object?>[
                    <String, Object?>{'width': 1, 'height': 1},
                  ],
                },
              }),
              200,
            );
          }),
          dnsResolver: (_) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
        );
        return client.parseFile(
          profile: profile,
          filePath: file.path,
          sourceName: 'fixture.png',
        );
      }

      final valid = await parseCrop(
        _validCropPng,
      );
      expect(valid.flattenedBlocks.single.imagePayload, isNotNull);

      final invalid = await parseCrop(const <int>[1, 2, 3]);
      expect(invalid.flattenedBlocks.single.imagePayload, isNull);
      expect(invalid.flattenedBlocks.single.text, '[图片]');
    });

    test('image materialization categories stay fixed and unique', () {
      final values = OcrImageMaterializationCategory.values
          .map(ocrImageMaterializationCategoryValue)
          .toList(growable: false);
      expect(
        values,
        containsAll(<String>[
          'inline_success',
          'remote_success',
          'inline_payload_invalid',
          'provider_placeholder',
          'locator_shape_unsupported',
          'uri_policy_rejected',
          'dns_resolution_failed',
          'redirect_rejected_or_exhausted',
          'http_non_success',
          'timeout_or_transport',
          'body_or_mime_invalid',
        ]),
      );
      expect(values.toSet(), hasLength(values.length));
    });

    test('remote crop telemetry is fixed, bounded and hostname-free', () async {
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);
      addTearDown(() => AppLogger.setSink(null));
      final file = _syntheticPngFile('zhipu-ocr-telemetry-success');
      addTearDown(() => file.deleteSync());
      final client = ZhipuOcrClient(
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response.bytes(
              _validCropPng,
              200,
              headers: const <String, String>{'content-type': 'image/png'},
            );
          }
          return http.Response(
            jsonEncode(
              _cropResponse(
                count: 2,
                url: 'https://cdn.example.com/private/crop.png?token=secret',
              ),
            ),
            200,
          );
        }),
        dnsResolver: (_) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
        ],
      );

      final document = await client.parseFile(
        profile: profile,
        filePath: file.path,
        sourceName: 'fixture.png',
      );
      await AppLogger.flush();

      expect(document.flattenedBlocks, hasLength(2));
      expect(
        document.flattenedBlocks.every((block) => block.imagePayload != null),
        isTrue,
      );
      final records = sink.records
          .where((record) => record.data['stage'] == 'image_materialization')
          .toList(growable: false);
      expect(records, hasLength(2));
      expect(
        records.map((record) => record.data['cropOrdinal']),
        <Object?>[1, 2],
      );
      for (final record in records) {
        expect(record.data['scheme'], 'https');
        expect(record.data['phase'], 'completed');
        expect(record.data['elapsedMs'], isA<int>());
        expect(record.data['timeoutBudgetMs'], 30000);
        expect(record.data['exceptionType'], isNull);
        expect(record.data['responseStarted'], isTrue);
        expect(record.data['httpStatus'], 200);
        expect(record.data['bytesReceived'], greaterThan(0));
        expect(record.data['result'], 'remote_success');
        expect(record.data['buildSha'], isA<String>());
        expect(record.data.containsKey('sanitizedHost'), isFalse);
        expect(record.toJson().toString(), isNot(contains('cdn.example.com')));
        expect(record.toJson().toString(), isNot(contains('token=secret')));
      }
    });

    test('remote crop send timeout keeps placeholder and fixed telemetry',
        () async {
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);
      addTearDown(() => AppLogger.setSink(null));
      final file = _syntheticPngFile('zhipu-ocr-telemetry-timeout');
      addTearDown(() => file.deleteSync());
      final client = ZhipuOcrClient(
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode(_cropResponse(count: 1)),
            200,
          ),
        ),
        remoteCropClientFactory: (_, __) =>
            _ThrowingCropClient(TimeoutException('private timeout')),
        dnsResolver: (_) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
        ],
      );

      final document = await client.parseFile(
        profile: profile,
        filePath: file.path,
        sourceName: 'fixture.png',
      );
      await AppLogger.flush();

      final record = sink.records.singleWhere(
        (item) => item.data['stage'] == 'image_materialization',
      );
      expect(document.flattenedBlocks.single.imagePayload, isNull);
      expect(document.flattenedBlocks.single.text, '[图片]');
      expect(record.data['phase'], 'send');
      expect(record.data['timeoutBudgetMs'], 30000);
      expect(record.data['exceptionType'], 'TimeoutException');
      expect(record.data['responseStarted'], isFalse);
      expect(record.data['httpStatus'], isNull);
      expect(record.data['bytesReceived'], 0);
      expect(record.data['result'], 'timeout_or_transport');
      expect(record.toJson().toString(), isNot(contains('private timeout')));
    });

    test('remote crop socket failure keeps the original placeholder result',
        () async {
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);
      addTearDown(() => AppLogger.setSink(null));
      final file = _syntheticPngFile('zhipu-ocr-telemetry-socket');
      addTearDown(() => file.deleteSync());
      final client = ZhipuOcrClient(
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode(_cropResponse(count: 1)),
            200,
          ),
        ),
        remoteCropClientFactory: (_, __) => _ThrowingCropClient(
          const SocketException('private socket'),
        ),
        dnsResolver: (_) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
        ],
      );

      final document = await client.parseFile(
        profile: profile,
        filePath: file.path,
        sourceName: 'fixture.png',
      );
      await AppLogger.flush();

      final record = sink.records.singleWhere(
        (item) => item.data['stage'] == 'image_materialization',
      );
      expect(document.flattenedBlocks.single.text, '[图片]');
      expect(record.data['phase'], 'send');
      expect(record.data['exceptionType'], 'SocketException');
      expect(record.data['responseStarted'], isFalse);
      expect(record.data['httpStatus'], isNull);
      expect(record.data['bytesReceived'], 0);
      expect(record.data['result'], 'timeout_or_transport');
      expect(record.toJson().toString(), isNot(contains('private socket')));
    });

    test('remote crop body interruption records response boundary', () async {
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);
      addTearDown(() => AppLogger.setSink(null));
      final file = _syntheticPngFile('zhipu-ocr-telemetry-body');
      addTearDown(() => file.deleteSync());
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final client = ZhipuOcrClient(
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode(_cropResponse(count: 1)),
            200,
          ),
        ),
        remoteCropClientFactory: (_, __) => _StreamedCropClient(() {
          scheduleMicrotask(() {
            body.add(_validCropPng.sublist(0, 3));
            body.addError(const SocketException('private body'));
            body.close();
          });
          return http.StreamedResponse(
            body.stream,
            200,
            headers: const <String, String>{'content-type': 'image/png'},
          );
        }),
        dnsResolver: (_) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
        ],
      );

      final document = await client.parseFile(
        profile: profile,
        filePath: file.path,
        sourceName: 'fixture.png',
      );
      await AppLogger.flush();

      final record = sink.records.singleWhere(
        (item) => item.data['stage'] == 'image_materialization',
      );
      expect(document.flattenedBlocks.single.text, '[图片]');
      expect(record.data['phase'], 'body');
      expect(record.data['exceptionType'], 'SocketException');
      expect(record.data['responseStarted'], isTrue);
      expect(record.data['httpStatus'], 200);
      expect(record.data['bytesReceived'], 3);
      expect(record.data['result'], 'timeout_or_transport');
      expect(record.toJson().toString(), isNot(contains('private body')));
    });

    test('remote crop status and body validation remain observable', () async {
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);
      addTearDown(() => AppLogger.setSink(null));
      final file = _syntheticPngFile('zhipu-ocr-telemetry-validation');
      addTearDown(() => file.deleteSync());

      Future<OcrDocument> parseRemote({
        required http.Client remoteClient,
      }) {
        final client = ZhipuOcrClient(
          httpClient: MockClient(
            (request) async => http.Response(
              jsonEncode(_cropResponse(count: 1)),
              200,
            ),
          ),
          remoteCropClientFactory: (_, __) => remoteClient,
          dnsResolver: (_) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
        );
        return client.parseFile(
          profile: profile,
          filePath: file.path,
          sourceName: 'fixture.png',
        );
      }

      final statusDocument = await parseRemote(
        remoteClient: MockClient(
          (_) async => http.Response('private response body', 500),
        ),
      );
      expect(statusDocument.flattenedBlocks.single.text, '[图片]');
      final invalidDocument = await parseRemote(
        remoteClient: MockClient(
          (_) async => http.Response.bytes(
            const <int>[1, 2, 3],
            200,
            headers: const <String, String>{'content-type': 'image/png'},
          ),
        ),
      );
      expect(invalidDocument.flattenedBlocks.single.text, '[图片]');
      await AppLogger.flush();

      final records = sink.records
          .where((record) => record.data['stage'] == 'image_materialization')
          .toList(growable: false);
      expect(records, hasLength(2));
      expect(records[0].data['result'], 'http_non_success');
      expect(records[0].data['responseStarted'], isTrue);
      expect(records[0].data['httpStatus'], 500);
      expect(records[0].data['exceptionType'], isNull);
      expect(records[1].data['result'], 'body_or_mime_invalid');
      expect(records[1].data['phase'], 'validation');
      expect(records[1].data['responseStarted'], isTrue);
      expect(records[1].data['httpStatus'], 200);
      expect(records[1].data['bytesReceived'], 3);
      final serialized = records.map((record) => record.toJson()).join();
      expect(serialized, isNot(contains('private response body')));
    });

    test('remote crop validation subtypes stay fixed and preserve rejection',
        () async {
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);
      addTearDown(() => AppLogger.setSink(null));
      final file = _syntheticPngFile('zhipu-ocr-validation-subtypes');
      addTearDown(() => file.deleteSync());

      Future<LogRecord> parseRemote({
        required List<int> bytes,
        required String contentType,
        http.Client? remoteClient,
      }) async {
        sink.records.clear();
        final client = ZhipuOcrClient(
          httpClient: MockClient(
            (request) async => http.Response(
              jsonEncode(_cropResponse(count: 1)),
              200,
            ),
          ),
          remoteCropClientFactory: (_, __) =>
              remoteClient ??
              MockClient(
                (_) async => http.Response.bytes(
                  bytes,
                  200,
                  headers: <String, String>{'content-type': contentType},
                ),
              ),
          dnsResolver: (_) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
        );

        final document = await client.parseFile(
          profile: profile,
          filePath: file.path,
          sourceName: 'fixture.png',
        );
        expect(document.flattenedBlocks.single.imagePayload, isNull);
        expect(document.flattenedBlocks.single.text, '[图片]');
        await AppLogger.flush();
        final records = sink.records
            .where((record) => record.data['stage'] == 'image_materialization')
            .toList(growable: false);
        expect(records, hasLength(1));
        return records.single;
      }

      final unrecognized = await parseRemote(
        bytes: const <int>[1, 2, 3],
        contentType: 'image/png; private-mime-sentinel',
      );
      expect(unrecognized.data['result'], 'body_or_mime_invalid');
      expect(
        unrecognized.data['validationSubtype'],
        'signature_unrecognized',
      );
      expect(unrecognized.data['declaredMimeClass'], 'png');
      expect(unrecognized.data['detectedMimeClass'], 'unknown');

      final mismatch = await parseRemote(
        bytes: _validCropJpeg,
        contentType: 'image/png; private-mime-sentinel',
      );
      expect(mismatch.data['result'], 'body_or_mime_invalid');
      expect(
        mismatch.data['validationSubtype'],
        'declared_detected_mismatch',
      );
      expect(mismatch.data['declaredMimeClass'], 'png');
      expect(mismatch.data['detectedMimeClass'], 'jpeg');

      final unsupported = await parseRemote(
        bytes: _validCropPng,
        contentType: 'image/avif; private-mime-sentinel',
      );
      expect(unsupported.data['result'], 'body_or_mime_invalid');
      expect(
        unsupported.data['validationSubtype'],
        'unsupported_declared_image_mime',
      );
      expect(unsupported.data['declaredMimeClass'], 'other_image');
      expect(unsupported.data['detectedMimeClass'], 'png');

      final empty = await parseRemote(
        bytes: const <int>[],
        contentType: 'image/png',
      );
      expect(empty.data['result'], 'body_or_mime_invalid');
      expect(empty.data['validationSubtype'], 'empty_body');

      final tooLarge = await parseRemote(
        bytes: const <int>[],
        contentType: 'image/png',
        remoteClient: _StreamedCropClient(
          () => http.StreamedResponse(
            Stream<List<int>>.fromIterable(const <List<int>>[]),
            200,
            headers: const <String, String>{'content-type': 'image/png'},
            contentLength: ZhipuOcrClient.maxImageBytes + 1,
          ),
        ),
      );
      expect(tooLarge.data['result'], 'body_or_mime_invalid');
      expect(tooLarge.data['validationSubtype'], 'body_too_large');

      final serialized = sink.records.map((record) => record.toJson()).join();
      expect(serialized, isNot(contains('private MIME sentinel')));
      expect(serialized, isNot(contains('private-mime-sentinel')));
      expect(serialized, isNot(contains('image/avif')));
      expect(serialized, isNot(contains('cdn.example.com')));
      expect(serialized, isNot(contains('token=secret')));
    });

    test('remote crop count and byte budgets are aggregate and fail closed',
        () async {
      final file = _syntheticPngFile('zhipu-ocr-crop-budget');
      addTearDown(() => file.deleteSync());

      Future<OcrDocument> parse({
        required int count,
        required int byteLimit,
        int countLimit = 2,
      }) {
        final client = ZhipuOcrClient(
          httpClient: MockClient((request) async {
            if (request.method == 'GET') {
              return http.Response.bytes(
                _validCropPng,
                200,
                headers: const <String, String>{
                  'content-type': 'image/png',
                },
              );
            }
            return http.Response(
              jsonEncode(_cropResponse(count: count)),
              200,
            );
          }),
          dnsResolver: (_) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
          remoteCropCountLimit: countLimit,
          remoteCropTotalBytesLimit: byteLimit,
        );
        return client.parseFile(
          profile: profile,
          filePath: file.path,
          sourceName: 'fixture.png',
        );
      }

      final exactCount = await parse(
        count: 2,
        byteLimit: _validCropPng.length * 2,
      );
      expect(exactCount.flattenedBlocks, hasLength(2));
      expect(
        exactCount.flattenedBlocks.every((block) => block.imagePayload != null),
        isTrue,
      );

      await expectLater(
        parse(count: 3, byteLimit: _validCropPng.length * 3),
        throwsA(isA<ZhipuOcrResponseFormatException>()),
      );
      await expectLater(
        parse(count: 2, byteLimit: _validCropPng.length),
        throwsA(isA<ZhipuOcrResponseFormatException>()),
      );
    });

    test('inline data URLs use the shared count and decoded-byte budgets',
        () async {
      final file = _syntheticPngFile('zhipu-ocr-inline-budget');
      addTearDown(() => file.deleteSync());
      final inlineDataUrl = _inlineImageDataUrl();

      Future<OcrDocument> parse({
        required int count,
        required int byteLimit,
        int countLimit = 2,
      }) {
        final client = ZhipuOcrClient(
          httpClient: MockClient((request) async {
            return http.Response(
              jsonEncode(_cropResponse(count: count, url: inlineDataUrl)),
              200,
            );
          }),
          remoteCropCountLimit: countLimit,
          remoteCropTotalBytesLimit: byteLimit,
        );
        return client.parseFile(
          profile: profile,
          filePath: file.path,
          sourceName: 'fixture.png',
        );
      }

      final valid = await parse(
        count: 1,
        byteLimit: _validCropPng.length,
      );
      expect(valid.flattenedBlocks.single.imagePayload, isNotNull);

      await expectLater(
        parse(
          count: 2,
          byteLimit: _validCropPng.length * 2,
          countLimit: 1,
        ),
        throwsA(isA<ZhipuOcrResponseFormatException>()),
      );
      await expectLater(
        parse(
          count: 2,
          byteLimit: _validCropPng.length,
        ),
        throwsA(isA<ZhipuOcrResponseFormatException>()),
      );
    });

    test('remote and inline images share one document budget', () async {
      final file = _syntheticPngFile('zhipu-ocr-mixed-budget');
      addTearDown(() => file.deleteSync());
      final inlineDataUrl = _inlineImageDataUrl();

      Future<OcrDocument> parse({
        required int countLimit,
        required int byteLimit,
      }) {
        final client = ZhipuOcrClient(
          httpClient: MockClient((request) async {
            if (request.method == 'GET') {
              return http.Response.bytes(
                _validCropPng,
                200,
                headers: const <String, String>{
                  'content-type': 'image/png',
                },
              );
            }
            return http.Response(
              jsonEncode(_mixedCropResponse(inlineDataUrl: inlineDataUrl)),
              200,
            );
          }),
          dnsResolver: (_) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
          remoteCropCountLimit: countLimit,
          remoteCropTotalBytesLimit: byteLimit,
        );
        return client.parseFile(
          profile: profile,
          filePath: file.path,
          sourceName: 'fixture.png',
        );
      }

      await expectLater(
        parse(
          countLimit: 1,
          byteLimit: _validCropPng.length * 2,
        ),
        throwsA(isA<ZhipuOcrResponseFormatException>()),
      );
      await expectLater(
        parse(
          countLimit: 2,
          byteLimit: _validCropPng.length,
        ),
        throwsA(isA<ZhipuOcrResponseFormatException>()),
      );
    });

    test('redirects share crop budget and re-check the resolved target',
        () async {
      final file = _syntheticPngFile('zhipu-ocr-crop-redirect');
      addTearDown(() => file.deleteSync());
      final requestedHosts = <String>[];
      final client = ZhipuOcrClient(
        httpClient: MockClient((request) async {
          requestedHosts.add(request.url.host);
          if (request.method != 'GET') {
            return http.Response(
              jsonEncode(
                _cropResponse(
                  count: 1,
                  url: 'https://cdn.example.com/redirect.png',
                ),
              ),
              200,
            );
          }
          if (request.url.host == 'cdn.example.com') {
            return http.Response(
              '',
              302,
              headers: const <String, String>{
                'location': 'https://final.example.com/final.png',
              },
            );
          }
          return http.Response.bytes(
            _validCropPng,
            200,
            headers: const <String, String>{'content-type': 'image/png'},
          );
        }),
        dnsResolver: (_) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
        ],
        remoteCropCountLimit: 1,
        remoteCropTotalBytesLimit: _validCropPng.length,
      );
      final redirected = await client.parseFile(
        profile: profile,
        filePath: file.path,
        sourceName: 'fixture.png',
      );
      expect(redirected.flattenedBlocks.single.imagePayload, isNotNull);
      expect(requestedHosts, <String>[
        'example.test',
        'cdn.example.com',
        'final.example.com',
      ]);

      final privateClient = ZhipuOcrClient(
        httpClient: MockClient((request) async {
          if (request.method != 'GET') {
            return http.Response(
              jsonEncode(
                _cropResponse(
                  count: 1,
                  url: 'https://cdn.example.com/private.png',
                ),
              ),
              200,
            );
          }
          return http.Response(
            '',
            302,
            headers: const <String, String>{
              'location': 'https://private.example.com/image.png',
            },
          );
        }),
        dnsResolver: (host) async => <InternetAddress>[
          InternetAddress(
            host == 'private.example.com' ? '127.0.0.1' : '93.184.216.34',
          ),
        ],
        remoteCropCountLimit: 1,
        remoteCropTotalBytesLimit: _validCropPng.length,
      );
      final privateTarget = await privateClient.parseFile(
        profile: profile,
        filePath: file.path,
        sourceName: 'fixture.png',
      );
      expect(privateTarget.flattenedBlocks.single.imagePayload, isNull);
      expect(privateTarget.flattenedBlocks.single.text, '[图片]');
    });

    test('redirect response bodies are cancelled at a bounded discard limit',
        () async {
      final file = _syntheticPngFile('zhipu-ocr-hostile-redirect');
      addTearDown(() => file.deleteSync());
      final hostileBodies = <StreamController<List<int>>>[];
      addTearDown(() async {
        for (final body in hostileBodies) {
          await body.close();
        }
      });
      var cropCalls = 0;
      var hostileBodyCancelled = false;
      final client = ZhipuOcrClient(
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode(
              _cropResponse(
                count: 1,
                url: 'https://cdn.example.com/hostile-redirect.png',
              ),
            ),
            200,
          );
        }),
        remoteCropClientFactory: (_, __) => _StreamedCropClient(() {
          cropCalls++;
          if (cropCalls == 1) {
            final body = StreamController<List<int>>();
            body.onCancel = () => hostileBodyCancelled = true;
            hostileBodies.add(body);
            body.add(
              List<int>.filled(
                ZhipuOcrClient.maxRemoteResponseDiscardBytes + 1,
                0,
              ),
            );
            return http.StreamedResponse(
              body.stream,
              302,
              headers: const <String, String>{
                'location': 'https://final.example.com/final.png',
              },
            );
          }
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[_validCropPng]),
            200,
            headers: const <String, String>{'content-type': 'image/png'},
          );
        }),
        dnsResolver: (_) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
        ],
        remoteCropCountLimit: 1,
        remoteCropTotalBytesLimit: _validCropPng.length,
      );

      final document = await client.parseFile(
        profile: profile,
        filePath: file.path,
        sourceName: 'fixture.png',
      );

      expect(document.flattenedBlocks.single.imagePayload, isNotNull);
      expect(cropCalls, 2);
      expect(hostileBodyCancelled, isTrue);
    });

    test('error response bodies are cancelled at a bounded discard limit',
        () async {
      final file = _syntheticPngFile('zhipu-ocr-hostile-error');
      addTearDown(() => file.deleteSync());
      final hostileBody = StreamController<List<int>>();
      addTearDown(hostileBody.close);
      var bodyCancelled = false;
      hostileBody.onCancel = () => bodyCancelled = true;
      final client = ZhipuOcrClient(
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode(
              _cropResponse(
                count: 1,
                url: 'https://cdn.example.com/hostile-error.png',
              ),
            ),
            200,
          );
        }),
        remoteCropClientFactory: (_, __) => _StreamedCropClient(() {
          hostileBody.add(
            List<int>.filled(
              ZhipuOcrClient.maxRemoteResponseDiscardBytes + 1,
              0,
            ),
          );
          return http.StreamedResponse(hostileBody.stream, 500);
        }),
        dnsResolver: (_) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
        ],
        remoteCropCountLimit: 1,
        remoteCropTotalBytesLimit: _validCropPng.length,
      );

      final document = await client.parseFile(
        profile: profile,
        filePath: file.path,
        sourceName: 'fixture.png',
      );

      expect(document.flattenedBlocks.single.imagePayload, isNull);
      expect(document.flattenedBlocks.single.text, '[图片]');
      expect(bodyCancelled, isTrue);
    });

    test(
        'remote crop address policy rejects private IPv6 and accepts public IPv6',
        () async {
      final file = _syntheticPngFile('zhipu-ocr-ipv6-policy');
      addTearDown(() => file.deleteSync());
      const cases = <String, bool>{
        '::': false,
        '::1': false,
        'fc00::1': false,
        'fd12::1': false,
        'fe80::1': false,
        'ff02::1': false,
        '2001:db8::1': false,
        '::ffff:127.0.0.1': false,
        '::ffff:10.0.0.1': false,
        '::ffff:172.16.0.1': false,
        '::ffff:192.168.0.1': false,
        '2001:4860:4860::8888': true,
      };

      for (final entry in cases.entries) {
        var cropGetCalls = 0;
        final client = ZhipuOcrClient(
          httpClient: MockClient((request) async {
            if (request.method == 'GET') {
              cropGetCalls++;
              return http.Response.bytes(
                _validCropPng,
                200,
                headers: const <String, String>{
                  'content-type': 'image/png',
                },
              );
            }
            return http.Response(
              jsonEncode(_cropResponse(count: 1)),
              200,
            );
          }),
          dnsResolver: (_) async => <InternetAddress>[
            InternetAddress(entry.key),
          ],
          remoteCropCountLimit: 1,
          remoteCropTotalBytesLimit: _validCropPng.length,
        );

        final document = await client.parseFile(
          profile: profile,
          filePath: file.path,
          sourceName: 'fixture.png',
        );
        expect(
          document.flattenedBlocks.single.imagePayload != null,
          entry.value,
          reason: 'unexpected remote crop policy for ${entry.key}',
        );
        expect(cropGetCalls, entry.value ? 1 : 0);
      }
    });

    test('remote crop binds the approved DNS address to its transport',
        () async {
      final file = _syntheticPngFile('zhipu-ocr-dns-binding');
      addTearDown(() => file.deleteSync());
      final approved = InternetAddress('93.184.216.34');
      var dnsCalls = 0;
      final boundAddresses = <InternetAddress>[];
      final remoteTransport = MockClient((request) async {
        return http.Response.bytes(
          _validCropPng,
          200,
          headers: const <String, String>{'content-type': 'image/png'},
        );
      });
      final client = ZhipuOcrClient(
        httpClient: MockClient((request) async {
          return http.Response(jsonEncode(_cropResponse(count: 1)), 200);
        }),
        remoteCropClientFactory: (uri, address) {
          boundAddresses.add(address);
          return remoteTransport;
        },
        dnsResolver: (_) async {
          dnsCalls++;
          // A second lookup would hypothetically rebind to loopback. The
          // client must perform one lookup and pass that approved address to
          // the transport instead of resolving the hostname again.
          return <InternetAddress>[
            dnsCalls == 1 ? approved : InternetAddress('127.0.0.1'),
          ];
        },
        remoteCropCountLimit: 1,
        remoteCropTotalBytesLimit: _validCropPng.length,
      );

      final document = await client.parseFile(
        profile: profile,
        filePath: file.path,
        sourceName: 'fixture.png',
      );

      expect(document.flattenedBlocks.single.imagePayload, isNotNull);
      expect(dnsCalls, 1);
      expect(boundAddresses, <InternetAddress>[approved]);
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

      test('remote crop budgets remain shared across PDF chunks', () async {
        final pdfFile = createSyntheticPdf(2);
        addTearDown(() => pdfFile.deleteSync());

        Future<OcrDocument> parse({
          required int countLimit,
          required int byteLimit,
        }) {
          var cropGetCalls = 0;
          final client = ZhipuOcrClient(
            pdfPageChunkSize: 1,
            httpClient: MockClient((request) async {
              if (request.method == 'GET') {
                cropGetCalls++;
                return http.Response.bytes(
                  _validCropPng,
                  200,
                  headers: const <String, String>{
                    'content-type': 'image/png',
                  },
                );
              }
              return http.Response(
                jsonEncode(_cropResponse(count: 1)),
                200,
              );
            }),
            dnsResolver: (_) async => <InternetAddress>[
              InternetAddress('93.184.216.34'),
            ],
            remoteCropCountLimit: countLimit,
            remoteCropTotalBytesLimit: byteLimit,
          );
          return client
              .parseFile(
            profile: profile,
            filePath: pdfFile.path,
            sourceName: 'two-page.pdf',
          )
              .whenComplete(() {
            expect(cropGetCalls, greaterThanOrEqualTo(1));
          });
        }

        await expectLater(
          parse(
            countLimit: 1,
            byteLimit: _validCropPng.length * 2,
          ),
          throwsA(isA<ZhipuOcrResponseFormatException>()),
        );
        await expectLater(
          parse(
            countLimit: 2,
            byteLimit: _validCropPng.length,
          ),
          throwsA(isA<ZhipuOcrResponseFormatException>()),
        );
      });

      test('inline image budget remains shared across PDF chunks', () async {
        final pdfFile = createSyntheticPdf(2);
        addTearDown(() => pdfFile.deleteSync());
        final inlineDataUrl = _inlineImageDataUrl();
        var requests = 0;
        final client = ZhipuOcrClient(
          pdfPageChunkSize: 1,
          httpClient: MockClient((request) async {
            requests++;
            return http.Response(
              jsonEncode(_cropResponse(count: 1, url: inlineDataUrl)),
              200,
            );
          }),
          remoteCropCountLimit: 2,
          remoteCropTotalBytesLimit: _validCropPng.length,
        );

        await expectLater(
          client.parseFile(
            profile: profile,
            filePath: pdfFile.path,
            sourceName: 'two-page-inline.pdf',
          ),
          throwsA(isA<ZhipuOcrResponseFormatException>()),
        );
        expect(requests, 2);
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

  group('MIME resolution fallback (F1-I2)', () {
    http.Response okResponse() {
      return http.Response(
        jsonEncode(<String, Object?>{
          'md_results': 'ok',
          'layout_details': <Object?>[],
          'data_info': <String, Object?>{},
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }

    test('extensionless managed path resolves image MIME from sourceName',
        () async {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'extless_${DateTime.now().microsecondsSinceEpoch}',
      )..writeAsBytesSync(const [1]);
      addTearDown(() => file.deleteSync());
      http.Request? captured;
      final client = ZhipuOcrClient(
        httpClient: MockClient((request) async {
          captured = request;
          return okResponse();
        }),
      );

      final document = await client.parseFile(
        profile: profile,
        filePath: file.path,
        sourceName: 'artifact-1.png',
      );

      expect(document.markdown, 'ok');
      expect(captured, isNotNull);
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['file'], startsWith('data:image/png;base64,'));
    });

    test('extensionless managed path resolves PDF MIME from sourceName',
        () async {
      final pdf = PdfDocument();
      pdf.pages.add();
      final pdfBytes = pdf.saveSync();
      pdf.dispose();
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'extless_pdf_${DateTime.now().microsecondsSinceEpoch}',
      )..writeAsBytesSync(pdfBytes);
      addTearDown(() => file.deleteSync());
      http.Request? captured;
      final client = ZhipuOcrClient(
        httpClient: MockClient((request) async {
          captured = request;
          return okResponse();
        }),
      );

      final document = await client.parseFile(
        profile: profile,
        filePath: file.path,
        sourceName: 'artifact-1.pdf',
      );

      expect(document.markdown, 'ok');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['file'], startsWith('data:application/pdf;base64,'));
    });

    test('physical filePath extension takes precedence over sourceName',
        () async {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'precedence_${DateTime.now().microsecondsSinceEpoch}.png',
      )..writeAsBytesSync(const [1]);
      addTearDown(() => file.deleteSync());
      http.Request? captured;
      final client = ZhipuOcrClient(
        httpClient: MockClient((request) async {
          captured = request;
          return okResponse();
        }),
      );

      await client.parseFile(
        profile: profile,
        filePath: file.path,
        sourceName: 'artifact-1.pdf',
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['file'], startsWith('data:image/png;base64,'));
    });

    test('both filePath and sourceName unrecognized throw ArgumentError',
        () async {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'noext_${DateTime.now().microsecondsSinceEpoch}',
      )..writeAsBytesSync(const [1]);
      addTearDown(() => file.deleteSync());
      final client = ZhipuOcrClient(
        httpClient: MockClient((_) async => okResponse()),
      );

      await expectLater(
        client.parseFile(
          profile: profile,
          filePath: file.path,
          sourceName: 'no-extension-either',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

final class _StreamedCropClient extends http.BaseClient {
  _StreamedCropClient(this._responseFactory);

  final http.StreamedResponse Function() _responseFactory;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return _responseFactory();
  }

  @override
  void close() {}
}

final class _ThrowingCropClient extends http.BaseClient {
  _ThrowingCropClient(this._error);

  final Object _error;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Future<http.StreamedResponse>.error(_error);
  }

  @override
  void close() {}
}
