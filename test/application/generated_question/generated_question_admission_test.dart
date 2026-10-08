import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:uuid/uuid.dart';
import 'generated_test_support.dart';

void main() {
  final admission = GeneratedQuestionAdmission(idFactory: const Uuid().v4);
  final h = GeneratedHarness();
  for (final kind in ['singleChoice', 'fillBlank', 'shortAnswer']) {
    test('strict supported $kind with explicit empty explanation', () {
      final result = admission.admit(
          submission(items: [candidate(kind: kind)]), h.origin());
      expect(result.items.single.original.kind.name, kind);
      expect(result.items.single.original.explanation!.nodes, isEmpty);
      expect(result.items.single.original.questionId, isNot('item'));
    });
  }
  test('ordered Text/InlineMath/BlockMath and no text reconstruction', () {
    final c = candidate();
    c['stem'] = [
      {'type': 'text', 'text': 'Literal **Markdown** '},
      {'type': 'inline_math', 'latex': 'x+1'},
      {'type': 'block_math', 'latex': 'x=2'}
    ];
    final d = admission
        .admit(submission(items: [c]), h.origin())
        .items
        .single
        .original;
    expect(d.stem.nodes.map((n) => n.runtimeType),
        [TextNode, InlineMathNode, BlockMathNode]);
  });
  for (final node in [
    'image',
    'table',
    'raw_fallback',
    'future',
    'provider_block'
  ]) {
    test('reject unsupported $node whole batch', () {
      final c = candidate(key: 'bad');
      c['stem'] = [
        {'type': node}
      ];
      expect(
          () =>
              admission.admit(submission(items: [candidate(), c]), h.origin()),
          failure(GeneratedFailure.unsupportedContent));
    });
  }
  for (final change in <String, void Function(Map<String, Object?>)>{
    'unknown item field': (c) => c['questionId'] = 'client',
    'missing answer': (c) => c.remove('answer'),
    'present null answer': (c) => c['answer'] = null,
    'wrong type': (c) => c['stem'] = 'guess me',
    'unknown kind': (c) => c['kind'] = 'multipleChoice',
    'missing node field': (c) => c['stem'] = [
          {'type': 'text'}
        ],
    'unknown node field': (c) => c['stem'] = [
          {'type': 'text', 'text': 'stem', 'extra': 1}
        ],
    'unauthorized evidence': (c) => c['evidenceKeys'] = ['invented'],
    'answer key absent': (c) {
      c['kind'] = 'singleChoice';
      c['answer'] = {
        'type': 'choice',
        'optionKeys': ['absent']
      };
    },
  }.entries) {
    test('reject ${change.key}', () {
      final c = candidate();
      change.value(c);
      expect(() => admission.admit(submission(items: [c]), h.origin()),
          throwsA(isA<GeneratedQuestionException>()));
    });
  }
  for (final json in [
    '{',
    '{}',
    '{"schemaVersion":1,"schemaVersion":1}',
    '{"schemaVersion":1,"schemaVersion":2}',
    submission(items: []),
    submission(items: [candidate(), candidate()])
  ]) {
    test('reject malformed/partial/duplicate/empty batch ${json.length}', () {
      expect(() => admission.admit(json, h.origin()),
          throwsA(isA<GeneratedQuestionException>()));
    });
  }
  for (final text in [
    'https://example.invalid',
    'file:///tmp/x',
    r'C:\private\x',
    '<b>HTML</b>',
    'data:image/png;base64,abc',
    List.filled(200, 'A').join()
  ]) {
    test('reject generated private/URL/binary content ${text.length}', () {
      expect(
          () => admission.admit(
              submission(items: [candidate(stem: text)]), h.origin()),
          failure(GeneratedFailure.unsafePayload));
    });
  }
  test('resource limits cover nodes/scalars/total/50-item maximum', () {
    final c = candidate();
    c['stem'] = List.generate(257, (i) => {'type': 'text', 'text': 'x'});
    expect(() => admission.admit(submission(items: [c]), h.origin()),
        failure(GeneratedFailure.resourceLimit));
    c['stem'] = [
      {'type': 'text', 'text': List.filled(4097, '中').join()}
    ];
    expect(() => admission.admit(submission(items: [c]), h.origin()),
        failure(GeneratedFailure.resourceLimit));
    expect(
        () => admission.admit(
            List.filled(GeneratedLimits.submissionBytes + 1, ' ').join(),
            h.origin()),
        failure(GeneratedFailure.resourceLimit));
    expect(
        () => admission.admit(
            submission(items: List.generate(51, (i) => candidate(key: 'i$i'))),
            h.origin()),
        failure(GeneratedFailure.resourceLimit));
  });
  test('duplicate keys with JSON escapes are detected before Map decode', () {
    final json = submission().replaceFirst(
        '"schemaVersion":1', '"schemaVersion":1,"schema\\u0056ersion":1');
    expect(() => admission.admit(json, h.origin()),
        failure(GeneratedFailure.invalidSubmission));
  });
  test(
      'missing and explicit null explanation remain different at input boundary',
      () {
    final c = candidate();
    c['explanation'] = null;
    expect(
        admission
            .admit(submission(items: [c]), h.origin())
            .items
            .single
            .original
            .explanation,
        isNull);
    c.remove('explanation');
    expect(() => admission.admit(submission(items: [c]), h.origin()),
        throwsA(isA<GeneratedQuestionException>()));
  });
  test(
      'semantic signature ignores internal IDs but preserves node type and empty/null',
      () {
    final a = admission.admit(submission(), h.origin()).items.single.original;
    final b = admission.admit(submission(), h.origin()).items.single.original;
    expect(a.questionId, isNot(b.questionId));
    expect(generatedCanonical(generatedSemantics(a)),
        generatedCanonical(generatedSemantics(b)));
    final c = candidate();
    c['stem'] = [
      {'type': 'inline_math', 'latex': 'Synthetic stem'}
    ];
    final d = admission
        .admit(submission(items: [c]), h.origin())
        .items
        .single
        .original;
    expect(generatedCanonical(generatedSemantics(a)),
        isNot(generatedCanonical(generatedSemantics(d))));
    c['stem'] = a.stem.nodes
        .map((n) => {'type': 'text', 'text': (n as TextNode).text})
        .toList();
    c['explanation'] = null;
    expect(
        generatedCanonical(generatedSemantics(a)),
        isNot(generatedCanonical(generatedSemantics(admission
            .admit(submission(items: [c]), h.origin())
            .items
            .single
            .original))));
  });
  test('strict command envelopes never accept candidate approval flags', () {
    expect(
        () => ApproveGeneratedProposalCommand.fromJson(
            {'proposalId': 'x', 'approved': true}),
        throwsA(isA<GeneratedQuestionException>()));
    expect(
        () => GeneratedReviewFlush.fromJson(jsonDecode(
            '{"proposalId":"x","expectedReviewRevision":"0","operations":[]}')),
        throwsA(isA<GeneratedQuestionException>()));
  });
}
