// Proposal-first review repair contract: provider-neutral outcomes, local
// canonicalization, structural and LaTeX validation, and zero mutation of the
// reviewed question. Synthetic fixtures only; no Provider, Replay, network,
// database or filesystem.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/services/import_review/review_repair_edit.dart';
import 'package:shiroha_quiz/services/import_review/review_repair_policy.dart';
import 'package:shiroha_quiz/services/import_review/review_repair_service.dart';
import 'package:shiroha_quiz/services/llm_api_client.dart';

import '../../support/unsupported_ai_engine_store.dart';

const String _brokenExplanation = r'理解 \(\begin{matrix}1 的推导';

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

class _ThrowingEngineRepository extends AiEngineRepository {
  _ThrowingEngineRepository()
      : super(
          store: const UnsupportedAiEngineStore(),
          credentialStore: const UnsupportedEngineCredentialStore(),
        );

  @override
  Future<AiEngineProfile?> getActiveTextEngine() async {
    throw StateError('engine lookup failed');
  }
}

class _ScriptedLlmApiClient extends LlmApiClient {
  _ScriptedLlmApiClient(this.respond);

  final Future<String> Function() respond;
  int callCount = 0;
  double? lastTemperature;
  String? lastPrompt;

  @override
  Future<String> callText({
    required AiEngineProfile profile,
    required String prompt,
    String? systemPrompt,
    double? temperature,
    String? reasoningEffort,
    int maxTokens = 8192,
    bool jsonResponse = false,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    callCount++;
    lastTemperature = temperature;
    lastPrompt = prompt;
    return respond();
  }
}

const AiEngineProfile _profile = AiEngineProfile(
  id: 'test',
  engineType: AiEngineType.text,
  name: 'test',
  apiKey: 'key',
  baseUrl: 'url',
  modelName: 'model',
  temperature: 0.0,
  reasoningEffort: '',
  isActive: true,
);

ReviewRepairRequest _request({
  QuestionType type = QuestionType.shortAnswer,
  String content = 'Stem',
  List<String> options = const <String>[],
  String standardAnswer = 'Answer',
  String explanation = _brokenExplanation,
  List<ReviewRepairField> fields = const <ReviewRepairField>[
    ReviewRepairField.explanation,
  ],
  List<String> triggers = const <String>['latex_unrenderable'],
  int questionNumber = 21,
  int? expectedRevision = 3,
}) {
  return ReviewRepairRequest(
    target: ReviewRepairTarget(
      originalIndex: questionNumber - 1,
      questionNumber: questionNumber,
      triggerCodes: triggers,
      fields: fields,
    ),
    reviewItemId: '44444444-4444-4444-8444-000000000021',
    inputDraft: QuestionDraft(
      type: type,
      content: content,
      options: options,
      standardAnswer: standardAnswer,
      explanation: explanation,
    ),
    expectedRevision: expectedRevision,
  );
}

String _response({
  required int questionNumber,
  String? content,
  List<String>? options,
  String? standardAnswer,
  String? explanation,
  Map<String, Object?> extra = const <String, Object?>{},
}) {
  return jsonEncode(<String, Object?>{
    'question_number': questionNumber,
    'content': content ?? 'Stem',
    'options': options ?? <String>[],
    'standard_answer': standardAnswer ?? 'Answer',
    'explanation': explanation ?? _brokenExplanation,
    ...extra,
  });
}

void main() {
  group('ReviewRepairService outcomes', () {
    Future<ReviewRepairResult> run({
      required String response,
      ReviewRepairRequest? request,
      TypedReviewSnapshot? snapshot,
      AiEngineRepository? engineRepository,
    }) {
      final service = ReviewRepairService(
        engineRepository: engineRepository ?? _FakeEngineRepository(_profile),
        apiClient: _ScriptedLlmApiClient(() async => response),
      );
      return service.generateProposal(
        request: request ?? _request(),
        snapshot: snapshot,
      );
    }

    test('a valid repair becomes a ready proposal', () async {
      final result = await run(
        response: _response(
          questionNumber: 21,
          explanation: r'理解 \(\begin{matrix}1\end{matrix}\) 的推导',
        ),
      );

      expect(result.outcome, ReviewRepairOutcome.proposalReady);
      expect(result.hasProposal, isTrue);
      final proposal = result.proposal!;
      expect(proposal.applicable, isTrue);
      expect(proposal.changedFields, <ReviewRepairField>[
        ReviewRepairField.explanation,
      ]);
      expect(proposal.validation.structuralValid, isTrue);
      expect(proposal.validation.latexValid, isTrue);
      expect(
        proposal.proposedDraft.explanation,
        r'理解 \(\begin{matrix}1\end{matrix}\) 的推导',
      );
      // The proposal never mutates the captured input.
      expect(proposal.originalDraft.explanation, _brokenExplanation);
    });

    test('is deterministic and bounded', () async {
      final client = _ScriptedLlmApiClient(
        () async => _response(
          questionNumber: 21,
          explanation: r'Fixed \(\begin{matrix}1\end{matrix}\)',
        ),
      );
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        apiClient: client,
      );

      await service.generateProposal(request: _request());

      expect(client.callCount, 1);
      expect(client.lastTemperature, 0);
      expect(client.lastPrompt, contains('第 21 题'));
      expect(client.lastPrompt, contains('explanation'));
      expect(client.lastPrompt, contains('只允许修改这些字段'));
    });

    test('rejects without an active text engine', () async {
      final result = await run(
        response: _response(questionNumber: 21),
        engineRepository: _FakeEngineRepository(null),
      );

      expect(result.outcome, ReviewRepairOutcome.noActiveEngine);
      expect(result.hasProposal, isFalse);
    });

    test('reports an engine lookup failure as a provider failure', () async {
      final result = await run(
        response: _response(questionNumber: 21),
        engineRepository: _ThrowingEngineRepository(),
      );

      expect(result.outcome, ReviewRepairOutcome.providerFailure);
    });

    test('reports a provider failure as an explicit outcome', () async {
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        apiClient: _ScriptedLlmApiClient(
          () async => throw StateError('provider down'),
        ),
      );

      final result = await service.generateProposal(request: _request());

      expect(result.outcome, ReviewRepairOutcome.providerFailure);
      expect(result.hasProposal, isFalse);
    });

    test('rejects invalid JSON and unexpected contract keys', () async {
      expect(
        (await run(response: 'not json at all')).outcome,
        ReviewRepairOutcome.invalidJson,
      );
      expect(
        (await run(
          response: '{"question_number":21,"content":"Stem",'
              '"options":[],"standard_answer":"Answer",'
              '"explanation":"x","reasoning":"because"}',
        ))
            .outcome,
        ReviewRepairOutcome.invalidJson,
      );
      expect(
        (await run(response: '[{"question_number":21}]')).outcome,
        ReviewRepairOutcome.invalidJson,
      );
    });

    test('rejects a changed question number', () async {
      final result = await run(
        response: _response(
          questionNumber: 22,
          explanation: r'Fixed \(\begin{matrix}1\end{matrix}\)',
        ),
      );

      expect(result.outcome, ReviewRepairOutcome.questionIdentityChanged);
    });

    test('rejects a repair that changes an out-of-scope field', () async {
      final result = await run(
        response: _response(
          questionNumber: 21,
          content: 'Rewritten stem',
          explanation: r'Fixed \(\begin{matrix}1\end{matrix}\)',
        ),
      );

      expect(result.outcome, ReviewRepairOutcome.unexpectedFieldChange);
      expect(result.diagnostics, <String>['content']);
    });

    test('rejects an unchanged result', () async {
      final result = await run(response: _response(questionNumber: 21));

      expect(result.outcome, ReviewRepairOutcome.emptyResult);
    });

    test('rejects LaTeX that is still unrenderable', () async {
      final result = await run(
        response: _response(
          questionNumber: 21,
          explanation: r'Still broken \(\begin{matrix}1',
        ),
      );

      expect(result.outcome, ReviewRepairOutcome.latexStillInvalid);
    });

    test('rejects a structurally invalid repair', () async {
      final result = await run(
        request: _request(
            fields: const <ReviewRepairField>[
              ReviewRepairField.options,
            ],
            triggers: const <String>[
              'choice_options_less_than_2',
            ],
            type: QuestionType.singleChoice,
            options: const <String>['A. one']),
        response: _response(
          questionNumber: 21,
          options: const <String>['A. one'],
        ),
      );

      expect(result.outcome, ReviewRepairOutcome.emptyResult);
    });

    test('rejects an option count or label change', () async {
      final result = await run(
        request: _request(
          type: QuestionType.singleChoice,
          options: const <String>['A. one', 'B. two'],
          fields: const <ReviewRepairField>[ReviewRepairField.options],
          triggers: const <String>['latex_unrenderable'],
        ),
        response: _response(
          questionNumber: 21,
          options: const <String>['A. one'],
        ),
      );

      expect(result.outcome, ReviewRepairOutcome.unsupportedOptionChange);
    });

    test('rejects a field the typed snapshot cannot rebuild', () async {
      final snapshot = TypedReviewSnapshot(
        reviewItemId: '44444444-4444-4444-8444-000000000021',
        questionId: '22222222-2222-4222-8222-000000000021',
        draft: QuestionDraftV2(
          questionId: '22222222-2222-4222-8222-000000000021',
          kind: QuestionKind.shortAnswer,
          questionNumber: 21,
          stem: RichContent(nodes: <ContentNode>[const TextNode('Stem')]),
          answer: ContentAnswer(
            content:
                RichContent(nodes: <ContentNode>[const TextNode('Answer')]),
          ),
          explanation: RichContent(nodes: <ContentNode>[
            TableNode(
              structure: TableStructure(rows: <TableRow>[
                TableRow(cells: <TableCell>[
                  TableCell(
                    content: RichContent(
                      nodes: <ContentNode>[const TextNode('cell')],
                    ),
                  ),
                ]),
              ]),
            ),
          ]),
          sourceRefs: const <SourceRef>[],
        ),
        baselineLegacy: LegacyReviewBaseline(
          type: 3,
          questionNumber: 21,
          content: 'Stem',
          options: const <String>[],
          standardAnswer: 'Answer',
          explanation: _brokenExplanation,
        ),
      );

      final result = await run(
        response: _response(
          questionNumber: 21,
          explanation: r'Fixed \(\begin{matrix}1\end{matrix}\)',
        ),
        snapshot: snapshot,
      );

      expect(result.outcome, ReviewRepairOutcome.unsupportedTargetField);
      expect(result.diagnostics, <String>['explanation']);
    });

    test('rejects a repaired text that cannot become structure', () async {
      final snapshot = TypedReviewSnapshot(
        reviewItemId: '44444444-4444-4444-8444-000000000021',
        questionId: '22222222-2222-4222-8222-000000000021',
        draft: QuestionDraftV2(
          questionId: '22222222-2222-4222-8222-000000000021',
          kind: QuestionKind.shortAnswer,
          questionNumber: 21,
          stem: RichContent(nodes: <ContentNode>[const TextNode('Stem')]),
          answer: ContentAnswer(
            content:
                RichContent(nodes: <ContentNode>[const TextNode('Answer')]),
          ),
          explanation: RichContent(nodes: <ContentNode>[
            const TextNode('text'),
            const BlockMathNode('z=1'),
          ]),
          sourceRefs: const <SourceRef>[],
        ),
        baselineLegacy: LegacyReviewBaseline(
          type: 3,
          questionNumber: 21,
          content: 'Stem',
          options: const <String>[],
          standardAnswer: 'Answer',
          explanation: _brokenExplanation,
        ),
      );

      final result = await run(
        response: _response(
          questionNumber: 21,
          explanation: '见下图 ![image](https://example.invalid/a.png)',
        ),
        snapshot: snapshot,
      );

      expect(result.outcome, ReviewRepairOutcome.structuralInvalid);
    });

    test('carries bounded trigger and field context without source payloads',
        () async {
      final result = await run(
        response: _response(
          questionNumber: 21,
          explanation: r'Fixed \(\begin{matrix}1\end{matrix}\)',
        ),
      );

      expect(result.proposal!.request.target.triggerCodes, <String>[
        'latex_unrenderable',
      ]);
      expect(
        result.proposal!.request.reviewItemId,
        '44444444-4444-4444-8444-000000000021',
      );
      expect(result.proposal!.request.expectedRevision, 3);
    });
  });

  group('ReviewRepairProposal staleness', () {
    test('detects any later change to the captured question', () async {
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        apiClient: _ScriptedLlmApiClient(
          () async => _response(
            questionNumber: 21,
            explanation: r'Fixed \(\begin{matrix}1\end{matrix}\)',
          ),
        ),
      );
      final result = await service.generateProposal(request: _request());
      final proposal = result.proposal!;
      final input = proposal.request.inputDraft;

      expect(proposal.isStaleFor(input), isFalse);
      expect(
        proposal.isStaleFor(input.copyWith(explanation: 'changed')),
        isTrue,
      );
      expect(proposal.isStaleFor(input.copyWith(content: 'changed')), isTrue);
      expect(
        proposal.isStaleFor(input.copyWith(standardAnswer: 'changed')),
        isTrue,
      );
      expect(
        proposal.isStaleFor(input.copyWith(type: QuestionType.singleChoice)),
        isTrue,
      );
      expect(
        proposal.isStaleFor(input.copyWith(options: const <String>['A. x'])),
        isTrue,
      );
    });

    test('marker digests bind to the exact applied text', () {
      final before = QuestionDraft(
        type: QuestionType.shortAnswer,
        content: 'Stem',
        options: const <String>[],
        standardAnswer: 'Answer',
        explanation: _brokenExplanation,
      );
      final after = before.copyWith(
        explanation: r'Fixed \(\begin{matrix}1\end{matrix}\)',
      );
      final edit = ReviewRepairEdit.applied(before: before, after: after);

      expect(
        edit.isSatisfiedByDraft(ReviewRepairField.explanation, after),
        isTrue,
      );
      expect(
        edit.isSatisfiedByDraft(
          ReviewRepairField.explanation,
          after.copyWith(explanation: 'manually typed'),
        ),
        isFalse,
      );
    });
  });

  test('the proposal never mutates the captured input draft', () async {
    final request = _request();
    final service = ReviewRepairService(
      engineRepository: _FakeEngineRepository(_profile),
      apiClient: _ScriptedLlmApiClient(
        () async => _response(
          questionNumber: 21,
          explanation: r'Fixed \(\begin{matrix}1\end{matrix}\)',
        ),
      ),
    );

    final result = await service.generateProposal(request: request);

    expect(result.hasProposal, isTrue);
    expect(request.inputDraft.explanation, _brokenExplanation);
    expect(
      request.inputDraft.explanation,
      isNot(result.proposal!.proposedDraft.explanation),
    );
  });
}
