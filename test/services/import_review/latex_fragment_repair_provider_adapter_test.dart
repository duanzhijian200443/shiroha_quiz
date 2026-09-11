import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiroha_quiz/application/import_review/latex_fragment_repair.dart';
import 'package:shiroha_quiz/application/import_review/latex_fragment_repair_provider.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_review/latex_fragment_repair_provider_adapter.dart';

import '../../support/unsupported_ai_engine_store.dart';

const _secret = 'SENTINEL_SECRET_KEY';
const _fragment = r'\begin{matrix}1';
const _reasoning = 'SENTINEL_REASONING_BODY';
const _corrected = r'\begin{matrix}1\end{matrix}';

class _FakeEngineRepository extends AiEngineRepository {
  _FakeEngineRepository(this.profile)
      : super(
          store: const UnsupportedAiEngineStore(),
          credentialStore: const UnsupportedEngineCredentialStore(),
        );

  final AiEngineProfile? profile;

  @override
  Future<AiEngineProfile?> getActiveTextEngine() async => profile;
}

class _MemoryLogSink implements LogSink {
  final records = <LogRecord>[];

  @override
  Future<void> write(LogRecord record) async => records.add(record);

  @override
  Future<void> flush() async {}
}

AiEngineProfile _profile({
  String baseUrl = 'https://provider.invalid/v1',
}) {
  return AiEngineProfile(
    id: 'engine_1',
    engineType: AiEngineType.text,
    name: 'test',
    apiKey: _secret,
    baseUrl: baseUrl,
    modelName: 'model-safe-id',
    temperature: 0.8,
    reasoningEffort: '',
    isActive: true,
  );
}

LatexFragmentProviderRequest _request({String original = _fragment}) {
  return LatexFragmentProviderRequest(
    nodeKind: LatexFragmentNodeKind.inlineMath,
    originalLatex: original,
    precedingContext: '前文哨兵',
    followingContext: '后文哨兵',
  );
}

LatexFragmentRepairProviderAdapter _adapter({
  required http.Client client,
  AiEngineProfile? profile,
  int maxRawResponseBytes = 64 * 1024,
}) {
  return LatexFragmentRepairProviderAdapter(
    engineRepository: _FakeEngineRepository(profile ?? _profile()),
    httpClient: client,
    maxRawResponseBytes: maxRawResponseBytes,
  );
}

Matcher _failsAs(LatexFragmentProviderFailure failure) {
  return throwsA(
    isA<LatexFragmentProviderException>()
        .having((error) => error.failure, 'failure', failure),
  );
}

void main() {
  tearDown(() {
    AppLogger.setSink(null);
  });

  test('chat content succeeds with one bounded non-JSON fragment request',
      () async {
    late Map<String, dynamic> body;
    final client = MockClient((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'finish_reason': 'stop',
              'message': <String, Object?>{'content': _corrected},
            },
          ],
        }),
        200,
      );
    });

    final result = await _adapter(client: client).repair(_request());

    expect(result.correctedLatex, _corrected);
    expect(result.providerProfileId, 'engine_1');
    expect(body['max_tokens'], 1024);
    expect(body['temperature'], 0);
    expect(body.containsKey('response_format'), isFalse);
    final serialized = jsonEncode(body);
    expect(serialized, contains(_fragment));
    expect(serialized, contains('前文哨兵'));
    expect(serialized, contains('后文哨兵'));
  });

  test('Gemini final text succeeds and thought text is never selected',
      () async {
    final client = MockClient((request) async {
      expect(request.url.queryParameters['key'], _secret);
      return http.Response(
        jsonEncode(<String, Object?>{
          'candidates': <Object?>[
            <String, Object?>{
              'finishReason': 'STOP',
              'content': <String, Object?>{
                'parts': <Object?>[
                  <String, Object?>{'thought': true, 'text': _reasoning},
                  <String, Object?>{'text': _corrected},
                ],
              },
            },
          ],
        }),
        200,
      );
    });

    final result = await _adapter(
      client: client,
      profile: _profile(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      ),
    ).repair(_request());

    expect(result.correctedLatex, _corrected);
    expect(result.correctedLatex, isNot(contains(_reasoning)));
  });

  test('Zhipu uses the chat-completions envelope without JSON mode', () async {
    final client = MockClient((request) async {
      expect(request.url.path, endsWith('/v4/chat/completions'));
      expect(request.headers['Authorization'], 'Bearer $_secret');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body.containsKey('response_format'), isFalse);
      return http.Response(
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'finish_reason': 'stop',
              'message': <String, Object?>{'content': _corrected},
            },
          ],
        }),
        200,
      );
    });

    final result = await _adapter(
      client: client,
      profile: _profile(
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      ),
    ).repair(_request());

    expect(result.correctedLatex, _corrected);
  });

  test('reasoning-only, empty, length and malformed envelopes are typed',
      () async {
    Future<void> verify(
      String body,
      LatexFragmentProviderFailure failure,
    ) async {
      final client = MockClient((_) async => http.Response(body, 200));
      await expectLater(
        _adapter(client: client).repair(_request()),
        _failsAs(failure),
      );
    }

    await verify(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'finish_reason': 'stop',
            'message': <String, Object?>{
              'content': '',
              'reasoning_content': _reasoning,
            },
          },
        ],
      }),
      LatexFragmentProviderFailure.providerReasoningOnly,
    );
    await verify(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'finish_reason': 'stop',
            'message': <String, Object?>{'content': ''},
          },
        ],
      }),
      LatexFragmentProviderFailure.providerEmptyContent,
    );
    await verify(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'finish_reason': 'length',
            'message': <String, Object?>{'content': _corrected},
          },
        ],
      }),
      LatexFragmentProviderFailure.providerFinishLength,
    );
    await verify(
      '{"choices":"invalid"}',
      LatexFragmentProviderFailure.providerInvalidEnvelope,
    );
    await verify(
      'not-json',
      LatexFragmentProviderFailure.providerInvalidEnvelope,
    );
  });

  test('rejects Markdown fences, outer delimiters and oversized output',
      () async {
    Future<void> verify(String output, {String original = _fragment}) async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'finish_reason': 'stop',
                'message': <String, Object?>{'content': output},
              },
            ],
          }),
          200,
        ),
      );
      await expectLater(
        _adapter(client: client).repair(_request(original: original)),
        _failsAs(LatexFragmentProviderFailure.providerOutputInvalid),
      );
    }

    final fence = String.fromCharCode(96) * 3;
    await verify('$fence latex\n$_corrected\n$fence');
    await verify(r'\(' + _corrected + r'\)');
    await verify('x' * 300, original: 'x');
  });

  test('bounded transport rejects an oversized raw response', () async {
    final client = MockClient((_) async => http.Response('x' * 200, 200));

    await expectLater(
      _adapter(client: client, maxRawResponseBytes: 64).repair(_request()),
      _failsAs(LatexFragmentProviderFailure.providerInvalidEnvelope),
    );
  });

  test('HTTP status failures are typed without reading the body', () async {
    final client = MockClient(
      (_) async => http.Response('SENTINEL_RAW_ERROR_BODY', 429),
    );

    await expectLater(
      _adapter(client: client).repair(_request()),
      _failsAs(LatexFragmentProviderFailure.providerRateLimited),
    );
  });

  test('diagnostics contain shape only and no request or response text',
      () async {
    final sink = _MemoryLogSink();
    AppLogger.setSink(sink);
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'finish_reason': 'stop',
              'message': <String, Object?>{
                'content': '',
                'reasoning_content': _reasoning,
              },
            },
          ],
        }),
        200,
      ),
    );

    await expectLater(
      _adapter(client: client).repair(_request()),
      _failsAs(LatexFragmentProviderFailure.providerReasoningOnly),
    );
    await AppLogger.flush();

    final logs =
        jsonEncode(sink.records.map((record) => record.toJson()).toList());
    expect(logs, contains('provider_reasoning_only'));
    expect(logs, contains('"httpStatus":200'));
    expect(logs, isNot(contains(_secret)));
    expect(logs, isNot(contains(_fragment)));
    expect(logs, isNot(contains(_reasoning)));
    expect(logs, isNot(contains(_corrected)));
    expect(logs, isNot(contains('前文哨兵')));
    expect(logs, isNot(contains('后文哨兵')));
  });
}
