import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/services/structured_question_merge_service.dart';

void main() {
  const profile = AiEngineProfile(
    id: 'test-engine',
    engineType: AiEngineType.text,
    name: 'Test engine',
    apiKey: 'SECRET_API_KEY',
    baseUrl: 'https://example.invalid/v1',
    modelName: 'test-model',
    temperature: 0.1,
    reasoningEffort: '',
    isActive: true,
  );

  final fileResults = <List<Map<String, dynamic>>>[
    <Map<String, dynamic>>[
      <String, dynamic>{
        'q_num': '1',
        'content': 'PRIVATE_QUESTION_BODY',
        'options': <String>['A', 'B'],
      },
    ],
    <Map<String, dynamic>>[
      <String, dynamic>{
        'q_num': '1',
        'standard_answer': 'PRIVATE_ANSWER_BODY',
      },
    ],
  ];

  StructuredQuestionMergeService serviceFor({
    Future<AiEngineProfile?> Function()? loadProfile,
    Future<String> Function(AiEngineProfile profile, String prompt)? request,
    Future<List<Map<String, dynamic>>> Function(String responseText)?
        parseResponse,
    String response =
        '{"questions":[{"q_num":"1","type":3,"content":"Merged stem","options":[],"standard_answer":"A","explanation":"Merged explanation"}]}',
  }) {
    return StructuredQuestionMergeService.forTesting(
      loadProfile: loadProfile ?? () async => profile,
      request: request ?? (_, __) async => response,
      parseResponse: parseResponse,
    );
  }

  Future<StructuredQuestionMergeException> captureFailure(
    Future<List<Map<String, dynamic>>> future,
  ) async {
    try {
      await future;
      fail('Expected StructuredQuestionMergeException.');
    } on StructuredQuestionMergeException catch (error) {
      return error;
    }
  }

  test('returns parsed questions for a complete legal JSON response', () async {
    final result = await serviceFor().merge(fileResults);

    expect(result, hasLength(1));
    expect(result.single['q_num'], '1');
    expect(result.single['content'], 'Merged stem');
    expect(result.single['standard_answer'], 'A');
  });

  test('preserves the one-file success fast path without loading AI', () async {
    var profileLoadCount = 0;
    var requestCount = 0;
    final singleFile = fileResults.first;
    final service = serviceFor(
      loadProfile: () async {
        profileLoadCount++;
        return profile;
      },
      request: (_, __) async {
        requestCount++;
        return '{}';
      },
    );

    final result =
        await service.merge(<List<Map<String, dynamic>>>[singleFile]);

    expect(identical(result, singleFile), isTrue);
    expect(profileLoadCount, 0);
    expect(requestCount, 0);
  });

  test('classifies a literal ellipsis response as invalidJson safely',
      () async {
    const rawResponse =
        '[{"q_num":"1","content":"PRIVATE_MODEL_STEM","standard_answer":"PRIVATE_MODEL_ANSWER"}, ...]';

    final error = await captureFailure(
      serviceFor(response: rawResponse).merge(fileResults),
    );

    expect(error.type, StructuredQuestionMergeFailureType.invalidJson);
    expect(error.causeType, isNotEmpty);
    expect(error.toString(), isNot(contains(rawResponse)));
    expect(error.toString(), isNot(contains('PRIVATE_MODEL_STEM')));
    expect(error.toString(), isNot(contains('PRIVATE_MODEL_ANSWER')));
  });

  test('catches an asynchronously thrown parser FormatException', () async {
    final service = serviceFor(
      parseResponse: (_) async {
        await Future<void>.delayed(Duration.zero);
        throw const FormatException('PRIVATE_PARSE_DETAILS');
      },
    );

    final error = await captureFailure(service.merge(fileResults));

    expect(error.type, StructuredQuestionMergeFailureType.invalidJson);
    expect(error.causeType, 'FormatException');
    expect(error.toString(), isNot(contains('PRIVATE_PARSE_DETAILS')));
  });

  test('classifies ordinary malformed and truncated JSON as invalidJson',
      () async {
    for (final response in <String>[
      'not JSON at all',
      '{"questions":[{"q_num":"1"}',
      '{"questions":[{"q_num":"1"}, INVALID]}',
    ]) {
      final error = await captureFailure(
        serviceFor(response: response).merge(fileResults),
      );
      expect(
        error.type,
        StructuredQuestionMergeFailureType.invalidJson,
        reason: response,
      );
      expect(error.toString(), isNot(contains(response)));
    }
  });

  test('classifies an empty response as emptyResponse', () async {
    final error = await captureFailure(
      serviceFor(response: '').merge(fileResults),
    );

    expect(error.type, StructuredQuestionMergeFailureType.emptyResponse);
  });

  test('classifies a whitespace-only response as emptyResponse', () async {
    final error = await captureFailure(
      serviceFor(response: ' \r\n\t ').merge(fileResults),
    );

    expect(error.type, StructuredQuestionMergeFailureType.emptyResponse);
  });

  test('classifies request timeout without exposing its message', () async {
    final error = await captureFailure(
      serviceFor(
        request: (_, __) async =>
            throw TimeoutException('PRIVATE_TIMEOUT_DETAILS'),
      ).merge(fileResults),
    );

    expect(error.type, StructuredQuestionMergeFailureType.timeout);
    expect(error.causeType, 'TimeoutException');
    expect(error.toString(), isNot(contains('PRIVATE_TIMEOUT_DETAILS')));
  });

  test('classifies parser timeout', () async {
    final error = await captureFailure(
      serviceFor(
        parseResponse: (_) async =>
            throw TimeoutException('PRIVATE_PARSE_TIMEOUT'),
      ).merge(fileResults),
    );

    expect(error.type, StructuredQuestionMergeFailureType.timeout);
    expect(error.toString(), isNot(contains('PRIVATE_PARSE_TIMEOUT')));
  });

  test('classifies provider 429 conservatively without exposing body',
      () async {
    final error = await captureFailure(
      serviceFor(
        request: (_, __) async =>
            throw Exception('API Error: 429 - PRIVATE_RESPONSE_BODY'),
      ).merge(fileResults),
    );

    expect(error.type, StructuredQuestionMergeFailureType.rateLimited);
    expect(error.toString(), isNot(contains('PRIVATE_RESPONSE_BODY')));
  });

  test('classifies typed socket failures as network', () async {
    final error = await captureFailure(
      serviceFor(
        request: (_, __) async =>
            throw const SocketException('PRIVATE_NETWORK_DETAILS'),
      ).merge(fileResults),
    );

    expect(error.type, StructuredQuestionMergeFailureType.network);
    expect(error.causeType, 'SocketException');
    expect(error.toString(), isNot(contains('PRIVATE_NETWORK_DETAILS')));
  });

  test('classifies a missing AI engine as notConfigured', () async {
    var requestCount = 0;
    final error = await captureFailure(
      serviceFor(
        loadProfile: () async => null,
        request: (_, __) async {
          requestCount++;
          return '{}';
        },
      ).merge(fileResults),
    );

    expect(error.type, StructuredQuestionMergeFailureType.notConfigured);
    expect(error.causeType, isNull);
    expect(requestCount, 0);
  });

  test('classifies unknown failures without retaining private error text',
      () async {
    final error = await captureFailure(
      serviceFor(
        request: (_, __) async => throw StateError(
          'PRIVATE_QUESTION_BODY PRIVATE_ANSWER_BODY SECRET_API_KEY '
          'Authorization: Bearer TOKEN data:image/png;base64,AAAA',
        ),
      ).merge(fileResults),
    );

    expect(error.type, StructuredQuestionMergeFailureType.unknown);
    expect(error.causeType, 'StateError');
    final safeText = error.toString();
    for (final sensitiveValue in <String>[
      'PRIVATE_QUESTION_BODY',
      'PRIVATE_ANSWER_BODY',
      'SECRET_API_KEY',
      'Authorization',
      'Bearer TOKEN',
      'base64',
      'AAAA',
    ]) {
      expect(safeText, isNot(contains(sensitiveValue)));
    }
  });

  test('does not create a real HTTP client when using the test injection',
      () async {
    var httpClientCreationCount = 0;
    var injectedRequestCount = 0;

    await HttpOverrides.runZoned(
      () async {
        final result = await serviceFor(
          request: (_, __) async {
            injectedRequestCount++;
            return '{"questions":[{"q_num":"1","type":3,"content":"Merged stem","options":[],"standard_answer":"A","explanation":""}]}';
          },
        ).merge(fileResults);
        expect(result, hasLength(1));
      },
      createHttpClient: (context) {
        httpClientCreationCount++;
        return HttpClient(context: context);
      },
    );

    expect(injectedRequestCount, 1);
    expect(httpClientCreationCount, 0);
  });
}
