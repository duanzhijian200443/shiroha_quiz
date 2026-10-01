// P7-D1 bounded AI answer provider adapter acceptance.
//
// All HTTP is deterministic via package:http/testing. No live provider, real
// credential, OCR, MCP, or network path is touched. Sentinel strings are
// fictional and never real secrets.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/core/observability/log_writer.dart';
import 'package:shiroha_quiz/core/observability/trace_context.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/answers/ai_answer_provider_adapter.dart';

const _apiKey = 'SENTINEL_API_KEY_9f8e7d';
const _openAiBase = 'https://api.openai.com/v1';
const _zhipuBase = 'https://api.bigmodel.cn';
const _geminiBase = 'https://generativelanguage.googleapis.com';

void main() {
  group('redacted completion telemetry', () {
    late List<LogRecord> records;
    setUp(() {
      records = [];
      LogWriter.setRecordHandler((record) {
        if (record.message == 'ai_answer_provider_completed') {
          records.add(record);
        }
      });
    });
    tearDown(() => LogWriter.setRecordHandler(null));

    test('success reports native counters once without any private payload',
        () async {
      final envelope = _contentEnvelope([
        {'type': 'block_math', 'latex': r'\sqrt{SENTINEL_FINAL_ANSWER}'},
      ]);
      final adapter = _adapter(
        profile: _profile(
            baseUrl: 'https://SENTINEL_PRIVATE_HOST/v1',
            model: 'SENTINEL_PRIVATE_MODEL'),
        client: _recordingClient((request) async => http.Response(
            jsonEncode({
              'id': 'SENTINEL_PROVIDER_ID',
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {
                    'content': envelope,
                    'reasoning_content': 'SENTINEL_REASONING',
                  },
                }
              ],
              'usage': {
                'prompt_tokens': 352,
                'completion_tokens': 2048,
                'total_tokens': 2400,
                'completion_tokens_details': {'reasoning_tokens': 1800},
                'private_extra': 'SENTINEL_USAGE_EXTRA',
              },
            }),
            200)),
      );
      final result = await adapter.generateAnswer(AiAnswerProviderRequest(
          kind: QuestionKind.shortAnswer,
          stem: _safeText('SENTINEL_PRIVATE_QUESTION')));
      expect(result.answer, isA<ContentAnswer>());
      final data = records.single.data;
      expect(data['status'], 'success');
      expect(data['stage'], 'complete');
      expect(data['failure'], isNull);
      expect(data['questionKind'], 'shortAnswer');
      expect(data['requestedMaxOutputTokens'], 2048);
      expect(data['httpStatus'], 200);
      expect(data['finishReason'], 'stop');
      expect(data['promptTokens'], 352);
      expect(data['completionTokens'], 2048);
      expect(data['reasoningTokens'], 1800);
      expect(data['totalTokens'], 2400);
      expect(data['rawResponseBytes'], greaterThan(0));
      expect(data['finalContentState'], 'text');
      expect(data['finalContentScalars'], envelope.runes.length);
      expect(data['requestId'], matches(r'^trace-[0-9]+-[0-9a-f]+$'));
      expect(jsonEncode(records.single.toJson()), isNot(contains('SENTINEL')));
      expect(jsonEncode(records.single.toJson()), isNot(contains(_apiKey)));
    });

    for (final entry in <(Object?, String, String)>[
      (null, 'finalContent', 'null'),
      ('{"schema_version":1,"answer":', 'answerJson', 'text'),
    ]) {
      test('length termination retains original failure at ${entry.$2}',
          () async {
        final adapter = _adapter(
          client: _recordingClient((request) async =>
              _telemetryChat(content: entry.$1, finishReason: 'length', usage: {
                'completion_tokens': 2048,
                'completion_tokens_details': {'reasoning_tokens': 2048},
              })),
        );
        await expectLater(adapter.generateAnswer(_contentRequest()),
            throwsA(_failure(AiAnswerProviderFailure.malformedProviderOutput)));
        final data = records.single.data;
        expect(data['status'], 'failed');
        expect(data['failure'], 'malformedProviderOutput');
        expect(data['stage'], entry.$2);
        expect(data['finishReason'], 'length');
        expect(data['completionTokens'], 2048);
        expect(data['finalContentState'], entry.$3);
      });
    }

    for (final entry in <(String, String, AiAnswerProviderFailure)>[
      ('{}', 'schema', AiAnswerProviderFailure.malformedProviderOutput),
      (
        _contentEnvelope([]),
        'typedValidation',
        AiAnswerProviderFailure.validationFailed
      ),
    ]) {
      test('schema and typed failures remain distinct at ${entry.$2}',
          () async {
        final adapter = _adapter(
            client: _recordingClient(
                (request) async => _telemetryChat(content: entry.$1)));
        await expectLater(adapter.generateAnswer(_contentRequest()),
            throwsA(_failure(entry.$3)));
        expect(records.single.data['stage'], entry.$2);
        expect(records.single.data['failure'], entry.$3.name);
      });
    }

    test('untrusted metadata is bounded and cannot change a valid answer',
        () async {
      final adapter = _adapter(
          client: _recordingClient((request) async => _telemetryChat(
                  content: _contentEnvelope(),
                  finishReason: 'SENTINEL_FINISH_REASON',
                  usage: {
                    'prompt_tokens': 'SENTINEL_TOKEN_STRING',
                    'completion_tokens': -1,
                    'total_tokens': 0x80000000,
                    'completion_tokens_details': {'reasoning_tokens': 1.0},
                  })));
      expect((await adapter.generateAnswer(_contentRequest())).answer,
          isA<ContentAnswer>());
      final data = records.single.data;
      expect(data['finishReason'], 'other');
      for (final field in [
        'promptTokens',
        'completionTokens',
        'reasoningTokens',
        'totalTokens'
      ]) {
        expect(data[field], isNull);
      }
      expect(jsonEncode(records.single.toJson()), isNot(contains('SENTINEL')));
    });

    test('concurrent calls retain separate snapshots and inherited trace',
        () async {
      final gate = Completer<void>();
      var calls = 0;
      final adapter = _adapter(client: _recordingClient((request) async {
        final call = ++calls;
        await gate.future;
        return _telemetryChat(
            content: call == 1 ? null : _contentEnvelope(),
            finishReason: call == 1 ? 'length' : 'stop',
            usage: {'total_tokens': call == 1 ? 2400 : 2416});
      }));
      await TraceContext.run(
          traceId: 'trace-123-abcd',
          correlationId: 'OBS-ABCD-EFGH',
          action: () async {
            final failed = expectLater(
                adapter.generateAnswer(_contentRequest()),
                throwsA(
                    _failure(AiAnswerProviderFailure.malformedProviderOutput)));
            final success = adapter.generateAnswer(_contentRequest());
            gate.complete();
            await failed;
            expect((await success).answer, isA<ContentAnswer>());
          });
      expect(records, hasLength(2));
      expect(records.map((r) => r.data['requestId']).toSet(), hasLength(2));
      final failed = records.singleWhere((r) => r.data['status'] == 'failed');
      final success = records.singleWhere((r) => r.data['status'] == 'success');
      expect(failed.data['totalTokens'], 2400);
      expect(failed.data['finishReason'], 'length');
      expect(success.data['totalTokens'], 2416);
      expect(success.data['finishReason'], 'stop');
      for (final record in records) {
        expect(record.traceId, 'trace-123-abcd');
        expect(record.correlationId, 'OBS-ABCD-EFGH');
      }
    });

    for (final usage in <Object?>[
      null,
      ['SENTINEL_WRONG_METADATA']
    ]) {
      test('missing or wrong metadata stays unknown: ${usage.runtimeType}',
          () async {
        final adapter = _adapter(
            client: _recordingClient((request) async => _telemetryChat(
                content: _contentEnvelope(),
                finishReason: false,
                usage: usage)));
        expect((await adapter.generateAnswer(_contentRequest())).answer,
            isA<ContentAnswer>());
        expect(records.single.data['completionTokens'], isNull);
        expect(records.single.data['finishReason'], isNull);
      });
    }

    test('profile failure produces exactly one terminal record', () async {
      final adapter = _adapter(
          noEngine: true,
          client: _recordingClient((request) async {
            fail('unconfigured profile must not send');
          }));
      await expectLater(adapter.generateAnswer(_contentRequest()),
          throwsA(_failure(AiAnswerProviderFailure.providerUnconfigured)));
      expect(records.single.data['stage'], 'profile');
      expect(records.single.data['httpStatus'], isNull);
      expect(records.single.data['rawResponseBytes'], isNull);
    });

    test('non-200 response is discarded without inspecting or logging its body',
        () async {
      final adapter = _adapter(
          client: _recordingClient(
              (request) async => http.Response('SENTINEL_ERROR_BODY', 500)));
      await expectLater(adapter.generateAnswer(_contentRequest()),
          throwsA(_failure(AiAnswerProviderFailure.providerUnavailable)));
      expect(records.single.data['stage'], 'http');
      expect(records.single.data['httpStatus'], 500);
      expect(records.single.data['rawResponseBytes'], isNull);
      expect(records.single.data['finishReason'], isNull);
      expect(jsonEncode(records.single.toJson()), isNot(contains('SENTINEL')));
    });

    test('byte overflow reports only the count and preserves its failure',
        () async {
      final adapter = _adapter(
          client: _StreamedClient(
              statusCode: 200, chunks: [List<int>.filled(64 * 1024 + 1, 65)]));
      await expectLater(adapter.generateAnswer(_contentRequest()),
          throwsA(_failure(AiAnswerProviderFailure.malformedProviderOutput)));
      expect(records.single.data['stage'], 'body');
      expect(records.single.data['rawResponseBytes'], 64 * 1024 + 1);
      expect(records.single.data['finishReason'], isNull);
      expect(records.single.data['completionTokens'], isNull);
    });

    test('Gemini observes native counters and never reads thought text',
        () async {
      final adapter = _adapter(
          profile: _profile(baseUrl: _geminiBase, model: 'gemini-x'),
          client: _recordingClient((request) async => http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'finishReason': 'MAX_TOKENS',
                    'content': {
                      'parts': [
                        {'thought': true, 'text': 'SENTINEL_GEMINI_THOUGHT'},
                        {'text': _contentEnvelope()},
                      ]
                    }
                  }
                ],
                'usageMetadata': {
                  'promptTokenCount': 80,
                  'candidatesTokenCount': 5,
                  'thoughtsTokenCount': 20,
                  'totalTokenCount': 105,
                }
              }),
              200)));
      expect((await adapter.generateAnswer(_contentRequest())).answer,
          isA<ContentAnswer>(),
          reason: 'finish metadata never changes decoding');
      final data = records.single.data;
      expect(data['finishReason'], 'length');
      expect(data['providerKind'], 'gemini');
      expect(data['completionTokens'], 5);
      expect(data['reasoningTokens'], 20);
      expect(data['totalTokens'], 105);
      expect(jsonEncode(records.single.toJson()), isNot(contains('SENTINEL')));
    });

    for (final succeeds in [true, false]) {
      test('throwing log observer cannot change outcome: $succeeds', () async {
        LogWriter.setRecordHandler(
            (_) => throw StateError('SENTINEL_LOG_ERROR'));
        final adapter = _adapter(
            client: _recordingClient((request) async =>
                _okChat(succeeds ? _contentEnvelope() : 'not JSON')));
        if (succeeds) {
          expect((await adapter.generateAnswer(_contentRequest())).answer,
              isA<ContentAnswer>());
        } else {
          await expectLater(
              adapter.generateAnswer(_contentRequest()),
              throwsA(
                  _failure(AiAnswerProviderFailure.malformedProviderOutput)));
        }
      });
    }
  });

  group('profile resolution', () {
    test('no active text engine is providerUnconfigured', () async {
      final adapter = _adapter(
        noEngine: true,
        client:
            _recordingClient((request) async => _okChat(_contentEnvelope())),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.providerUnconfigured)),
      );
    });

    test('missing credential makes the profile incomplete', () async {
      final adapter = _adapter(
        profile: _profile(),
        secret: null,
        client:
            _recordingClient((request) async => _okChat(_contentEnvelope())),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.providerUnconfigured)),
      );
    });

    test('incomplete profile (missing model) is providerUnconfigured',
        () async {
      final adapter = _adapter(
        profile: _profile(model: ''),
        client:
            _recordingClient((request) async => _okChat(_contentEnvelope())),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.providerUnconfigured)),
      );
    });

    test('credential store temporarily unavailable maps to providerUnavailable',
        () async {
      final adapter = _adapter(
        profile: _profile(),
        credentialError: const EngineCredentialException(
          EngineCredentialFailure.temporarilyUnavailable,
        ),
        client:
            _recordingClient((request) async => _okChat(_contentEnvelope())),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.providerUnavailable)),
      );
    });

    test('corrupt credential maps to internalError without raw cause',
        () async {
      final adapter = _adapter(
        profile: _profile(),
        credentialError: const EngineCredentialException(
          EngineCredentialFailure.dataCorrupt,
        ),
        client:
            _recordingClient((request) async => _okChat(_contentEnvelope())),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.internalError)),
      );
    });

    test('successful call carries the bounded engine id as provenance',
        () async {
      final client = _recordingClient(
        (request) async => _okChat(_choiceEnvelope()),
      );
      final adapter = _adapter(profile: _profile(), client: client);
      final result = await adapter.generateAnswer(_choiceRequest());
      expect(result.providerProfileId, 'engine_001');
      expect(result.answer, ChoiceAnswer(optionIds: ['opt_a']));
    });
  });

  group('malformed provider configuration', () {
    test('malformed base URL maps to typed internalError with no leak',
        () async {
      final adapter = _adapter(
        profile: _profile(baseUrl: 'https://SENTINEL_BAD_HOST['),
        client: _recordingClient(
          (request) async => _okChat(_contentEnvelope()),
        ),
      );
      try {
        await adapter.generateAnswer(_contentRequest());
        fail('expected a typed provider failure');
      } on AiAnswerProviderException catch (error) {
        expect(error.failure, AiAnswerProviderFailure.internalError);
        expect(error.toString(), isNot(contains('SENTINEL_BAD_HOST')));
        expect(error.toString(), isNot(contains(_apiKey)));
        expect(error.toString(), isNot(contains('FormatException')));
      }
    });

    test('Gemini malformed configuration never leaks URI or key', () async {
      final adapter = _adapter(
        profile: _profile(
          baseUrl: 'https://generativelanguage.googleapis.com[',
          model: 'gemini-x',
        ),
        client: _recordingClient(
          (request) async => _okChat(_contentEnvelope()),
        ),
      );
      try {
        await adapter.generateAnswer(_contentRequest());
        fail('expected a typed provider failure');
      } on AiAnswerProviderException catch (error) {
        expect(error.failure, AiAnswerProviderFailure.internalError);
        expect(error.toString(), isNot(contains('generativelanguage')));
        expect(error.toString(), isNot(contains(_apiKey)));
        expect(error.toString(), isNot(contains('FormatException')));
      }
    });
  });

  group('non-200 body handling', () {
    test('500 with over-64KiB chunked body maps boundedly with no leakage',
        () async {
      final client = _StreamedClient(
        statusCode: 500,
        chunks: [
          List<int>.filled(30 * 1024, 0x61),
          List<int>.filled(30 * 1024, 0x61),
          List<int>.filled(30 * 1024, 0x61),
        ],
      );
      final adapter = _adapter(client: client);
      try {
        await adapter
            .generateAnswer(_contentRequest())
            .timeout(const Duration(seconds: 5));
        fail('expected providerUnavailable');
      } on AiAnswerProviderException catch (error) {
        expect(error.failure, AiAnswerProviderFailure.providerUnavailable);
        expect(error.toString(), isNot(contains('a' * 64)));
      }
    });

    test('non-200 stream that never closes still maps promptly', () async {
      final client = _StreamedClient(statusCode: 503, neverClose: true);
      final adapter = _adapter(client: client);
      await expectLater(
        adapter
            .generateAnswer(_contentRequest())
            .timeout(const Duration(seconds: 5)),
        throwsA(_failure(AiAnswerProviderFailure.providerUnavailable)),
      );
    });
  });

  group('singleChoice output validation', () {
    test('valid one option maps to a one-ID ChoiceAnswer', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(_choiceEnvelope()),
        ),
      );
      final result = await adapter.generateAnswer(_choiceRequest());
      expect(result.answer, ChoiceAnswer(optionIds: ['opt_a']));
    });

    test('unknown option id is validationFailed', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(_choiceEnvelope('opt_unknown')),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_choiceRequest()),
        throwsA(_failure(AiAnswerProviderFailure.validationFailed)),
      );
    });

    test('empty option id is validationFailed', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(_choiceEnvelope('  ')),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_choiceRequest()),
        throwsA(_failure(AiAnswerProviderFailure.validationFailed)),
      );
    });

    test('option_ids multi-ID form is validationFailed', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(
            jsonEncode({
              'schema_version': 1,
              'answer': {
                'kind': 'choice',
                'option_ids': ['opt_a', 'opt_b'],
              },
            }),
          ),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_choiceRequest()),
        throwsA(_failure(AiAnswerProviderFailure.validationFailed)),
      );
    });

    test('option_id list form is validationFailed', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(
            jsonEncode({
              'schema_version': 1,
              'answer': {
                'kind': 'choice',
                'option_id': ['opt_a'],
              },
            }),
          ),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_choiceRequest()),
        throwsA(_failure(AiAnswerProviderFailure.validationFailed)),
      );
    });

    test('content answer for singleChoice is validationFailed', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(
            jsonEncode({
              'schema_version': 1,
              'answer': {
                'kind': 'content',
                'nodes': [
                  {'type': 'text', 'text': 'x'},
                ],
              },
            }),
          ),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_choiceRequest()),
        throwsA(_failure(AiAnswerProviderFailure.validationFailed)),
      );
    });
  });

  group('content output validation', () {
    test('valid text node decodes to ContentAnswer', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(_contentEnvelope()),
        ),
      );
      final result = await adapter.generateAnswer(_contentRequest());
      final answer = result.answer as ContentAnswer;
      expect(answer.content.nodes, hasLength(1));
      expect((answer.content.nodes.single as TextNode).text, 'x = 1');
    });

    test('inline and block math decode structurally', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(
            _contentEnvelope([
              {'type': 'inline_math', 'latex': r'\frac{1}{2}'},
              {'type': 'block_math', 'latex': r'\int_0^1 x\,dx'},
            ]),
          ),
        ),
      );
      final result = await adapter.generateAnswer(_contentRequest());
      final answer = result.answer as ContentAnswer;
      expect(answer.content.nodes, hasLength(2));
      expect(
        (answer.content.nodes[0] as InlineMathNode).latex,
        r'\frac{1}{2}',
      );
      expect(
        (answer.content.nodes[1] as BlockMathNode).latex,
        r'\int_0^1 x\,dx',
      );
    });

    test('mixed structural nodes keep order', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(
            _contentEnvelope([
              {'type': 'text', 'text': 'x = '},
              {'type': 'inline_math', 'latex': 'a^2'},
            ]),
          ),
        ),
      );
      final result = await adapter.generateAnswer(_contentRequest());
      final answer = result.answer as ContentAnswer;
      expect(answer.content.nodes, hasLength(2));
      expect((answer.content.nodes[0] as TextNode).text, 'x = ');
      expect(
        (answer.content.nodes[1] as InlineMathNode).latex,
        'a^2',
      );
    });

    test('empty nodes is validationFailed', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(_contentEnvelope([])),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.validationFailed)),
      );
    });

    test('whitespace-only text is validationFailed', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(
            _contentEnvelope([
              {'type': 'text', 'text': '   '},
            ]),
          ),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.validationFailed)),
      );
    });

    test('missing payload field is validationFailed', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(
            _contentEnvelope([
              {'type': 'text'},
            ]),
          ),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.validationFailed)),
      );
    });

    test('unsupported node type is validationFailed and never becomes fallback',
        () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(
            _contentEnvelope([
              {'type': 'raw', 'payload': 'secret'},
            ]),
          ),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.validationFailed)),
      );
    });

    test('over 64 nodes is validationFailed', () async {
      final nodes = <Map<String, dynamic>>[
        for (var index = 0; index < 65; index++)
          {'type': 'text', 'text': 'node $index'},
      ];
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(_contentEnvelope(nodes)),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.validationFailed)),
      );
    });

    test('over 8192 Unicode scalars is validationFailed', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(
            _contentEnvelope([
              {'type': 'text', 'text': 'a' * 8193},
            ]),
          ),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.validationFailed)),
      );
    });

    test('choice answer for fillBlank is validationFailed', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(_choiceEnvelope()),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest(kind: QuestionKind.fillBlank)),
        throwsA(_failure(AiAnswerProviderFailure.validationFailed)),
      );
    });
  });

  group('envelope contract', () {
    test('non-JSON provider body is malformedProviderOutput', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => http.Response('not json at all', 200),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.malformedProviderOutput)),
      );
    });

    test('non-JSON final content is malformedProviderOutput', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat('plain text answer'),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.malformedProviderOutput)),
      );
    });

    test('wrong schema_version is malformedProviderOutput', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(
            jsonEncode({
              'schema_version': 2,
              'answer': {
                'kind': 'content',
                'nodes': [
                  {'type': 'text', 'text': 'x'},
                ],
              },
            }),
          ),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.malformedProviderOutput)),
      );
    });

    test('missing answer key is malformedProviderOutput', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => _okChat(jsonEncode({'schema_version': 1})),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.malformedProviderOutput)),
      );
    });

    test('missing final provider content is malformedProviderOutput', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '  '}
                },
              ],
            }),
            200,
          ),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.malformedProviderOutput)),
      );
    });

    test('raw response over 64 KiB fails closed', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => http.Response('a' * (64 * 1024 + 1), 200),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.malformedProviderOutput)),
      );
    });
  });

  group('HTTP failure mapping', () {
    for (final entry in <(int, AiAnswerProviderFailure)>[
      (401, AiAnswerProviderFailure.providerAuthenticationFailed),
      (403, AiAnswerProviderFailure.providerAuthenticationFailed),
      (408, AiAnswerProviderFailure.providerTimeout),
      (504, AiAnswerProviderFailure.providerTimeout),
      (429, AiAnswerProviderFailure.providerRateLimited),
      (500, AiAnswerProviderFailure.providerUnavailable),
      (503, AiAnswerProviderFailure.providerUnavailable),
      (418, AiAnswerProviderFailure.providerRejected),
    ]) {
      test('HTTP ${entry.$1} maps to ${entry.$2.name}', () async {
        final adapter = _adapter(
          client: _recordingClient(
            (request) async =>
                http.Response('SENTINEL_PROVIDER_BODY', entry.$1),
          ),
        );
        await expectLater(
          adapter.generateAnswer(_contentRequest()),
          throwsA(_failure(entry.$2)),
        );
      });
    }

    test('provider error messages never contain the body or the key', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => http.Response('SENTINEL_PROVIDER_BODY', 401),
        ),
      );
      try {
        await adapter.generateAnswer(_contentRequest());
        fail('expected a typed provider failure');
      } on AiAnswerProviderException catch (error) {
        expect(error.toString(), isNot(contains('SENTINEL_PROVIDER_BODY')));
        expect(error.toString(), isNot(contains(_apiKey)));
        expect(error.toString(), isNot(contains('api.openai.com')));
      }
    });

    test('slow provider maps to providerTimeout', () async {
      final adapter = _adapter(
        requestTimeout: const Duration(milliseconds: 50),
        client: MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return _okChat(_contentEnvelope());
        }),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.providerTimeout)),
      );
    });

    test('network ClientException maps to providerUnavailable', () async {
      final adapter = _adapter(
        client: MockClient(
          (request) async =>
              throw http.ClientException('SENTINEL_NETWORK_DETAIL'),
        ),
      );
      try {
        await adapter.generateAnswer(_contentRequest());
        fail('expected a typed provider failure');
      } on AiAnswerProviderException catch (error) {
        expect(error.failure, AiAnswerProviderFailure.providerUnavailable);
        expect(error.toString(), isNot(contains('SENTINEL_NETWORK_DETAIL')));
      }
    });
  });

  group('reasoning privacy', () {
    test('reasoning_content is never decoded when content exists', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': _contentEnvelope(),
                    'reasoning_content': 'SENTINEL_REASONING_TRACE',
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );
      final result = await adapter.generateAnswer(_contentRequest());
      final answer = result.answer as ContentAnswer;
      expect(
        answer.content.nodes.map((node) => (node as TextNode).text).join(),
        'x = 1',
      );
      expect(
        result.toString(),
        isNot(contains('SENTINEL_REASONING_TRACE')),
      );
    });

    test('reasoning_content alone is never used as the answer', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'reasoning_content': _choiceEnvelope(),
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_choiceRequest()),
        throwsA(_failure(AiAnswerProviderFailure.malformedProviderOutput)),
      );
    });

    test('Gemini thought parts never become the answer', () async {
      final adapter = _adapter(
        profile: _profile(baseUrl: _geminiBase, model: 'gemini-x'),
        client: _recordingClient(
          (request) async => http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'thought': true, 'text': 'SENTINEL_THOUGHT'},
                      {'text': _contentEnvelope()},
                    ],
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );
      final result = await adapter.generateAnswer(_contentRequest());
      final answer = result.answer as ContentAnswer;
      expect(
        answer.content.nodes.map((node) => (node as TextNode).text).join(),
        'x = 1',
      );
      expect(
        result.toString(),
        isNot(contains('SENTINEL_THOUGHT')),
      );
    });

    test('Gemini thought-only output is malformedProviderOutput', () async {
      final adapter = _adapter(
        profile: _profile(baseUrl: _geminiBase, model: 'gemini-x'),
        client: _recordingClient(
          (request) async => http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'thought': true, 'text': _choiceEnvelope()},
                    ],
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );
      await expectLater(
        adapter.generateAnswer(_contentRequest()),
        throwsA(_failure(AiAnswerProviderFailure.malformedProviderOutput)),
      );
    });
  });

  group('provider kinds', () {
    test('OpenAI-compatible bounded fixture works', () async {
      final requests = <http.Request>[];
      final adapter = _adapter(
        profile: _profile(),
        client: _recordingClient((request) async {
          requests.add(request);
          return _okChat(_contentEnvelope());
        }),
      );
      final result = await adapter.generateAnswer(_contentRequest());
      expect(result.answer, isA<ContentAnswer>());
      expect(requests.single.url.toString(), '$_openAiBase/chat/completions');
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body['max_tokens'], 2048);
      expect(body['response_format'], {'type': 'json_object'});
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('Zhipu v4 fixture works', () async {
      final requests = <http.Request>[];
      final adapter = _adapter(
        profile: _profile(baseUrl: _zhipuBase, model: 'glm-x'),
        client: _recordingClient((request) async {
          requests.add(request);
          return _okChat(_contentEnvelope());
        }),
      );
      final result = await adapter.generateAnswer(_contentRequest());
      expect(result.answer, isA<ContentAnswer>());
      expect(
        requests.single.url.toString(),
        '$_zhipuBase/v4/chat/completions',
      );
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body['model'], 'glm-x');
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('Gemini generateContent fixture works with JSON MIME', () async {
      final requests = <http.Request>[];
      final adapter = _adapter(
        profile: _profile(baseUrl: _geminiBase, model: 'gemini-x'),
        client: _recordingClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': _contentEnvelope()},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      final result = await adapter.generateAnswer(_contentRequest());
      expect(result.answer, isA<ContentAnswer>());
      final url = requests.single.url.toString();
      expect(url, contains(':generateContent'));
      expect(url, contains('key=$_apiKey'));
      expect(requests.single.headers.containsKey('Authorization'), isFalse);
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      final config = body['generationConfig'] as Map<String, dynamic>;
      expect(config['responseMimeType'], 'application/json');
      expect(config['maxOutputTokens'], 2048);
    });
  });

  group('prompt privacy at the wire', () {
    test('outbound body contains only intended question content', () async {
      // Fixture draft whose excluded fields carry sentinel secrets; only the
      // safe stem/options are admitted into the provider request.
      const sentinelStorage = 'SENTINEL_STORAGE_ID';
      const sentinelBank = 'SENTINEL_BANK_NAME';
      const sentinelSource = 'SENTINEL_SOURCE_ID';
      const sentinelAsset = 'SENTINEL_ASSET_METADATA';
      const sentinelCurrentAnswer = 'SENTINEL_CURRENT_ANSWER';
      const sentinelPath = 'SENTINEL_FILE_PATH';
      const sentinelBase64 = 'SENTINEL_BASE64_BLOB';
      const sentinelExplanation = 'SENTINEL_EXPLANATION';

      // Everything a naive caller might know and would have to leave behind:
      // the request type structurally cannot carry any of it.
      final callerData = <String, String>{
        'storageId': sentinelStorage,
        'bankName': sentinelBank,
        'sourceId': sentinelSource,
        'assetMetadata': sentinelAsset,
        'currentAnswer': sentinelCurrentAnswer,
        'filePath': sentinelPath,
        'base64Blob': sentinelBase64,
        'explanation': sentinelExplanation,
      };

      final draft = QuestionDraftV2(
        questionId: 'q_$sentinelStorage',
        kind: QuestionKind.singleChoice,
        questionNumber: 1,
        stem: RichContent(nodes: const [TextNode('solve for x')]),
        sourceRefs: [
          SourceRef.document(sourceId: sentinelSource),
        ],
        options: [
          QuestionOption(
            optionId: 'opt_a',
            label: 'A',
            content: RichContent(nodes: const [TextNode('x = 1')]),
            sourceRef: SourceRef.document(sourceId: sentinelAsset),
          ),
          QuestionOption(
            optionId: 'opt_b',
            label: 'B',
            content: RichContent(nodes: const [TextNode('x = 2')]),
          ),
        ],
        answer: ContentAnswer(
          content: RichContent(nodes: [TextNode(sentinelCurrentAnswer)]),
        ),
      );
      final request = AiAnswerProviderRequest(
        kind: QuestionKind.singleChoice,
        stem: AiAnswerSafeContent.from(draft.stem),
        options: [
          for (final option in draft.options)
            AiAnswerSafeOption(
              optionId: option.optionId,
              label: option.label,
              content: AiAnswerSafeContent.from(option.content),
            ),
        ],
      );

      final requests = <http.Request>[];
      final adapter = _adapter(
        client: _recordingClient((request) async {
          requests.add(request);
          return _okChat(_choiceEnvelope());
        }),
      );
      await adapter.generateAnswer(request);

      final outbound = requests.single.body;
      for (final sentinel in callerData.values) {
        expect(
          outbound,
          isNot(contains(sentinel)),
          reason: 'sentinel $sentinel must never leave the app',
        );
      }
      expect(outbound, contains('solve for x'));
      expect(outbound, contains('opt_a'));
      expect(outbound, contains('opt_b'));
    });

    test('authorization secret never appears in results or errors', () async {
      final adapter = _adapter(
        client: _recordingClient(
          (request) async => http.Response('SENTINEL_BODY', 500),
        ),
      );
      try {
        await adapter.generateAnswer(_contentRequest());
        fail('expected a typed provider failure');
      } on AiAnswerProviderException catch (error) {
        expect(error.toString(), isNot(contains(_apiKey)));
      }
    });
  });
}

// --- fixtures and helpers ---

http.Response _telemetryChat({
  required Object? content,
  Object? finishReason = 'stop',
  Object? usage,
}) =>
    http.Response(
        jsonEncode({
          'choices': [
            {
              'finish_reason': finishReason,
              'message': {'content': content}
            }
          ],
          if (usage != null) 'usage': usage,
        }),
        200);

AiEngineProfile _profile({
  String baseUrl = _openAiBase,
  String model = 'gpt-x',
}) {
  return AiEngineProfile(
    id: 'engine_001',
    engineType: AiEngineType.text,
    name: 'fixture engine',
    apiKey: '', // scrubbed metadata; the secret comes from the credential store
    baseUrl: baseUrl,
    modelName: model,
    temperature: 0.2,
    reasoningEffort: '',
    isActive: true,
  );
}

class _FakeEngineStore implements AiEngineStore {
  _FakeEngineStore(this.profile);

  AiEngineProfile? profile;

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async =>
      profile;

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async =>
      profile == null ? const [] : <AiEngineProfile>[profile!];

  @override
  Future<void> deleteAiEngine(String id) async {}

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {}

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {}
}

class _FakeCredentialStore implements EngineCredentialStore {
  _FakeCredentialStore({this.secret = _apiKey, this.error});

  final String? secret;
  final EngineCredentialException? error;

  @override
  Future<String?> readCredential(String engineId) async {
    final failure = error;
    if (failure != null) throw failure;
    return secret;
  }

  @override
  Future<void> deleteCredential(String engineId) async {}

  @override
  Future<void> writeCredential(String engineId, String secret) async {}
}

MockClient _recordingClient(
  Future<http.Response> Function(http.Request request) handler,
) {
  return MockClient((request) => handler(request));
}

AiAnswerProviderAdapter _adapter({
  AiEngineProfile? profile,
  bool noEngine = false,
  String? secret = _apiKey,
  EngineCredentialException? credentialError,
  required http.Client client,
  Duration requestTimeout = const Duration(seconds: 120),
}) {
  final repository = AiEngineRepository(
    store: _FakeEngineStore(noEngine ? null : (profile ?? _profile())),
    credentialStore: _FakeCredentialStore(
      secret: secret,
      error: credentialError,
    ),
  );
  return AiAnswerProviderAdapter(
    engineRepository: repository,
    httpClient: client,
    requestTimeout: requestTimeout,
  );
}

/// Deterministic streamed-response client for bounded non-200 body tests.
///
/// Emits [chunks] (optionally never closing the stream) so the adapter's
/// cancellation path is exercised on real `StreamedResponse` objects instead
/// of buffered `MockClient` bodies.
class _StreamedClient extends http.BaseClient {
  _StreamedClient({
    required this.statusCode,
    this.chunks = const <List<int>>[],
    this.neverClose = false,
  });

  final int statusCode;
  final List<List<int>> chunks;
  final bool neverClose;
  final List<http.Request> requests = <http.Request>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request as http.Request);
    final controller = StreamController<List<int>>();
    for (final chunk in chunks) {
      controller.add(chunk);
    }
    if (!neverClose) {
      // Fire-and-forget: the close future only completes once a listener
      // consumes the done event; nobody must await it before the adapter
      // attaches its listener.
      unawaited(controller.close());
    }
    return http.StreamedResponse(controller.stream, statusCode);
  }
}

AiAnswerProviderRequest _choiceRequest() {
  return AiAnswerProviderRequest(
    kind: QuestionKind.singleChoice,
    stem: _safeText('solve for x'),
    options: [
      AiAnswerSafeOption(
        optionId: 'opt_a',
        label: 'A',
        content: _safeText('x = 1'),
      ),
      AiAnswerSafeOption(
        optionId: 'opt_b',
        label: 'B',
        content: _safeText('x = 2'),
      ),
    ],
  );
}

AiAnswerProviderRequest _contentRequest({
  QuestionKind kind = QuestionKind.shortAnswer,
}) {
  return AiAnswerProviderRequest(
    kind: kind,
    stem: _safeText('solve for x'),
  );
}

AiAnswerSafeContent _safeText(String text) {
  return AiAnswerSafeContent.from(RichContent(nodes: [TextNode(text)]));
}

http.Response _okChat(String content) {
  return http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {'content': content}
        },
      ],
    }),
    200,
  );
}

String _choiceEnvelope([String optionId = 'opt_a']) {
  return jsonEncode({
    'schema_version': 1,
    'answer': {'kind': 'choice', 'option_id': optionId},
  });
}

String _contentEnvelope([
  List<Map<String, dynamic>>? nodes,
]) {
  return jsonEncode({
    'schema_version': 1,
    'answer': {
      'kind': 'content',
      'nodes': nodes ??
          [
            {'type': 'text', 'text': 'x = 1'},
          ],
    },
  });
}

Matcher _failure(AiAnswerProviderFailure failure) {
  return isA<AiAnswerProviderException>().having(
    (error) => error.failure,
    'failure',
    failure,
  );
}
