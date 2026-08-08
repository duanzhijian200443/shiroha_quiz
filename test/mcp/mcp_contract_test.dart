// mcp.study.v0 adapter contract acceptance.
//
// Covers the exactly-six tool surface, the frozen success/error envelopes,
// opaque cursors and pages, single-object projection, the fixed error
// taxonomy, and the READ_ONLY proof. The adapter runs over the T0
// StudyQueryService with the canonical synthetic in-memory dataset; the clock
// is fixed so every envelope timestamp is deterministic.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_query/study_query_clock.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/mcp/study_mcp_adapter.dart';

import '../application/study_query/study_query_test_support.dart';

final class _FixedClock implements StudyClock {
  const _FixedClock(this.now);

  final DateTime now;

  @override
  DateTime nowUtc() => now;
}

final DateTime fixedNow = DateTime.utc(2026, 8, 8, 17);

StudyMcpAdapter _adapter() {
  return StudyMcpAdapter(
    service: StudyQueryService(
      questionQuery: QuestionRepository(),
      metricsQuery: ReviewRepository(),
      clock: _FixedClock(fixedNow),
    ),
    clock: _FixedClock(fixedNow),
  );
}

/// Canonical mixed typed+legacy dataset mirroring the T0 acceptance dataset.
Future<void> _seedStandardDataset() async {
  final db = await openTestDatabase();

  await db.insert('bank_folders', <String, Object?>{
    'bank_name': bankMath,
    'folder_name': 'Algebra',
  });
  await db.insert('bank_folders', <String, Object?>{
    'bank_name': bankPhysics,
    'folder_name': 'Physics',
  });

  await insertTypedQuestion(
    db,
    draft: makeDraft(
      'draft_alpha',
      stem: richContent(<ContentNode>[
        const TextNode('Solve '),
        const InlineMathNode(r'x^2=1'),
        RawFallbackNode(rawFallbackPayload('synthetic-raw')),
      ]),
      options: <QuestionOption>[optionA(), optionB()],
      answer: ChoiceAnswer(optionIds: <String>['A']),
      explanation: textContent('Synthetic explanation alpha'),
    ),
    storageId: idTyped1,
    createdAt: 100,
    bankName: bankMath,
  );
  await insertTypedQuestion(
    db,
    draft: makeDraft(
      'draft_beta',
      stem: textContent('Synthetic stem beta'),
      options: <QuestionOption>[optionA(), optionB()],
      answer: ChoiceAnswer(optionIds: <String>['A']),
      explanation: textContent('Beta explanation'),
    ),
    storageId: idTyped2,
    createdAt: 90,
    bankName: bankMath,
  );
  await insertLegacyQuestion(
    db,
    id: 'legacy_q3',
    createdAt: 80,
    bankName: bankMath,
    content: 'Synthetic legacy gamma',
    type: 3,
    options: '["A. one","B. two"]',
    answer: 'Legacy answer',
    explanation: 'Legacy explanation.',
  );
  await insertLegacyQuestion(
    db,
    id: 'legacy_q4',
    createdAt: 70,
    bankName: bankPhysics,
    content: 'Physics legacy delta',
    type: 0,
    options: '["A. alpha","B. beta"]',
    answer: 'A',
    explanation: null,
  );
  await insertTypedQuestion(
    db,
    draft: makeDraft(
      'draft_epsilon',
      stem: textContent('Synthetic stem epsilon'),
      options: <QuestionOption>[optionA(), optionB()],
      // Explicit typed empty: no answer and no explanation.
      answer: null,
      explanation: null,
    ),
    storageId: idTyped5,
    createdAt: 60,
    bankName: bankPhysics,
  );
  await insertLegacyQuestion(
    db,
    id: 'legacy_q6',
    createdAt: 50,
    bankName: bankThird,
    content: 'Third bank zeta',
    type: 2,
    options: '[]',
    answer: 'fill answer',
    explanation: null,
  );
  await insertLegacyQuestion(
    db,
    id: 'legacy_q7',
    createdAt: 40,
    bankName: bankMath,
    content: 'Progress 100%_done now',
    type: 0,
    options: '["A. yes","B. no"]',
    answer: 'A',
    explanation: null,
  );

  await insertReviewState(
    db,
    questionId: idTyped1,
    state: 3,
    nextReviewTime: unixSeconds('2026-08-08T15:59:59Z'),
    lapses: 3,
    difficulty: 4.2,
    lastLapseTime: unixSeconds('2026-08-03T07:00:00Z'),
  );
  await insertReviewState(
    db,
    questionId: idTyped2,
    state: 2,
    nextReviewTime: unixSeconds('2026-08-08T16:00:00Z'),
  );
  await insertReviewState(
    db,
    questionId: 'legacy_q3',
    state: 1,
    nextReviewTime: unixSeconds('2026-08-09T10:00:00Z'),
    lapses: 2,
    difficulty: 6.5,
    lastLapseTime: unixSeconds('2026-08-01T08:00:00Z'),
  );
  await insertReviewState(
    db,
    questionId: 'legacy_q4',
    state: 1,
    nextReviewTime: unixSeconds('2026-08-07T23:59:59Z'),
    lapses: 1,
    lastLapseTime: unixSeconds('2026-08-02T09:00:00Z'),
  );
  await insertReviewState(
    db,
    questionId: idTyped5,
    state: 3,
    nextReviewTime: unixSeconds('2026-08-10T00:00:00Z'),
  );
  await insertReviewState(
    db,
    questionId: 'legacy_q6',
    state: 0,
    nextReviewTime: unixSeconds('2026-08-08T00:00:00Z'),
  );
  await insertReviewState(
    db,
    questionId: 'legacy_q7',
    state: 0,
    nextReviewTime: unixSeconds('2026-08-06T00:00:00Z'),
  );

  await insertReviewLog(
    db,
    questionId: idTyped1,
    reviewTime: unixSeconds('2026-08-08T16:30:00Z'),
  );
  await insertReviewLog(
    db,
    questionId: idTyped2,
    reviewTime: unixSeconds('2026-08-08T15:00:00Z'),
  );
  await insertReviewLog(
    db,
    questionId: idTyped5,
    reviewTime: unixSeconds('2026-08-08T00:30:00Z'),
  );
}

/// Asserts the frozen success envelope rules and returns the envelope body.
Map<String, Object?> _successEnvelope(StudyMcpToolResult result) {
  expect(result.isError, isFalse);
  final envelope = result.envelope;
  expect(envelope['schema_version'], studyMcpSchemaVersion);
  expect(envelope['generated_at'], '2026-08-08T17:00:00Z');
  expect(envelope.containsKey('error'), isFalse);
  return envelope;
}

/// Asserts the exact section-5 error envelope and returns it.
Map<String, Object?> _errorEnvelope(
  StudyMcpToolResult result, {
  required String code,
}) {
  expect(result.isError, isTrue);
  final envelope = result.envelope;
  expect(envelope.keys.toSet(), <String>{'schema_version', 'error'});
  expect(envelope['schema_version'], studyMcpSchemaVersion);
  expect(envelope.containsKey('generated_at'), isFalse);
  expect(envelope.containsKey('data'), isFalse);
  expect(envelope.containsKey('items'), isFalse);
  expect(envelope.containsKey('next_cursor'), isFalse);
  final error = envelope['error'] as Map<String, Object?>;
  expect(error.keys.toSet(), <String>{'code', 'message', 'retryable'});
  expect(error['code'], code);
  expect(error['message'], isA<String>());
  expect(error['retryable'], isA<bool>());
  return envelope;
}

void main() {
  setUpAll(initTestDatabaseFactory);

  setUp(() async {
    await resetTestDatabase();
    await _seedStandardDataset();
  });

  tearDown(resetTestDatabase);

  group('A exactly-six tool surface and envelopes', () {
    test('tool names are exactly the frozen six', () {
      expect(
        StudyMcpAdapter.toolNames,
        <String>[
          'list_question_banks',
          'get_study_overview',
          'get_due_review_summary',
          'search_questions',
          'get_question_detail',
          'get_weak_questions',
        ],
      );
    });

    test('page envelopes carry items and next_cursor', () async {
      final envelope = _successEnvelope(
        await _adapter().callTool('list_question_banks', <String, dynamic>{}),
      );
      expect(envelope.containsKey('data'), isFalse);
      expect(envelope['items'], isA<List<Object?>>());
      expect(envelope.containsKey('next_cursor'), isTrue);
      expect(envelope['next_cursor'], isNull);
    });

    test('single-object envelopes carry data only', () async {
      final envelope = _successEnvelope(
        await _adapter().callTool(
          'get_study_overview',
          <String, dynamic>{'timezone': 'Asia/Shanghai'},
        ),
      );
      expect(envelope.containsKey('data'), isTrue);
      expect(envelope.containsKey('items'), isFalse);
      expect(envelope.containsKey('next_cursor'), isFalse);
    });
  });

  group('B list question banks', () {
    test('counts, folders, and no internal ids or question text', () async {
      final envelope = _successEnvelope(
        await _adapter().callTool('list_question_banks', <String, dynamic>{}),
      );
      final items = envelope['items'] as List<Object?>;
      expect(
        items.map((item) => (item as Map<String, Object?>)['bank_name']),
        <Object?>[bankMath, bankPhysics, bankThird],
      );
      final math = items[0] as Map<String, Object?>;
      expect(math['folder_name'], 'Algebra');
      expect(math['question_count'], 4);
      expect(math['due_count'], 3);
      expect(math['mastered_count'], 1);
      final physics = items[1] as Map<String, Object?>;
      expect(physics['folder_name'], 'Physics');
      expect(physics['question_count'], 2);
      expect(physics['due_count'], 1);
      expect(physics['mastered_count'], 1);
      final third = items[2] as Map<String, Object?>;
      expect(third['folder_name'], uncategorizedFolder);
      expect(third['question_count'], 1);
      expect(third['due_count'], 1);
      expect(third['mastered_count'], 0);
      final serialized = jsonEncode(envelope);
      expect(serialized, isNot(contains('Solve ')));
      expect(serialized, isNot(contains('legacy_q')));
    });

    test('bounded keyset pagination with an opaque cursor', () async {
      final adapter = _adapter();
      final first = _successEnvelope(
        await adapter.callTool(
          'list_question_banks',
          <String, dynamic>{'limit': 2},
        ),
      );
      final firstItems = first['items'] as List<Object?>;
      expect(
        firstItems.map((item) => (item as Map<String, Object?>)['bank_name']),
        <Object?>[bankMath, bankPhysics],
      );
      final cursor = first['next_cursor'] as String;
      expect(cursor, isNotEmpty);
      expect(cursor, isNot(contains(bankPhysics)));

      final second = _successEnvelope(
        await adapter.callTool(
          'list_question_banks',
          <String, dynamic>{'limit': 2, 'cursor': cursor},
        ),
      );
      final secondItems = second['items'] as List<Object?>;
      expect(
        secondItems.map((item) => (item as Map<String, Object?>)['bank_name']),
        <Object?>[bankThird],
      );
      expect(second['next_cursor'], isNull);
    });
  });

  group('C study overview and due review summary', () {
    test('global and bank-scoped overview counts', () async {
      final adapter = _adapter();
      final shanghai = _successEnvelope(
        await adapter.callTool(
          'get_study_overview',
          <String, dynamic>{'timezone': 'Asia/Shanghai'},
        ),
      );
      final data = shanghai['data'] as Map<String, Object?>;
      expect(data['question_count'], 7);
      expect(data['mastered_count'], 2);
      expect(data['due_count'], 5);
      expect(data['today_practice_count'], 1);
      expect(data['wrong_question_count'], 3);

      final math = _successEnvelope(
        await adapter.callTool(
          'get_study_overview',
          <String, dynamic>{
            'bank_name': '  $bankMath  ',
            'timezone': 'Asia/Shanghai',
          },
        ),
      );
      final mathData = math['data'] as Map<String, Object?>;
      expect(mathData['question_count'], 4);
      expect(mathData['due_count'], 3);
      expect(mathData['wrong_question_count'], 2);
      expect(mathData['today_practice_count'], 1);

      final utc = _successEnvelope(
        await adapter.callTool(
          'get_study_overview',
          <String, dynamic>{'timezone': 'UTC'},
        ),
      );
      expect((utc['data'] as Map<String, Object?>)['today_practice_count'], 3);
    });

    test('due review summary buckets use the selected timezone', () async {
      final adapter = _adapter();
      final shanghai = _successEnvelope(
        await adapter.callTool(
          'get_due_review_summary',
          <String, dynamic>{
            'timezone': 'Asia/Shanghai',
            'from': '2026-08-08T00:00:00Z',
            'to': '2026-08-10T00:00:00Z',
          },
        ),
      );
      final data = shanghai['data'] as Map<String, Object?>;
      expect(data['due_now'], 5);
      expect(data['scheduled_count'], 3);
      final buckets = data['buckets'] as List<Object?>;
      expect(
        buckets.map((bucket) {
          final map = bucket as Map<String, Object?>;
          return '${map['date']}:${map['count']}';
        }).toList(),
        <String>['2026-08-08:1', '2026-08-09:2'],
      );

      final utc = _successEnvelope(
        await adapter.callTool(
          'get_due_review_summary',
          <String, dynamic>{
            'timezone': 'UTC',
            'from': '2026-08-08T00:00:00Z',
            'to': '2026-08-10T00:00:00Z',
          },
        ),
      );
      final utcBuckets =
          (utc['data'] as Map<String, Object?>)['buckets'] as List<Object?>;
      expect(
        utcBuckets.map((bucket) {
          final map = bucket as Map<String, Object?>;
          return '${map['date']}:${map['count']}';
        }).toList(),
        <String>['2026-08-08:2', '2026-08-09:1'],
      );
    });
  });

  group('D search questions', () {
    test('ordering, opaque cursor pages, preview, flags, and source kind',
        () async {
      final adapter = _adapter();
      final first = _successEnvelope(
        await adapter.callTool(
          'search_questions',
          <String, dynamic>{
            'bank_name': bankMath,
            'query': 'Synthetic',
            'limit': 2,
          },
        ),
      );
      final firstItems = first['items'] as List<Object?>;
      expect(
        firstItems.map((item) => (item as Map<String, Object?>)['question_id']),
        <Object?>[idTyped1, idTyped2],
      );
      final hit = firstItems[0] as Map<String, Object?>;
      expect(hit['bank_name'], bankMath);
      expect(hit['kind'], 'single_choice');
      expect(hit['stem_preview'], r'Solve x^2=1');
      expect(hit['has_answer'], isTrue);
      expect(hit['has_explanation'], isTrue);
      expect(hit['due'], isTrue);
      expect(hit['source_kind'], 'typed');
      final serialized = jsonEncode(first);
      expect(serialized, isNot(contains('synthetic-raw')));
      expect(serialized, isNot(contains('raw_fallback')));
      final cursor = first['next_cursor'] as String;
      expect(cursor, isNotEmpty);

      final second = _successEnvelope(
        await adapter.callTool(
          'search_questions',
          <String, dynamic>{
            'bank_name': bankMath,
            'query': 'Synthetic',
            'limit': 2,
            'cursor': cursor,
          },
        ),
      );
      final secondItems = second['items'] as List<Object?>;
      expect(
        secondItems
            .map((item) => (item as Map<String, Object?>)['question_id']),
        <Object?>['legacy_q3'],
      );
      final legacy = secondItems.single as Map<String, Object?>;
      expect(legacy['kind'], 'short_answer');
      expect(legacy['stem_preview'], 'Synthetic legacy gamma');
      expect(legacy['has_explanation'], isTrue);
      expect(legacy['due'], isFalse);
      expect(legacy['source_kind'], 'legacy');
      expect(second['next_cursor'], isNull);
    });
  });

  group('E question detail', () {
    test('typed detail projects safe nodes and raw fallback to unsupported',
        () async {
      final envelope = _successEnvelope(
        await _adapter().callTool(
          'get_question_detail',
          <String, dynamic>{'question_id': idTyped1},
        ),
      );
      final data = envelope['data'] as Map<String, Object?>;
      expect(data['question_id'], idTyped1);
      expect(data['bank_name'], bankMath);
      expect(data['kind'], 'single_choice');
      expect(data['source_kind'], 'typed');
      expect((data['due_state'] as Map<String, Object?>)['due'], isTrue);
      final stem = data['stem'] as List<Object?>;
      expect(
        stem.map((node) => (node as Map<String, Object?>)['type']).toList(),
        <Object?>['text', 'inline_math', 'unsupported'],
      );
      expect((stem[0] as Map<String, Object?>)['text'], 'Solve ');
      expect((stem[1] as Map<String, Object?>)['latex'], r'x^2=1');
      final options = data['options'] as List<Object?>;
      expect(options, hasLength(2));
      expect((options[0] as Map<String, Object?>)['label'], 'A');
      expect(
        ((options[0] as Map<String, Object?>)['content'] as List<Object?>)
            .single,
        <String, Object?>{'type': 'text', 'text': 'one'},
      );
      final answer = data['answer'] as List<Object?>;
      expect(answer.single, <String, Object?>{'type': 'text', 'text': 'A'});
      final explanation = data['explanation'] as List<Object?>;
      expect(
        explanation.single,
        <String, Object?>{
          'type': 'text',
          'text': 'Synthetic explanation alpha'
        },
      );
      expect(jsonEncode(envelope), isNot(contains('synthetic-raw')));
    });

    test('legacy detail is a safe text DTO', () async {
      final envelope = _successEnvelope(
        await _adapter().callTool(
          'get_question_detail',
          <String, dynamic>{'question_id': 'legacy_q3'},
        ),
      );
      final data = envelope['data'] as Map<String, Object?>;
      expect(data['kind'], 'short_answer');
      expect(data['source_kind'], 'legacy');
      expect(
        (data['due_state'] as Map<String, Object?>)['due'],
        isFalse,
      );
      expect(
        (data['stem'] as List<Object?>).single,
        <String, Object?>{'type': 'text', 'text': 'Synthetic legacy gamma'},
      );
      expect(
        (data['answer'] as List<Object?>).single,
        <String, Object?>{'type': 'text', 'text': 'Legacy answer'},
      );
      expect(
        (data['explanation'] as List<Object?>).single,
        <String, Object?>{'type': 'text', 'text': 'Legacy explanation.'},
      );
    });
  });

  group('F weak questions', () {
    test('metrics, ordering, bank scope, and keyset pagination', () async {
      final adapter = _adapter();
      final first = _successEnvelope(
        await adapter.callTool(
          'get_weak_questions',
          <String, dynamic>{'limit': 2},
        ),
      );
      final firstItems = first['items'] as List<Object?>;
      expect(
        firstItems.map((item) => (item as Map<String, Object?>)['question_id']),
        <Object?>[idTyped1, 'legacy_q4'],
      );
      final typed = firstItems[0] as Map<String, Object?>;
      expect(typed['bank_name'], bankMath);
      expect(typed['stem_preview'], r'Solve x^2=1');
      expect(typed['lapse_count'], 3);
      expect(typed['difficulty'], 4.2);
      expect(typed['last_lapse_at'], '2026-08-03T07:00:00Z');
      expect(jsonEncode(first), isNot(contains('synthetic-raw')));
      final legacy = firstItems[1] as Map<String, Object?>;
      expect(legacy['lapse_count'], 1);
      expect(legacy['difficulty'], 5.0);
      expect(legacy['last_lapse_at'], '2026-08-02T09:00:00Z');
      final cursor = first['next_cursor'] as String;
      expect(cursor, isNotEmpty);

      final second = _successEnvelope(
        await adapter.callTool(
          'get_weak_questions',
          <String, dynamic>{'limit': 2, 'cursor': cursor},
        ),
      );
      final secondItems = second['items'] as List<Object?>;
      expect(
        secondItems
            .map((item) => (item as Map<String, Object?>)['question_id']),
        <Object?>['legacy_q3'],
      );
      final last = secondItems.single as Map<String, Object?>;
      expect(last['lapse_count'], 2);
      expect(last['difficulty'], 6.5);
      expect(last['last_lapse_at'], '2026-08-01T08:00:00Z');
      expect(second['next_cursor'], isNull);

      final math = _successEnvelope(
        await adapter.callTool(
          'get_weak_questions',
          <String, dynamic>{'bank_name': bankMath},
        ),
      );
      expect(
        (math['items'] as List<Object?>)
            .map((item) => (item as Map<String, Object?>)['question_id'])
            .toList(),
        <Object?>[idTyped1, 'legacy_q3'],
      );
    });
  });

  group('G error taxonomy', () {
    test('invalid arguments map to the exact invalid_request envelope',
        () async {
      final adapter = _adapter();
      final invalidCalls = <(String, Map<String, dynamic>)>[
        ('list_question_banks', <String, dynamic>{'limit': 0}),
        ('list_question_banks', <String, dynamic>{'limit': 101}),
        ('list_question_banks', <String, dynamic>{'limit': '5'}),
        ('list_question_banks', <String, dynamic>{'cursor': 42}),
        ('list_question_banks', <String, dynamic>{'cursor': 'not-a-cursor'}),
        ('get_study_overview', <String, dynamic>{}),
        (
          'get_study_overview',
          <String, dynamic>{'timezone': 'Mars/Olympus_Mons'},
        ),
        (
          'get_study_overview',
          <String, dynamic>{'timezone': 'UTC', 'bank_name': '   '},
        ),
        ('get_due_review_summary', <String, dynamic>{}),
        (
          'get_due_review_summary',
          <String, dynamic>{
            'timezone': 'UTC',
            'from': 'not-a-date',
            'to': '2026-08-10T00:00:00Z',
          },
        ),
        (
          'get_due_review_summary',
          <String, dynamic>{
            'timezone': 'UTC',
            'from': '2026-08-08T00:00:00',
            'to': '2026-08-10T00:00:00Z',
          },
        ),
        (
          'get_due_review_summary',
          <String, dynamic>{
            'timezone': 'UTC',
            'from': '2026-08-08 00:00:00Z',
            'to': '2026-08-10T00:00:00Z',
          },
        ),
        (
          'get_due_review_summary',
          <String, dynamic>{
            'timezone': 'UTC',
            'from': '2026-08-08T00:00:00+0800',
            'to': '2026-08-10T00:00:00Z',
          },
        ),
        (
          'get_due_review_summary',
          <String, dynamic>{
            'timezone': 'UTC',
            'from': '2026-08-08T00:00:00z',
            'to': '2026-08-10T00:00:00Z',
          },
        ),
        (
          'get_due_review_summary',
          <String, dynamic>{
            'timezone': 'UTC',
            'from': '2026-08-09T00:00:00Z',
            'to': '2026-08-08T00:00:00Z',
          },
        ),
        (
          'get_due_review_summary',
          <String, dynamic>{
            'timezone': 'UTC',
            'from': '2026-08-08T00:00:00Z',
            'to': '2026-11-07T00:00:00Z',
          },
        ),
        (
          'search_questions',
          <String, dynamic>{'bank_name': '  ', 'query': 'x'},
        ),
        (
          'search_questions',
          <String, dynamic>{'bank_name': bankMath, 'query': ''}
        ),
        (
          'search_questions',
          <String, dynamic>{'bank_name': bankMath, 'query': 'x' * 201},
        ),
        (
          'search_questions',
          <String, dynamic>{'bank_name': bankMath, 'query': 'x', 'limit': 0},
        ),
        (
          'search_questions',
          <String, dynamic>{'bank_name': bankMath, 'query': 'x', 'limit': 51},
        ),
        ('get_question_detail', <String, dynamic>{}),
        ('get_question_detail', <String, dynamic>{'question_id': '   '}),
        (
          'get_weak_questions',
          <String, dynamic>{'limit': 0},
        ),
        (
          'get_weak_questions',
          <String, dynamic>{'limit': 51},
        ),
        ('execute_sql', <String, dynamic>{}),
      ];

      for (final (name, args) in invalidCalls) {
        final result = await adapter.callTool(name, args);
        final envelope = _errorEnvelope(
          result,
          code: 'invalid_request',
        );
        expect(
          (envelope['error'] as Map<String, Object?>)['message'],
          'The request is invalid.',
        );
        expect(
          (envelope['error'] as Map<String, Object?>)['retryable'],
          isFalse,
        );
      }
    });

    test('missing question maps to not_found', () async {
      final result = await _adapter().callTool(
        'get_question_detail',
        <String, dynamic>{'question_id': 'missing-question'},
      );
      final envelope = _errorEnvelope(result, code: 'not_found');
      expect(
        (envelope['error'] as Map<String, Object?>)['retryable'],
        isFalse,
      );
    });

    test('corrupt sidecar maps to data_corrupt with no V1 fallback', () async {
      final db = await openTestDatabase();
      await insertTypedQuestion(
        db,
        draft: makeDraft(
          'draft_corrupt',
          stem: textContent('Corrupt bank stem'),
          options: <QuestionOption>[optionA()],
          answer: ChoiceAnswer(optionIds: <String>['A']),
        ),
        storageId: idCorrupt,
        createdAt: 10,
        bankName: bankCorrupt,
      );
      await corruptSidecar(db, storageId: idCorrupt);

      final result = await _adapter().callTool(
        'get_question_detail',
        <String, dynamic>{'question_id': idCorrupt},
      );
      final envelope = _errorEnvelope(result, code: 'data_corrupt');
      final error = envelope['error'] as Map<String, Object?>;
      expect(error['message'], 'The stored data cannot be read safely.');
      expect(error['retryable'], isFalse);
      expect(jsonEncode(envelope), isNot(contains('oops')));
      expect(jsonEncode(envelope), isNot(contains('V1')));
    });

    test('temporary database failure maps to temporarily_unavailable',
        () async {
      final db = await openTestDatabase();
      await db.execute('DROP TABLE review_states');
      final result = await _adapter().callTool(
        'get_study_overview',
        <String, dynamic>{'timezone': 'UTC'},
      );
      final envelope = _errorEnvelope(
        result,
        code: 'temporarily_unavailable',
      );
      final error = envelope['error'] as Map<String, Object?>;
      expect(error['retryable'], isTrue);
      expect(jsonEncode(envelope), isNot(contains('review_states')));
      expect(jsonEncode(envelope), isNot(contains('DROP')));
    });
  });

  group('H READ_ONLY proof', () {
    test('all six tool calls leave the core tables byte-identical', () async {
      final db = await openTestDatabase();
      final before = await snapshotCoreTables(db);
      final adapter = _adapter();

      await adapter.callTool('list_question_banks', <String, dynamic>{});
      await adapter.callTool(
        'get_study_overview',
        <String, dynamic>{'timezone': 'Asia/Shanghai'},
      );
      await adapter.callTool(
        'get_due_review_summary',
        <String, dynamic>{
          'timezone': 'Asia/Shanghai',
          'from': '2026-08-08T00:00:00Z',
          'to': '2026-08-10T00:00:00Z',
        },
      );
      await adapter.callTool(
        'search_questions',
        <String, dynamic>{'bank_name': bankMath, 'query': 'Synthetic'},
      );
      await adapter.callTool(
        'get_question_detail',
        <String, dynamic>{'question_id': idTyped1},
      );
      await adapter.callTool('get_weak_questions', <String, dynamic>{});

      final after = await snapshotCoreTables(db);
      expect(after, before);
    });
  });
}
