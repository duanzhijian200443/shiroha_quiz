// W0-A1 pure-application acceptance: the standalone proposal tool catalog
// and dispatcher. The persistence port is faked so no database, provider,
// network or private document is touched.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_write_proposal_tool_catalog.dart';
import 'package:shiroha_quiz/application/agent/agent_write_proposal_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_persistence.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal_service.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';

const _bankName = 'w0_a1_synthetic_bank';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';
const _conversationId = 'conv_a1_001';
const _messageId = 'msg_a1_user_001';

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

QuestionDraftV2 _choiceDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'w0_a1_choice_q',
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _text('Choice stem.'),
    options: <QuestionOption>[
      QuestionOption(optionId: 'opt_a', label: 'A', content: _text('first')),
      QuestionOption(optionId: 'opt_b', label: 'B', content: _text('second')),
      QuestionOption(optionId: 'opt_c', label: 'C', content: _text('third')),
    ],
    answer: answer,
    explanation: _text('Explanation.'),
  );
}

QuestionDraftV2 _contentDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'w0_a1_content_q',
    kind: QuestionKind.shortAnswer,
    questionNumber: 2,
    stem: _text('Content stem.'),
    answer: answer,
    explanation: _text('Explanation.'),
  );
}

class _FakePersistence implements AgentWritePersistencePort {
  _FakePersistence({required this.admissionResult});

  AgentWriteAdmissionResult admissionResult;
  final admissionRequests = <AgentWriteAdmissionRequest>[];
  final commitCalls = <AgentWriteCommitRequest>[];

  @override
  Future<AgentWriteAdmissionResult> admitStagingTarget(
    AgentWriteAdmissionRequest request,
  ) async {
    admissionRequests.add(request);
    return admissionResult;
  }

  @override
  Future<void> commitApproved(AgentWriteCommitRequest request) async {
    commitCalls.add(request);
  }
}

/// Returns one admission result per admission call, so one granted dispatch
/// consumes two entries (a dispatcher admission plus a staging admission).
/// Distinct entries let a test model snapshots that differ between the two
/// admission calls.
class _RotatingPersistence implements AgentWritePersistencePort {
  _RotatingPersistence(this._results);

  final List<AgentWriteAdmissionResult> _results;
  final commitCalls = <AgentWriteCommitRequest>[];
  int _admissionCalls = 0;

  @override
  Future<AgentWriteAdmissionResult> admitStagingTarget(
    AgentWriteAdmissionRequest request,
  ) async {
    final result = _results[_admissionCalls];
    _admissionCalls += 1;
    return result;
  }

  @override
  Future<void> commitApproved(AgentWriteCommitRequest request) async {
    commitCalls.add(request);
  }
}

AgentWriteProposalToolCall _call(String argumentsJson) {
  return AgentWriteProposalToolCall(
    argumentsJson: argumentsJson,
    sourceConversationId: _conversationId,
    sourceMessageId: _messageId,
    scope: ConversationScope.global(),
  );
}

String _choiceArguments(List<int> numbers) {
  return jsonEncode(<String, Object?>{
    'target': _storageId,
    'answer': <String, Object?>{'option_numbers': numbers},
  });
}

String _contentArguments(List<Map<String, Object?>> nodes) {
  return jsonEncode(<String, Object?>{
    'target': _storageId,
    'answer': <String, Object?>{
      'content': <String, Object?>{'nodes': nodes},
    },
  });
}

Map<String, Object?> _decoded(String response) {
  return jsonDecode(response) as Map<String, Object?>;
}

Map<String, Object?> _errorOf(String response) {
  return (_decoded(response)['error'] as Map<String, Object?>);
}

void main() {
  group('catalog', () {
    test(
        'exposes exactly one DRAFT/STAGE proposal tool with no approve or '
        'commit operation', () {
      expect(AgentWriteProposalToolCatalog.toolName, 'propose_missing_answer');
      expect(
        AgentWriteProposalToolCatalog.definition.name,
        'propose_missing_answer',
      );
      final schema = AgentWriteProposalToolCatalog.definition.inputSchema;
      expect(schema.containsKey('approve'), isFalse);
      expect(schema.containsKey('commit'), isFalse);
      expect(schema['required'], <Object?>['target', 'answer']);
    });
  });

  group('strict payload validation', () {
    late _FakePersistence persistence;
    late AgentWriteProposalToolDispatcher dispatcher;

    setUp(() {
      persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          AgentWriteAdmittedTarget(
            storageId: _storageId,
            bankName: _bankName,
            draft: _contentDraft(),
          ),
        ),
      );
      dispatcher = AgentWriteProposalToolDispatcher(
        persistence: persistence,
        proposalService: AgentWriteProposalService(persistence),
      );
    });

    test(
      'unknown, missing and duplicated keys fail as invalid_request',
      () async {
        final unknownKey = await dispatcher.dispatch(
          _call(
            jsonEncode(<String, Object?>{
              'target': _storageId,
              'answer': <String, Object?>{
                'option_numbers': <int>[1],
              },
              'extra': 'x',
            }),
          ),
        );
        expect(_errorOf(unknownKey)['code'], 'invalid_request');

        final missingAnswer = await dispatcher.dispatch(
          _call(jsonEncode(<String, Object?>{'target': _storageId})),
        );
        expect(_errorOf(missingAnswer)['code'], 'invalid_request');

        final bothKinds = await dispatcher.dispatch(
          _call(
            jsonEncode(<String, Object?>{
              'target': _storageId,
              'answer': <String, Object?>{
                'option_numbers': <int>[1],
                'content': <String, Object?>{
                  'nodes': <Map<String, Object?>>[
                    <String, Object?>{'type': 'text', 'text': 'x'},
                  ],
                },
              },
            }),
          ),
        );
        expect(_errorOf(bothKinds)['code'], 'invalid_request');
        expect(persistence.admissionRequests, isEmpty);
      },
    );

    test('malformed types and out-of-bounds sizes fail safely', () async {
      final badTarget = await dispatcher.dispatch(
        _call(
          jsonEncode(<String, Object?>{
            'target': 42,
            'answer': <String, Object?>{
              'option_numbers': <int>[1],
            },
          }),
        ),
      );
      expect(_errorOf(badTarget)['code'], 'invalid_request');

      final hugeTarget = await dispatcher.dispatch(
        _call(
          jsonEncode(<String, Object?>{
            'target': 'x' * 129,
            'answer': <String, Object?>{
              'option_numbers': <int>[1],
            },
          }),
        ),
      );
      expect(_errorOf(hugeTarget)['code'], 'invalid_request');

      final badNumbers = await dispatcher.dispatch(
        _call(
          jsonEncode(<String, Object?>{
            'target': _storageId,
            'answer': <String, Object?>{
              'option_numbers': <Object?>['1'],
            },
          }),
        ),
      );
      expect(_errorOf(badNumbers)['code'], 'invalid_request');

      final duplicateNumbers = await dispatcher.dispatch(
        _call(_choiceArguments(<int>[1, 1])),
      );
      expect(_errorOf(duplicateNumbers)['code'], 'invalid_request');

      final tooManyNumbers = await dispatcher.dispatch(
        _call(_choiceArguments(List<int>.generate(33, (i) => i + 1))),
      );
      expect(_errorOf(tooManyNumbers)['code'], 'invalid_request');
      expect(persistence.admissionRequests, isEmpty);
    });

    test(
      'unknown node types, unknown keys and oversized nodes fail safely',
      () async {
        final unknownType = await dispatcher.dispatch(
          _call(
            _contentArguments(<Map<String, Object?>>[
              <String, Object?>{'type': 'raw_fallback', 'payload': 'x'},
            ]),
          ),
        );
        expect(_errorOf(unknownType)['code'], 'invalid_request');

        final unknownKey = await dispatcher.dispatch(
          _call(
            _contentArguments(<Map<String, Object?>>[
              <String, Object?>{'type': 'text', 'text': 'x', 'extra': 'y'},
            ]),
          ),
        );
        expect(_errorOf(unknownKey)['code'], 'invalid_request');

        final missingField = await dispatcher.dispatch(
          _call(
            _contentArguments(<Map<String, Object?>>[
              <String, Object?>{'type': 'inline_math'},
            ]),
          ),
        );
        expect(_errorOf(missingField)['code'], 'invalid_request');

        final tooManyNodes = await dispatcher.dispatch(
          _call(
            _contentArguments(
              List<Map<String, Object?>>.generate(
                65,
                (i) => <String, Object?>{'type': 'text', 'text': 'x'},
              ),
            ),
          ),
        );
        expect(_errorOf(tooManyNodes)['code'], 'invalid_request');
        expect(persistence.admissionRequests, isEmpty);
      },
    );

    test(
      'malformed JSON and non-object arguments fail as invalid_request',
      () async {
        final badJson = await dispatcher.dispatch(_call('{corrupt'));
        expect(_errorOf(badJson)['code'], 'invalid_request');

        final listJson = await dispatcher.dispatch(_call('[1, 2]'));
        expect(_errorOf(listJson)['code'], 'invalid_request');
      },
    );
  });

  group('admission safety and conversion', () {
    test(
        'unauthorized, nonexistent and unreadable targets share one identical '
        'non-enumerating response', () async {
      final deniedDispatcher = AgentWriteProposalToolDispatcher(
        persistence: _FakePersistence(
          admissionResult: const AgentWriteAdmissionDenied(),
        ),
        proposalService: AgentWriteProposalService(
          _FakePersistence(admissionResult: const AgentWriteAdmissionDenied()),
        ),
      );
      final denied = await deniedDispatcher.dispatch(
        _call(
          _contentArguments(<Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'answer'},
          ]),
        ),
      );

      final unavailableDispatcher = AgentWriteProposalToolDispatcher(
        persistence: _FakePersistence(
          admissionResult: const AgentWriteAdmissionUnavailable(),
        ),
        proposalService: AgentWriteProposalService(
          _FakePersistence(
            admissionResult: const AgentWriteAdmissionUnavailable(),
          ),
        ),
      );
      final unavailable = await unavailableDispatcher.dispatch(
        _call(
          _contentArguments(<Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'answer'},
          ]),
        ),
      );

      expect(_errorOf(denied)['code'], 'not_found');
      expect(_errorOf(unavailable)['code'], 'not_found');
      expect(_errorOf(denied), _errorOf(unavailable));
      expect(denied, isNot(contains('a3f9c2e4')));
      expect(denied, isNot(contains('synthetic')));
    });

    test('option numbers convert to option ids in number order', () async {
      final persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          AgentWriteAdmittedTarget(
            storageId: _storageId,
            bankName: _bankName,
            draft: _choiceDraft(),
          ),
        ),
      );
      final service = AgentWriteProposalService(persistence);
      final dispatcher = AgentWriteProposalToolDispatcher(
        persistence: persistence,
        proposalService: service,
      );

      final response = await dispatcher.dispatch(
        _call(_choiceArguments(<int>[3, 1])),
      );
      final decoded = _decoded(response);
      expect(decoded['ok'], isTrue);
      final result = decoded['result'] as Map<String, Object?>;
      final proposalId = result['proposal_id'] as String;
      final proposal = service.proposalById(proposalId);
      expect(
        proposal.proposedAnswer,
        ChoiceAnswer(optionIds: <String>['opt_c', 'opt_a']),
      );
      final labels =
          ((result['preview'] as Map<String, Object?>)['proposed_answer']
              as Map<String, Object?>)['labels'] as List<Object?>;
      expect(labels, <Object?>['C', 'A']);
    });

    test(
        'out-of-range option numbers and already-answered targets are '
        'ineligible', () async {
      final outOfRangePersistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          AgentWriteAdmittedTarget(
            storageId: _storageId,
            bankName: _bankName,
            draft: _choiceDraft(),
          ),
        ),
      );
      final outOfRange = AgentWriteProposalToolDispatcher(
        persistence: outOfRangePersistence,
        proposalService: AgentWriteProposalService(outOfRangePersistence),
      );
      final response = await outOfRange.dispatch(
        _call(_choiceArguments(<int>[4])),
      );
      expect(_errorOf(response)['code'], 'ineligible');

      final answeredPersistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          AgentWriteAdmittedTarget(
            storageId: _storageId,
            bankName: _bankName,
            draft: _contentDraft(answer: ContentAnswer(content: _text('old'))),
          ),
        ),
      );
      final answered = AgentWriteProposalToolDispatcher(
        persistence: answeredPersistence,
        proposalService: AgentWriteProposalService(answeredPersistence),
      );
      final answeredResponse = await answered.dispatch(
        _call(
          _contentArguments(<Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'new'},
          ]),
        ),
      );
      expect(_errorOf(answeredResponse)['code'], 'ineligible');
    });
  });

  group('successful staging', () {
    late _FakePersistence persistence;
    late AgentWriteProposalService service;
    late AgentWriteProposalToolDispatcher dispatcher;

    setUp(() {
      persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          AgentWriteAdmittedTarget(
            storageId: _storageId,
            bankName: _bankName,
            draft: _contentDraft(),
          ),
        ),
      );
      service = AgentWriteProposalService(persistence);
      dispatcher = AgentWriteProposalToolDispatcher(
        persistence: persistence,
        proposalService: service,
      );
    });

    test(
      'stages a content proposal with an exact preview and no commit',
      () async {
        final response = await dispatcher.dispatch(
          _call(
            _contentArguments(<Map<String, Object?>>[
              <String, Object?>{'type': 'text', 'text': 'answer '},
              <String, Object?>{'type': 'inline_math', 'latex': 'x^2+1'},
            ]),
          ),
        );
        final decoded = _decoded(response);
        expect(decoded['ok'], isTrue);
        final result = decoded['result'] as Map<String, Object?>;
        expect(result['outcome'], 'pending');
        final proposalId = result['proposal_id'] as String;
        final proposal = service.proposalById(proposalId);
        final answer = proposal.proposedAnswer as ContentAnswer;
        expect(answer.content.nodes, hasLength(2));
        expect((answer.content.nodes[0] as TextNode).text, 'answer ');
        expect((answer.content.nodes[1] as InlineMathNode).latex, 'x^2+1');

        final preview = result['preview'] as Map<String, Object?>;
        expect(preview['bank_name'], _bankName);
        expect((preview['stem'] as List<Object?>), isNotEmpty);
        expect(
          ((preview['proposed_answer'] as Map<String, Object?>)['kind']),
          'content',
        );
        expect(persistence.commitCalls, isEmpty);
      },
    );

    test(
      'runtime source context is injected and never taken from arguments',
      () async {
        await dispatcher.dispatch(
          _call(
            _contentArguments(<Map<String, Object?>>[
              <String, Object?>{'type': 'text', 'text': 'answer'},
            ]),
          ),
        );

        // The dispatcher admits once to convert option numbers and the staging
        // service admits again inside stageProposal; both carry the
        // runtime-injected source context.
        expect(persistence.admissionRequests, hasLength(2));
        final request = persistence.admissionRequests.first;
        expect(request.sourceConversationId, _conversationId);
        expect(request.sourceMessageId, _messageId);
        expect(request.scope, ConversationScope.global());
        expect(request.targetStorageId, _storageId);
        expect(persistence.admissionRequests.last, request);
      },
    );

    test('semantic replay returns the same proposal id', () async {
      final arguments = _contentArguments(<Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': 'answer'},
      ]);
      final first = _decoded(await dispatcher.dispatch(_call(arguments)));
      final second = _decoded(await dispatcher.dispatch(_call(arguments)));

      expect(
        (first['result'] as Map<String, Object?>)['proposal_id'],
        (second['result'] as Map<String, Object?>)['proposal_id'],
      );
      expect((second['result'] as Map<String, Object?>)['outcome'], 'pending');
    });

    test(
      'semantic replay after approval reports the committed outcome',
      () async {
        final arguments = _contentArguments(<Map<String, Object?>>[
          <String, Object?>{'type': 'text', 'text': 'answer'},
        ]);
        final first = _decoded(await dispatcher.dispatch(_call(arguments)));
        final proposalId =
            (first['result'] as Map<String, Object?>)['proposal_id'] as String;
        await service.approveProposal(proposalId);

        final replay = _decoded(await dispatcher.dispatch(_call(arguments)));
        final replayResult = replay['result'] as Map<String, Object?>;
        expect(replayResult['proposal_id'], proposalId);
        expect(replayResult['outcome'], 'committed');
      },
    );
  });

  group('proposal validity and result-size safety', () {
    test(
      'kind mismatch and blank math are ineligible through the tool',
      () async {
        final choicePersistence = _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            AgentWriteAdmittedTarget(
              storageId: _storageId,
              bankName: _bankName,
              draft: _choiceDraft(),
            ),
          ),
        );
        final choiceDispatcher = AgentWriteProposalToolDispatcher(
          persistence: choicePersistence,
          proposalService: AgentWriteProposalService(choicePersistence),
        );

        final mismatch = await choiceDispatcher.dispatch(
          _call(
            _contentArguments(<Map<String, Object?>>[
              <String, Object?>{'type': 'text', 'text': 'answer'},
            ]),
          ),
        );
        expect(_errorOf(mismatch)['code'], 'ineligible');

        final blankMath = await choiceDispatcher.dispatch(
          _call(
            _contentArguments(<Map<String, Object?>>[
              <String, Object?>{'type': 'inline_math', 'latex': '   '},
            ]),
          ),
        );
        expect(_errorOf(blankMath)['code'], 'ineligible');
      },
    );

    test(
        'oversized tool result never stages and never supersedes a pending '
        'proposal', () async {
      final persistence = _RotatingPersistence(<AgentWriteAdmissionResult>[
        // First dispatch: both admissions see the small draft and stage a
        // pending proposal.
        AgentWriteAdmissionGranted(
          AgentWriteAdmittedTarget(
            storageId: _storageId,
            bankName: _bankName,
            draft: _contentDraft(),
          ),
        ),
        AgentWriteAdmissionGranted(
          AgentWriteAdmittedTarget(
            storageId: _storageId,
            bankName: _bankName,
            draft: _contentDraft(),
          ),
        ),
        // Second dispatch: the dispatcher admission still sees the small
        // draft, but the staging admission sees an oversized draft. The
        // exact candidate result therefore overflows even though the first
        // admission snapshot would pass a preflight sized on admission #1.
        AgentWriteAdmissionGranted(
          AgentWriteAdmittedTarget(
            storageId: _storageId,
            bankName: _bankName,
            draft: _contentDraft(),
          ),
        ),
        AgentWriteAdmissionGranted(
          AgentWriteAdmittedTarget(
            storageId: _storageId,
            bankName: _bankName,
            draft: QuestionDraftV2(
              questionId: 'w0_a1_huge_q',
              kind: QuestionKind.shortAnswer,
              questionNumber: 2,
              stem: RichContent(nodes: <ContentNode>[TextNode('x' * 70000)]),
            ),
          ),
        ),
      ]);
      final service = AgentWriteProposalService(persistence);
      final dispatcher = AgentWriteProposalToolDispatcher(
        persistence: persistence,
        proposalService: service,
      );
      final arguments = _contentArguments(<Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': 'answer'},
      ]);

      final first = _decoded(await dispatcher.dispatch(_call(arguments)));
      expect(first['ok'], isTrue);
      final firstId =
          (first['result'] as Map<String, Object?>)['proposal_id'] as String;
      expect(
        service.proposalById(firstId).outcome,
        AgentWriteProposalOutcome.pending,
      );

      final overflow = await dispatcher.dispatch(_call(arguments));
      expect(_errorOf(overflow)['code'], 'internal_error');
      expect(overflow, isNot(contains('proposal_id')));
      expect(
        service.proposalById(firstId).outcome,
        AgentWriteProposalOutcome.pending,
        reason: 'A failed result-size gate must not supersede the previous '
            'pending proposal or leave a hidden active proposal.',
      );
      expect(persistence.commitCalls, isEmpty);
    });

    test(
      'success result preview derives from the staged proposal when '
      'admission snapshots differ',
      () async {
        final persistence = _RotatingPersistence(<AgentWriteAdmissionResult>[
          AgentWriteAdmissionGranted(
            AgentWriteAdmittedTarget(
              storageId: _storageId,
              bankName: _bankName,
              draft: QuestionDraftV2(
                questionId: 'w0_a1_first_q',
                kind: QuestionKind.shortAnswer,
                questionNumber: 2,
                stem: _text('First admitted stem.'),
              ),
            ),
          ),
          AgentWriteAdmissionGranted(
            AgentWriteAdmittedTarget(
              storageId: _storageId,
              bankName: _bankName,
              draft: QuestionDraftV2(
                questionId: 'w0_a1_second_q',
                kind: QuestionKind.shortAnswer,
                questionNumber: 2,
                stem: _text('Second admitted stem.'),
              ),
            ),
          ),
        ]);
        final service = AgentWriteProposalService(persistence);
        final dispatcher = AgentWriteProposalToolDispatcher(
          persistence: persistence,
          proposalService: service,
        );

        final decoded = _decoded(
          await dispatcher.dispatch(
            _call(_contentArguments(<Map<String, Object?>>[
              <String, Object?>{'type': 'text', 'text': 'answer'},
            ])),
          ),
        );
        expect(decoded['ok'], isTrue);
        final result = decoded['result'] as Map<String, Object?>;
        final proposalId = result['proposal_id'] as String;
        final proposal = service.proposalById(proposalId);

        // Preview/identity/outcome come from the exact staged proposal (the
        // second admission), never from the dispatcher's first admission.
        expect(
          (result['preview'] as Map<String, Object?>)['stem'],
          <Object?>[
            <String, Object?>{
              'type': 'text',
              'text': 'Second admitted stem.',
            },
          ],
        );
        expect(
          (proposal.preview.stem.nodes.single as TextNode).text,
          'Second admitted stem.',
        );
        expect(result['outcome'], 'pending');
      },
    );
  });
}
