import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:uuid/uuid.dart';
import 'generated_test_support.dart';

void main() {
  final admission = GeneratedQuestionAdmission(idFactory: const Uuid().v4);
  final h = GeneratedHarness();
  test(
      'aggregate content scalar ceiling is enforced across individually valid nodes',
      () {
    final c = candidate();
    c['stem'] = [
      for (var i = 0; i < 3; i++)
        {'type': 'text', 'text': List.filled(1500, '中 ').join()}
    ];
    expect(() => admission.admit(submission(items: [c]), h.origin()),
        failure(GeneratedFailure.resourceLimit));
  });
  test(
      'durable review working budget is independent of smaller immutable originals',
      () {
    final candidates = List.generate(50, (i) {
      final c =
          candidate(key: 'i$i', stem: 'Question $i', kind: 'singleChoice');
      c['options'] = List.generate(
          26,
          (n) => {
                'optionKey': 'a$n',
                'label': 'A$n',
                'content': [
                  {'type': 'text', 'text': 'Option $n'}
                ]
              });
      c['answer'] = {
        'type': 'choice',
        'optionKeys': ['a0']
      };
      return c;
    });
    final batch = admission.admit(submission(items: candidates), h.origin());
    final p = GeneratedQuestionProposal(
        proposalId: '11111111-1111-4111-8111-111111111111',
        createdAtUtcMs: 0,
        updatedAtUtcMs: 0,
        localOwner: 'owner',
        originKind: 'synthetic',
        clientProfileId: 'internal',
        submissionKey: 'submission',
        semanticFingerprint: List.filled(64, '0').join(),
        requestedCount: 50,
        originalTarget: h.target,
        target: h.target,
        reviewRevision: 1,
        lifecycleStatus: GeneratedStatus.pendingReview,
        items: batch.items,
        commitReceipt: null);
    final value = p.toJson();
    for (final item in value['items'] as List) {
      final working = item['working'] as Map;
      for (final option in working['options'] as List) {
        (option['content'] as Map)['nodes'] = [
          {'type': 'text', 'text': List.filled(1024, '中 ').join()}
        ];
      }
    }
    expect(() => GeneratedQuestionProposal.fromJson(value),
        failure(GeneratedFailure.resourceLimit));
  });
  test('flush count/byte limits reject before state can be written', () {
    const id = '11111111-1111-4111-8111-111111111111';
    expect(
        () => GeneratedReviewFlush.fromJson({
              'proposalId': id,
              'expectedReviewRevision': 0,
              'operations': List.generate(
                  51,
                  (i) =>
                      {'type': 'decide', 'itemId': id, 'decision': 'accepted'})
            }),
        failure(GeneratedFailure.resourceLimit));
    expect(
        () => GeneratedReviewFlush.fromJson({
              'proposalId': id,
              'expectedReviewRevision': 0,
              'operations': [
                {
                  'type': 'edit',
                  'edit': {
                    'field': 'stem',
                    'itemId': id,
                    'value': [
                      {
                        'type': 'text',
                        'text':
                            List.filled(GeneratedLimits.flushBytes, '中').join()
                      }
                    ]
                  }
                }
              ]
            }),
        failure(GeneratedFailure.resourceLimit));
  });
}
