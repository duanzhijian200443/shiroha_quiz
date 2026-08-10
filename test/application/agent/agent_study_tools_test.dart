import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_runtime_limits.dart';
import 'package:shiroha_quiz/application/agent/agent_study_tool_catalog.dart';
import 'package:shiroha_quiz/application/agent/agent_study_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/study_query/study_query_clock.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';

void main() {
  group('catalog', () {
    test('is exactly the MCP-v0 six-tool input surface', () {
      final definitions = AgentStudyToolCatalog.definitions;
      expect(definitions.map((definition) => definition.name), <String>[
        'list_question_banks',
        'get_study_overview',
        'get_due_review_summary',
        'search_questions',
        'get_question_detail',
        'get_weak_questions',
      ]);

      final schemas = <String, Map<String, Object?>>{
        for (final definition in definitions)
          definition.name: definition.inputSchema,
      };
      expect(_properties(schemas['list_question_banks']!), <String>{
        'cursor',
        'limit',
      });
      expect(
        _property(schemas['list_question_banks']!, 'limit'),
        containsPair('default', 50),
      );
      expect(_bounds(schemas['list_question_banks']!, 'limit'), (1, 100));
      expect(schemas['get_study_overview']!['required'], <String>['timezone']);
      expect(_properties(schemas['get_study_overview']!), <String>{
        'bank_name',
        'timezone',
      });
      expect(schemas['get_due_review_summary']!['required'], <String>[
        'from',
        'to',
      ]);
      expect(_properties(schemas['get_due_review_summary']!), <String>{
        'bank_name',
        'timezone',
        'from',
        'to',
      });
      expect(
        _property(schemas['get_due_review_summary']!, 'from')['pattern'],
        startsWith(r'^\d{4}-\d{2}-\d{2}T'),
      );
      expect(schemas['search_questions']!['required'], <String>[
        'bank_name',
        'query',
      ]);
      expect(_properties(schemas['search_questions']!), <String>{
        'bank_name',
        'query',
        'cursor',
        'limit',
      });
      expect(_bounds(schemas['search_questions']!, 'limit'), (1, 50));
      expect(
        _property(schemas['search_questions']!, 'query'),
        containsPair('maxLength', 200),
      );
      expect(schemas['get_question_detail']!['required'], <String>[
        'question_id',
      ]);
      expect(_properties(schemas['get_question_detail']!), <String>{
        'question_id',
      });
      expect(_properties(schemas['get_weak_questions']!), <String>{
        'bank_name',
        'cursor',
        'limit',
      });
      expect(_bounds(schemas['get_weak_questions']!, 'limit'), (1, 50));
      for (final schema in schemas.values) {
        expect(schema['type'], 'object');
        expect(schema.containsKey('additionalProperties'), isFalse);
      }
    });
  });

  group('dispatcher', () {
    test(
      'all six calls dispatch through StudyQueryService and stay safe',
      () async {
        final questions = _QuestionPort();
        final metrics = _MetricsPort();
        final dispatcher = _dispatcher(questions: questions, metrics: metrics);

        final calls = <(String, String)>[
          ('list_question_banks', '{}'),
          ('get_study_overview', '{"timezone":"UTC"}'),
          (
            'get_due_review_summary',
            '{"timezone":"UTC","from":"2026-08-09T00:00:00Z",'
                '"to":"2026-08-11T00:00:00Z"}',
          ),
          ('search_questions', '{"bank_name":"Synthetic","query":"safe"}'),
          ('get_question_detail', '{"question_id":"q1"}'),
          ('get_weak_questions', '{}'),
        ];

        for (final (name, arguments) in calls) {
          expect(
            _decode(await dispatcher.dispatch(name, arguments))['ok'],
            isTrue,
          );
        }
        expect(
          questions.calls,
          containsAll(<String>['banks', 'search', 'detail', 'weak']),
        );
        expect(
          metrics.calls,
          containsAll(<String>['overview', 'due_now', 'scheduled']),
        );

        final detail = _decode(
          await dispatcher.dispatch(
            'get_question_detail',
            '{"question_id":"q1"}',
          ),
        );
        final result = detail['result'] as Map<String, dynamic>;
        expect(result['stem'], <Object?>[
          <String, Object?>{'type': 'text', 'text': 'Safe stem'},
          <String, Object?>{'type': 'unsupported'},
        ]);
        expect(jsonEncode(detail), isNot(contains('private-marker')));
      },
    );

    test(
      'invalid JSON, types, bounds, and unknown names are deterministic',
      () async {
        final dispatcher = _dispatcher();
        final invalidCalls = <(String, String)>[
          ('list_question_banks', '{'),
          ('list_question_banks', '[]'),
          ('list_question_banks', '{"limit":"5"}'),
          ('list_question_banks', '{"limit":101}'),
          ('get_study_overview', '{"timezone":42}'),
          (
            'get_due_review_summary',
            '{"from":"2026-08-09 00:00:00Z",'
                '"to":"2026-08-11T00:00:00Z"}',
          ),
          (
            'search_questions',
            jsonEncode(<String, Object?>{
              'bank_name': 'Synthetic',
              'query': 'x' * 201,
            }),
          ),
          ('execute_sql', '{}'),
        ];

        for (final (name, arguments) in invalidCalls) {
          expect(
            _decode(await dispatcher.dispatch(name, arguments)),
            _failure('invalid_request', 'The request is invalid.', false),
          );
        }
      },
    );

    test('T0 failures are fixed and redacted', () async {
      final questions = _QuestionPort(
        failure: StudyQueryRepositoryFailure.corruptPayload,
      );
      final dispatcher = _dispatcher(questions: questions);
      final response = await dispatcher.dispatch(
        'get_question_detail',
        '{"question_id":"q1","path":"C:/private.db"}',
      );

      expect(
        _decode(response),
        _failure(
          'data_corrupt',
          'The stored data cannot be read safely.',
          false,
        ),
      );
      expect(response, isNot(contains('private.db')));
      expect(response, isNot(contains('private-marker')));
    });

    test(
      'argument and result UTF-8 limits fail without payload leakage',
      () async {
        final argumentLimited = _dispatcher(
          limits: const AgentRuntimeLimits(maxToolArgumentUtf8Bytes: 4),
        );
        expect(
          _decode(
            await argumentLimited.dispatch('list_question_banks', '{"x":"界"}'),
          ),
          _failure('invalid_request', 'The request is invalid.', false),
        );

        final resultLimited = _dispatcher(
          questions: _QuestionPort(bankName: 'private-marker' * 20),
          limits: const AgentRuntimeLimits(maxToolResultUtf8Bytes: 120),
        );
        final response = await resultLimited.dispatch(
          'list_question_banks',
          '{}',
        );
        expect(
          _decode(response),
          _failure('internal_error', 'An internal error occurred.', false),
        );
        expect(response, isNot(contains('private-marker')));
      },
    );
  });
}

Set<String> _properties(Map<String, Object?> schema) {
  return ((schema['properties'] as Map<String, Object?>).keys).toSet();
}

Map<String, Object?> _property(Map<String, Object?> schema, String name) {
  return (schema['properties'] as Map<String, Object?>)[name]!
      as Map<String, Object?>;
}

(int, int) _bounds(Map<String, Object?> schema, String name) {
  final property = _property(schema, name);
  return (property['minimum']! as int, property['maximum']! as int);
}

Map<String, dynamic> _decode(String value) {
  return jsonDecode(value) as Map<String, dynamic>;
}

Map<String, Object?> _failure(String code, String message, bool retryable) {
  return <String, Object?>{
    'ok': false,
    'error': <String, Object?>{
      'code': code,
      'message': message,
      'retryable': retryable,
    },
  };
}

AgentStudyToolDispatcher _dispatcher({
  _QuestionPort? questions,
  _MetricsPort? metrics,
  AgentRuntimeLimits limits = const AgentRuntimeLimits(),
}) {
  return AgentStudyToolDispatcher(
    service: StudyQueryService(
      questionQuery: questions ?? _QuestionPort(),
      metricsQuery: metrics ?? _MetricsPort(),
      clock: const _Clock(),
    ),
    limits: limits,
  );
}

final class _Clock implements StudyClock {
  const _Clock();

  @override
  DateTime nowUtc() => DateTime.utc(2026, 8, 10, 12);
}

final class _QuestionPort implements StudyQuestionQueryPort {
  _QuestionPort({this.failure, this.bankName = 'Synthetic'});

  final StudyQueryRepositoryFailure? failure;
  final String bankName;
  final List<String> calls = <String>[];

  void _throwIfNeeded() {
    final selected = failure;
    if (selected != null) throw StudyQueryRepositoryException(selected);
  }

  StudyQuestionRead get _question => TypedStudyQuestionRead(
    questionId: 'q1',
    bankName: bankName,
    createdAt: 1,
    draft: QuestionDraftV2(
      questionId: 'q1',
      kind: QuestionKind.shortAnswer,
      stem: RichContent(
        nodes: <ContentNode>[
          const TextNode('Safe stem'),
          RawFallbackNode(<String, Object?>{
            'type': 'raw_fallback',
            'payload': <String, Object?>{'private': 'private-marker'},
          }),
        ],
      ),
    ),
    review: const StudyQuestionReviewState(
      due: true,
      lapseCount: 2,
      difficulty: 6.5,
      lastLapseTime: 1786363200,
    ),
  );

  @override
  Future<StudyPage<QuestionBankSummary>> listStudyQuestionBanks({
    required int nowUnixSeconds,
    required int limit,
    String? afterBankName,
  }) async {
    calls.add('banks');
    _throwIfNeeded();
    return StudyPage<QuestionBankSummary>(
      items: <QuestionBankSummary>[
        QuestionBankSummary(
          bankName: bankName,
          folderName: 'Folder',
          questionCount: 1,
          dueCount: 1,
          masteredCount: 0,
        ),
      ],
      hasMore: false,
    );
  }

  @override
  Future<StudyPage<StudyQuestionRead>> searchStudyQuestions({
    required String bankName,
    required String query,
    required int nowUnixSeconds,
    required int limit,
    int? afterCreatedAt,
    String? afterId,
  }) async {
    calls.add('search');
    _throwIfNeeded();
    return StudyPage<StudyQuestionRead>(
      items: <StudyQuestionRead>[_question],
      hasMore: false,
    );
  }

  @override
  Future<StudyQuestionRead?> getStudyQuestionDetail(
    String questionId, {
    required int nowUnixSeconds,
  }) async {
    calls.add('detail');
    _throwIfNeeded();
    return _question;
  }

  @override
  Future<StudyPage<StudyQuestionRead>> listStudyWeakQuestions({
    required int nowUnixSeconds,
    required int limit,
    String? bankName,
    int? afterLastLapseTime,
    String? afterId,
  }) async {
    calls.add('weak');
    _throwIfNeeded();
    return StudyPage<StudyQuestionRead>(
      items: <StudyQuestionRead>[_question],
      hasMore: false,
    );
  }
}

final class _MetricsPort implements StudyMetricsQueryPort {
  final List<String> calls = <String>[];

  @override
  Future<StudyOverviewCounts> getStudyOverviewCounts({
    String? bankName,
    required int nowUnixSeconds,
    required int todayStartUnixSeconds,
  }) async {
    calls.add('overview');
    return const StudyOverviewCounts(
      questionCount: 1,
      masteredCount: 0,
      dueCount: 1,
      todayPracticeCount: 0,
      wrongQuestionCount: 1,
    );
  }

  @override
  Future<int> countStudyDueNow({
    String? bankName,
    required int nowUnixSeconds,
  }) async {
    calls.add('due_now');
    return 1;
  }

  @override
  Future<List<int>> getStudyScheduledReviewTimestamps({
    String? bankName,
    required int fromUnixSeconds,
    required int toUnixSeconds,
  }) async {
    calls.add('scheduled');
    return <int>[1786363200];
  }
}
