// Proposal-first review repair contract: provider-neutral outcomes, local
// canonicalization, structural and LaTeX validation, and zero mutation of the
// reviewed question. Synthetic fixtures only; no Provider, Replay, network,
// database or filesystem.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/latex_fragment_repair_provider.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
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
const String _fragmentLegacy = r'前 \(a\) 中 \(\begin{matrix}1\) 后 \(c\)';
const String _fragmentReplacement = r'\begin{matrix}1\end{matrix}';

class _MemoryLogSink implements LogSink {
  final List<LogRecord> records = <LogRecord>[];

  @override
  Future<void> write(LogRecord record) async {
    records.add(record);
  }

  @override
  Future<void> flush() async {}
}

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

class _FakeFragmentProvider implements LatexFragmentRepairProviderPort {
  _FakeFragmentProvider({
    this.result,
    this.failure,
  });

  final String? result;
  final LatexFragmentProviderFailure? failure;
  int calls = 0;
  LatexFragmentProviderRequest? lastRequest;

  @override
  Future<LatexFragmentProviderResult> repair(
    LatexFragmentProviderRequest request, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    calls++;
    lastRequest = request;
    final failure = this.failure;
    if (failure != null) throw LatexFragmentProviderException(failure);
    return LatexFragmentProviderResult(
      correctedLatex: result ?? _fragmentReplacement,
      providerProfileId: 'fragment-engine',
    );
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

ReviewRepairRequest _fragmentRequest({
  String explanation = _fragmentLegacy,
}) {
  return ReviewRepairRequest(
    target: ReviewRepairTarget(
      originalIndex: 20,
      questionNumber: 21,
      triggerCodes: const <String>['latex_unrenderable'],
      fields: const <ReviewRepairField>[ReviewRepairField.explanation],
      strategy: ReviewRepairStrategy.latexFragment,
    ),
    reviewItemId: '44444444-4444-4444-8444-000000000021',
    inputDraft: QuestionDraft(
      type: QuestionType.shortAnswer,
      content: 'Stem',
      options: const <String>[],
      standardAnswer: 'Answer',
      explanation: explanation,
    ),
    expectedRevision: 7,
  );
}

TypedReviewSnapshot _fragmentSnapshot({
  String legacy = _fragmentLegacy,
  List<ContentNode>? explanationNodes,
}) {
  return TypedReviewSnapshot(
    reviewItemId: '44444444-4444-4444-8444-000000000021',
    questionId: '22222222-2222-4222-8222-000000000021',
    draft: QuestionDraftV2(
      questionId: '22222222-2222-4222-8222-000000000021',
      kind: QuestionKind.shortAnswer,
      questionNumber: 21,
      stem: RichContent(nodes: const <ContentNode>[TextNode('Stem')]),
      answer: ContentAnswer(
        content: RichContent(nodes: const <ContentNode>[TextNode('Answer')]),
      ),
      explanation: RichContent(
        nodes: explanationNodes ??
            const <ContentNode>[
              TextNode('前 '),
              InlineMathNode('a'),
              TextNode(' 中 '),
              InlineMathNode(r'\begin{matrix}1'),
              TextNode(' 后 '),
              InlineMathNode('c'),
            ],
      ),
    ),
    baselineLegacy: LegacyReviewBaseline(
      type: 3,
      questionNumber: 21,
      content: 'Stem',
      options: const <String>[],
      standardAnswer: 'Answer',
      explanation: legacy,
    ),
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
  tearDown(() {
    AppLogger.setSink(null);
  });

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
      final malformed = await run(response: 'not json at all');
      final extraKey = await run(
        response: '{"question_number":21,"content":"Stem",'
            '"options":[],"standard_answer":"Answer",'
            '"explanation":"x","reasoning":"because"}',
      );
      final nonObject = await run(response: '[{"question_number":21}]');

      expect(malformed.outcome, ReviewRepairOutcome.invalidJson);
      expect(malformed.diagnostics, <String>['repair_json_decode_failed']);
      expect(extraKey.outcome, ReviewRepairOutcome.invalidJson);
      expect(extraKey.diagnostics, <String>['repair_extra_keys']);
      expect(nonObject.outcome, ReviewRepairOutcome.invalidJson);
      expect(nonObject.diagnostics, <String>['repair_non_object']);
    });

    test('logs only bounded metadata for repair response parsing', () async {
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);
      const promptSentinel = 'PRIVATE_Q21_PROMPT_BODY';
      const responseSentinel = 'PRIVATE_PROVIDER_RESPONSE_BODY';
      const latexSentinel = r'PRIVATE_LATEX_\(\begin{matrix}';
      const apiKeySentinel = 'PRIVATE_API_KEY_VALUE';
      const baseUrlSentinel = 'https://private-provider.invalid/v1';
      const privateProfile = AiEngineProfile(
        id: 'private-test',
        engineType: AiEngineType.text,
        name: 'private-test',
        apiKey: apiKeySentinel,
        baseUrl: baseUrlSentinel,
        modelName: 'model',
        temperature: 0,
        reasoningEffort: '',
        isActive: true,
      );

      final result = await run(
        engineRepository: _FakeEngineRepository(privateProfile),
        request: _request(
          content: promptSentinel,
          explanation: latexSentinel,
        ),
        response: _response(
          questionNumber: 21,
          content: promptSentinel,
          explanation: responseSentinel,
          extra: const <String, Object?>{'unexpected': 'private-extra-value'},
        ),
      );
      await AppLogger.flush();

      expect(result.outcome, ReviewRepairOutcome.invalidJson);
      expect(result.diagnostics, <String>['repair_extra_keys']);
      expect(sink.records, hasLength(1));
      final record = sink.records.single;
      expect(record.module, 'ReviewRepair');
      expect(record.data, containsPair('providerKind', 'openAiCompatible'));
      expect(record.data, containsPair('modelId', 'model'));
      expect(
        record.data,
        containsPair('repairContentJsonDecodeSucceeded', true),
      );
      expect(record.data, containsPair('decodedTopLevelType', 'object'));
      expect(record.data, containsPair('contractExtraKeyCount', 1));
      expect(record.data, containsPair('contractMissingKeyCount', 0));
      expect(
        record.data,
        containsPair('failureClassification', 'repair_extra_keys'),
      );

      final encoded = jsonEncode(record.toJson());
      for (final forbidden in <String>[
        promptSentinel,
        responseSentinel,
        latexSentinel,
        'private-extra-value',
        apiKeySentinel,
        baseUrlSentinel,
      ]) {
        expect(encoded, isNot(contains(forbidden)),
            reason: 'Leaked: $forbidden');
      }
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

  group('LaTeX fragment strategy', () {
    test('repairs only the unique invalid node with adjacent context',
        () async {
      final provider = _FakeFragmentProvider();
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        fragmentProvider: provider,
      );

      final result = await service.generateProposal(
        request: _fragmentRequest(),
        snapshot: _fragmentSnapshot(),
      );

      expect(result.outcome, ReviewRepairOutcome.proposalReady);
      expect(provider.calls, 1);
      expect(provider.lastRequest!.originalLatex, r'\begin{matrix}1');
      expect(provider.lastRequest!.precedingContext, ' 中 ');
      expect(provider.lastRequest!.followingContext, ' 后 ');
      expect(
        result.proposal!.proposedDraft.explanation,
        r'前 \(a\) 中 \(\begin{matrix}1\end{matrix}\) 后 \(c\)',
      );
      expect(result.proposal!.fragment, isNotNull);
      expect(result.proposal!.fragment!.target.nodeIndex, 3);
      expect(
        result.proposal!.changedFields,
        const <ReviewRepairField>[ReviewRepairField.explanation],
      );
    });

    test('missing snapshot and baseline drift make zero provider calls',
        () async {
      final provider = _FakeFragmentProvider();
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        fragmentProvider: provider,
      );

      final missing = await service.generateProposal(
        request: _fragmentRequest(),
      );
      final drifted = await service.generateProposal(
        request: _fragmentRequest(explanation: 'changed'),
        snapshot: _fragmentSnapshot(),
      );

      expect(
        missing.outcome,
        ReviewRepairOutcome.fragmentTargetUnavailable,
      );
      expect(
        drifted.outcome,
        ReviewRepairOutcome.fragmentTargetUnavailable,
      );
      expect(missing.diagnostics, <String>['snapshot_missing']);
      expect(drifted.diagnostics, <String>['baseline_drift']);
      expect(provider.calls, 0);
    });

    test('target diagnostics expose only bounded shape metadata', () async {
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);
      final provider = _FakeFragmentProvider();
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        fragmentProvider: provider,
      );

      final result = await service.generateProposal(
        request: _fragmentRequest(
          explanation: r'PRIVATE_SENTINEL \(changed\)',
        ),
        snapshot: _fragmentSnapshot(),
      );
      await AppLogger.flush();
      final logs = jsonEncode(
        sink.records.map((record) => record.toJson()).toList(),
      );

      expect(result.diagnostics, <String>['baseline_drift']);
      expect(logs, contains('baseline_drift'));
      expect(logs, contains('typedNodeCount'));
      expect(logs, contains('candidateCount'));
      expect(logs, isNot(contains('PRIVATE_SENTINEL')));
      expect(logs, isNot(contains(_fragmentLegacy)));
      expect(logs, isNot(contains(_fragmentReplacement)));
      expect(provider.calls, 0);
    });

    test('non-target normalization mismatch still repairs the unique bad node',
        () async {
      const legacy = r'前 \(alpha\) 中 \(\begin{matrix}1\) 后 \(c\)';
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);
      final provider = _FakeFragmentProvider();
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        fragmentProvider: provider,
      );

      final result = await service.generateProposal(
        request: _fragmentRequest(explanation: legacy),
        snapshot: _fragmentSnapshot(legacy: legacy),
      );
      await AppLogger.flush();
      final logs = jsonEncode(
        sink.records.map((record) => record.toJson()).toList(),
      );

      expect(result.outcome, ReviewRepairOutcome.proposalReady);
      expect(result.hasProposal, isTrue);
      expect(provider.calls, 1);
      expect(provider.lastRequest!.originalLatex, r'\begin{matrix}1');
      expect(logs, isNot(contains(r'\begin{matrix}')));
      expect(logs, isNot(contains('alpha')));
    });

    test('typed bad but legacy-valid target makes zero provider calls',
        () async {
      const legacy = r'前 \(a\) 中 \(x^2\) 后 \(c\)';
      final provider = _FakeFragmentProvider();
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        fragmentProvider: provider,
      );

      final result = await service.generateProposal(
        request: _fragmentRequest(explanation: legacy),
        snapshot: _fragmentSnapshot(legacy: legacy),
      );

      expect(result.outcome, ReviewRepairOutcome.fragmentTargetUnavailable);
      expect(
        result.diagnostics,
        <String>['target_legacy_renderability_mismatch'],
      );
      expect(provider.calls, 0);
    });

    test('multiple invalid nodes make zero provider calls', () async {
      const legacy = r'前 \(\begin{matrix}1\) 后 \(\begin{array}2\)';
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);
      final provider = _FakeFragmentProvider();
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        fragmentProvider: provider,
      );

      final result = await service.generateProposal(
        request: _fragmentRequest(explanation: legacy),
        snapshot: _fragmentSnapshot(
          legacy: legacy,
          explanationNodes: const <ContentNode>[
            TextNode('前 '),
            InlineMathNode(r'\begin{matrix}1'),
            TextNode(' 后 '),
            InlineMathNode(r'\begin{array}2'),
          ],
        ),
      );
      await AppLogger.flush();
      final logs = jsonEncode(
        sink.records.map((record) => record.toJson()).toList(),
      );

      expect(
        result.outcome,
        ReviewRepairOutcome.fragmentTargetUnavailable,
      );
      expect(result.diagnostics, <String>['candidate_multiple']);
      expect(logs, contains('candidate_multiple'));
      expect(logs, contains('"candidateCount":2'));
      expect(logs, contains('"nodeKind":"inline_math"'));
      expect(logs, isNot(contains(r'\begin{matrix}')));
      expect(logs, isNot(contains(r'\begin{array}')));
      expect(provider.calls, 0);
    });

    test('typed provider failures keep their diagnostic classification',
        () async {
      final provider = _FakeFragmentProvider(
        failure: LatexFragmentProviderFailure.providerFinishLength,
      );
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        fragmentProvider: provider,
      );

      final result = await service.generateProposal(
        request: _fragmentRequest(),
        snapshot: _fragmentSnapshot(),
      );

      expect(result.outcome, ReviewRepairOutcome.invalidFragmentOutput);
      expect(result.diagnostics, <String>['provider_finish_length']);
      expect(provider.calls, 1);
    });

    test('malformed replacement is rejected by the local fragment checker',
        () async {
      final provider = _FakeFragmentProvider(result: r'\begin{array}');
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        fragmentProvider: provider,
      );

      final result = await service.generateProposal(
        request: _fragmentRequest(),
        snapshot: _fragmentSnapshot(),
      );

      expect(
        result.outcome,
        ReviewRepairOutcome.fragmentRenderabilityFailed,
      );
      expect(result.hasProposal, isFalse);
    });

    test('a replacement that changes token topology cannot become a proposal',
        () async {
      final provider = _FakeFragmentProvider(result: r'x + \(y\)');
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        fragmentProvider: provider,
      );

      final result = await service.generateProposal(
        request: _fragmentRequest(),
        snapshot: _fragmentSnapshot(),
      );

      expect(result.outcome, ReviewRepairOutcome.invalidFragmentOutput);
      expect(result.diagnostics, <String>['fragment_topology_changed']);
      expect(result.hasProposal, isFalse);
      expect(provider.calls, 1);
    });

    test('a fragment fix that leaves the full field invalid is rejected',
        () async {
      const legacy = r'前 \left \(\begin{matrix}1\) 后';
      final provider = _FakeFragmentProvider();
      final service = ReviewRepairService(
        engineRepository: _FakeEngineRepository(_profile),
        fragmentProvider: provider,
      );

      final result = await service.generateProposal(
        request: _fragmentRequest(explanation: legacy),
        snapshot: _fragmentSnapshot(
          legacy: legacy,
          explanationNodes: const <ContentNode>[
            TextNode(r'前 \left '),
            InlineMathNode(r'\begin{matrix}1'),
            TextNode(' 后'),
          ],
        ),
      );

      expect(result.outcome, ReviewRepairOutcome.fieldReauditFailed);
      expect(result.hasProposal, isFalse);
      expect(provider.calls, 1);
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
