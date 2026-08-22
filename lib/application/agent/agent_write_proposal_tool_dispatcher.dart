/// Proposal tool dispatcher for the built-in Agent's W0 DRAFT/STAGE
/// capability.
///
/// The dispatcher holds only Application seams (the admission persistence
/// port and the transient proposal service) and never reaches data-layer
/// repositories, the low-level database API or the MCP transport. Payload
/// validation is strict and exact-key; malformed, oversized or unknown
/// content fails with a bounded safe response, and unauthorized/nonexistent
/// targets share one identical non-enumerating response.
library;

import 'dart:convert';

import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/question/question_draft_v2.dart';
import '../safe_write/agent_write_persistence.dart';
import '../safe_write/agent_write_proposal.dart';
import '../safe_write/agent_write_proposal_service.dart';
import 'agent_runtime_limits.dart';

/// One proposal tool call with the runtime-injected source context. The
/// model never supplies or overrides the source Conversation/Message
/// identity.
final class AgentWriteProposalToolCall {
  const AgentWriteProposalToolCall({
    required this.argumentsJson,
    required this.sourceConversationId,
    required this.sourceMessageId,
    required this.scope,
  });

  final String argumentsJson;
  final String sourceConversationId;
  final String sourceMessageId;
  final ConversationScope scope;
}

final class AgentWriteProposalToolDispatcher {
  AgentWriteProposalToolDispatcher({
    required AgentWritePersistencePort persistence,
    required AgentWriteProposalService proposalService,
    AgentRuntimeLimits limits = const AgentRuntimeLimits(),
  })  : _persistence = persistence,
        _proposalService = proposalService,
        _limits = limits;

  final AgentWritePersistencePort _persistence;
  final AgentWriteProposalService _proposalService;
  final AgentRuntimeLimits _limits;

  static const int _maxTargetRunes = 128;
  static const int _maxOptionNumbers = 32;
  static const int _maxContentNodes = 64;
  static const int _maxTextRunes = 2048;
  static const int _maxLatexRunes = 1024;

  Future<String> dispatch(
    AgentWriteProposalToolCall call, {
    bool Function()? proposalMutationAllowed,
  }) async {
    if (utf8.encode(call.argumentsJson).length >
        _limits.maxToolArgumentUtf8Bytes) {
      return _failure(_ToolFailure.invalidRequest);
    }
    final Map<String, dynamic> arguments;
    try {
      final decoded = jsonDecode(call.argumentsJson);
      if (decoded is! Map<String, dynamic>) {
        return _failure(_ToolFailure.invalidRequest);
      }
      arguments = decoded;
    } on FormatException {
      return _failure(_ToolFailure.invalidRequest);
    }
    try {
      final parsed = _parseArguments(arguments);
      final result = await _handle(
        parsed,
        call,
        proposalMutationAllowed: proposalMutationAllowed,
      );
      final encoded = jsonEncode(<String, Object?>{
        'ok': true,
        'result': result,
      });
      if (utf8.encode(encoded).length > _limits.maxToolResultUtf8Bytes) {
        return _failure(_ToolFailure.internal);
      }
      return encoded;
    } on AgentWriteStageResultTooLargeException {
      // The pre-activation result-size gate rejected the exact candidate
      // before any lifecycle mutation; the transport can never deliver it.
      return _failure(_ToolFailure.internal);
    } on AgentWriteStageCancelledException {
      // A runtime timeout/cancellation guard refused the final synchronous
      // activation gate. The enclosing turn owns the visible failure; this
      // bounded response is relevant only if dispatch is still observed.
      return _failure(_ToolFailure.internal);
    } on _ToolFailureException catch (error) {
      return _failure(error.failure);
    } on ArgumentError {
      return _failure(_ToolFailure.invalidRequest);
    } catch (_) {
      return _failure(_ToolFailure.internal);
    }
  }

  Future<Map<String, Object?>> _handle(
    _ParsedToolArguments parsed,
    AgentWriteProposalToolCall call, {
    bool Function()? proposalMutationAllowed,
  }) async {
    final request = AgentWriteAdmissionRequest(
      sourceConversationId: call.sourceConversationId,
      sourceMessageId: call.sourceMessageId,
      scope: call.scope,
      targetStorageId: parsed.targetStorageId,
    );
    final admission = await _persistence.admitStagingTarget(request);
    if (admission is! AgentWriteAdmissionGranted) {
      // Unauthorized, nonexistent and unreadable targets share one safe
      // non-enumerating tool response without target identity or content.
      throw const _ToolFailureException(_ToolFailure.unavailable);
    }
    final target = admission.target;
    final QuestionAnswer answer;
    final numbers = parsed.payload.optionNumbers;
    if (numbers != null) {
      if (numbers.any((number) => number > target.draft.options.length)) {
        throw const _ToolFailureException(_ToolFailure.ineligible);
      }
      answer = ChoiceAnswer(
        optionIds: <String>[
          for (final number in numbers)
            target.draft.options[number - 1].optionId,
        ],
      );
    } else {
      answer = ContentAnswer(
        content: RichContent(nodes: parsed.payload.contentNodes!),
      );
    }
    final staged = await _proposalService.stageProposal(
      admissionRequest: request,
      proposedAnswer: answer,
      resultSizeGate: _resultFits,
      lifecycleMutationAllowed: proposalMutationAllowed,
    );
    switch (staged) {
      case AgentWriteStageResultStaged(:final proposal):
        return _successResult(proposal);
      case AgentWriteStageResultDenied() || AgentWriteStageResultUnavailable():
        throw const _ToolFailureException(_ToolFailure.unavailable);
      case AgentWriteStageResultIneligible():
        throw const _ToolFailureException(_ToolFailure.ineligible);
    }
  }

  /// Returns whether the exact encoded tool result for [candidate] fits the
  /// transport limit.
  ///
  /// [candidate] is the exact proposal the service would activate (real
  /// proposal id, frozen preview and current pending outcome), so the
  /// encoding is byte-identical to the eventual success result. The service
  /// invokes this gate before any lifecycle mutation, so an oversized result
  /// can never leave a hidden pending proposal or supersede an older one.
  /// The post-encoding check in [dispatch] remains only as defense-in-depth
  /// (for example replay results whose outcome spelling differs).
  bool _resultFits(AgentWriteProposal candidate) {
    final encoded = jsonEncode(<String, Object?>{
      'ok': true,
      'result': _successResult(candidate),
    });
    return utf8.encode(encoded).length <= _limits.maxToolResultUtf8Bytes;
  }

  _ParsedToolArguments _parseArguments(Map<String, dynamic> arguments) {
    if (arguments.keys.length != 2 ||
        !arguments.containsKey('target') ||
        !arguments.containsKey('answer')) {
      throw const _ToolFailureException(_ToolFailure.invalidRequest);
    }
    final target = arguments['target'];
    if (target is! String ||
        target.trim().isEmpty ||
        target.runes.length > _maxTargetRunes) {
      throw const _ToolFailureException(_ToolFailure.invalidRequest);
    }
    final answer = arguments['answer'];
    if (answer is! Map) {
      throw const _ToolFailureException(_ToolFailure.invalidRequest);
    }
    final answerMap = Map<String, dynamic>.from(answer);
    if (answerMap.keys.length != 1) {
      throw const _ToolFailureException(_ToolFailure.invalidRequest);
    }
    if (answerMap.containsKey('option_numbers')) {
      return _ParsedToolArguments(
        targetStorageId: target,
        payload: _ProposalToolPayload(
          optionNumbers: _parseOptionNumbers(answerMap['option_numbers']),
        ),
      );
    }
    if (answerMap.containsKey('content')) {
      final content = answerMap['content'];
      if (content is! Map) {
        throw const _ToolFailureException(_ToolFailure.invalidRequest);
      }
      final contentMap = Map<String, dynamic>.from(content);
      if (contentMap.keys.length != 1 || !contentMap.containsKey('nodes')) {
        throw const _ToolFailureException(_ToolFailure.invalidRequest);
      }
      return _ParsedToolArguments(
        targetStorageId: target,
        payload: _ProposalToolPayload(
          contentNodes: _parseContentNodes(contentMap['nodes']),
        ),
      );
    }
    throw const _ToolFailureException(_ToolFailure.invalidRequest);
  }

  List<int> _parseOptionNumbers(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.length > _maxOptionNumbers) {
      throw const _ToolFailureException(_ToolFailure.invalidRequest);
    }
    final numbers = <int>[];
    for (final item in raw) {
      if (item is! int || item < 1) {
        throw const _ToolFailureException(_ToolFailure.invalidRequest);
      }
      numbers.add(item);
    }
    if (numbers.toSet().length != numbers.length) {
      throw const _ToolFailureException(_ToolFailure.invalidRequest);
    }
    return numbers;
  }

  List<ContentNode> _parseContentNodes(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.length > _maxContentNodes) {
      throw const _ToolFailureException(_ToolFailure.invalidRequest);
    }
    final nodes = <ContentNode>[];
    for (final item in raw) {
      if (item is! Map) {
        throw const _ToolFailureException(_ToolFailure.invalidRequest);
      }
      final nodeMap = Map<String, dynamic>.from(item);
      final type = nodeMap['type'];
      if (type is! String) {
        throw const _ToolFailureException(_ToolFailure.invalidRequest);
      }
      switch (type) {
        case 'text':
          if (nodeMap.keys.length != 2 || !nodeMap.containsKey('text')) {
            throw const _ToolFailureException(_ToolFailure.invalidRequest);
          }
          final text = nodeMap['text'];
          if (text is! String || text.runes.length > _maxTextRunes) {
            throw const _ToolFailureException(_ToolFailure.invalidRequest);
          }
          nodes.add(TextNode(text));
        case 'inline_math':
          if (nodeMap.keys.length != 2 || !nodeMap.containsKey('latex')) {
            throw const _ToolFailureException(_ToolFailure.invalidRequest);
          }
          nodes.add(InlineMathNode(_mathLatex(nodeMap['latex'])));
        case 'block_math':
          if (nodeMap.keys.length != 2 || !nodeMap.containsKey('latex')) {
            throw const _ToolFailureException(_ToolFailure.invalidRequest);
          }
          nodes.add(BlockMathNode(_mathLatex(nodeMap['latex'])));
        default:
          // Unknown node types, including any raw fallback, fail safely.
          throw const _ToolFailureException(_ToolFailure.invalidRequest);
      }
    }
    return nodes;
  }

  String _mathLatex(Object? raw) {
    if (raw is! String || raw.runes.length > _maxLatexRunes) {
      throw const _ToolFailureException(_ToolFailure.invalidRequest);
    }
    return raw;
  }

  /// Builds the success payload exclusively from the exact staged [proposal]
  /// preview, identity and outcome returned by the service, so the tool
  /// result can never show a snapshot different from the one the proposal
  /// fingerprint/expectedDraft/approval path uses.
  Map<String, Object?> _successResult(AgentWriteProposal proposal) {
    return <String, Object?>{
      'proposal_id': proposal.id,
      'outcome': _outcomeOf(proposal.outcome),
      'preview': <String, Object?>{
        'bank_name': proposal.preview.bankName,
        'stem': <Map<String, Object?>>[
          for (final node in proposal.preview.stem.nodes) _nodeOf(node),
        ],
        'options': <Map<String, Object?>>[
          for (final option in proposal.preview.options)
            <String, Object?>{
              'label': option.label,
              'content': <Map<String, Object?>>[
                for (final node in option.content.nodes) _nodeOf(node),
              ],
            },
        ],
        'proposed_answer': _answerOf(
          proposal.preview.proposedAnswer,
          proposal.preview.options,
        ),
      },
    };
  }

  /// Stable tool-surface string for the proposal lifecycle outcome. Semantic
  /// replay returns the existing proposal with its current outcome, so the
  /// tool result must never hardcode a pending state.
  String _outcomeOf(AgentWriteProposalOutcome outcome) {
    return switch (outcome) {
      AgentWriteProposalOutcome.pending => 'pending',
      AgentWriteProposalOutcome.committing => 'committing',
      AgentWriteProposalOutcome.committed => 'committed',
      AgentWriteProposalOutcome.rejected => 'rejected',
      AgentWriteProposalOutcome.superseded => 'superseded',
      AgentWriteProposalOutcome.stale => 'stale',
      AgentWriteProposalOutcome.invalid => 'invalid',
      AgentWriteProposalOutcome.unknownOutcome => 'unknown_outcome',
    };
  }

  Map<String, Object?> _answerOf(
    QuestionAnswer answer,
    List<QuestionOption> options,
  ) {
    return switch (answer) {
      ChoiceAnswer(:final optionIds) => <String, Object?>{
          'kind': 'choice',
          'labels': <String>[
            for (final optionId in optionIds) _labelOf(optionId, options),
          ],
        },
      ContentAnswer(:final content) => <String, Object?>{
          'kind': 'content',
          'nodes': <Map<String, Object?>>[
            for (final node in content.nodes) _nodeOf(node),
          ],
        },
    };
  }

  String _labelOf(String optionId, List<QuestionOption> options) {
    for (final option in options) {
      if (option.optionId == optionId) return option.label;
    }
    return optionId;
  }

  Map<String, Object?> _nodeOf(ContentNode node) {
    return switch (node) {
      TextNode(:final text) => <String, Object?>{'type': 'text', 'text': text},
      InlineMathNode(:final latex) => <String, Object?>{
          'type': 'inline_math',
          'latex': latex,
        },
      BlockMathNode(:final latex) => <String, Object?>{
          'type': 'block_math',
          'latex': latex,
        },
      ImageNode() || TableNode() => <String, Object?>{'type': 'unsupported'},
      RawFallbackNode() => <String, Object?>{'type': 'unsupported'},
    };
  }

  String _failure(_ToolFailure failure) {
    final (code, message) = switch (failure) {
      _ToolFailure.invalidRequest => (
          'invalid_request',
          'The proposal request is invalid.',
        ),
      _ToolFailure.unavailable => (
          'not_found',
          'The proposal target is not available.',
        ),
      _ToolFailure.ineligible => (
          'ineligible',
          'The target is not eligible for a fill-missing-answer proposal.',
        ),
      _ToolFailure.internal => (
          'internal_error',
          'An internal error occurred.',
        ),
    };
    return jsonEncode(<String, Object?>{
      'ok': false,
      'error': <String, Object?>{
        'code': code,
        'message': message,
        'retryable': false,
      },
    });
  }
}

enum _ToolFailure { invalidRequest, unavailable, ineligible, internal }

final class _ToolFailureException implements Exception {
  const _ToolFailureException(this.failure);

  final _ToolFailure failure;
}

final class _ParsedToolArguments {
  const _ParsedToolArguments({
    required this.targetStorageId,
    required this.payload,
  });

  final String targetStorageId;
  final _ProposalToolPayload payload;
}

final class _ProposalToolPayload {
  const _ProposalToolPayload({this.optionNumbers, this.contentNodes});

  final List<int>? optionNumbers;
  final List<ContentNode>? contentNodes;
}
