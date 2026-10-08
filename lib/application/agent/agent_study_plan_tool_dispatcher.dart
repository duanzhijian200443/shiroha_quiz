/// Proposal tool dispatcher for the built-in Agent's SPL-1 StudyPlan
/// `propose_study_plan` capability.
///
/// Holds only Application seams ([StudyPlanDraftService]) and never reaches
/// SQLite repositories, raw database APIs, or MCP transport. Payload
/// validation is strict and exact-key; forbidden or model-supplied authority
/// keys are rejected outright, and unauthorized/missing targets share one
/// safe non-enumerating response.
library;

import 'dart:convert';

import '../../domain/conversations/conversation.dart';
import '../../domain/study_plan/study_plan_draft.dart';
import '../../domain/study_plan/study_plan_values.dart';
import '../study_plan/study_plan_draft_service.dart';
import '../study_plan/study_plan_capability.dart';
import '../capabilities/capability.dart';
import 'agent_tool_projection.dart';
import 'agent_runtime_limits.dart';

/// One proposal tool call with trusted runtime-injected source context.
final class AgentStudyPlanToolCall {
  const AgentStudyPlanToolCall({
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

final class AgentStudyPlanToolProjection {
  AgentStudyPlanToolProjection({
    required StudyPlanDraftService draftService,
    CapabilityExecutor? executor,
    AgentRuntimeLimits limits = const AgentRuntimeLimits(),
  })  : _executor = executor ??
            CapabilityExecutor(ApplicationCapabilityRegistry(
                [studyPlanCapability(draftService)])),
        _limits = limits;

  final CapabilityExecutor _executor;
  final AgentRuntimeLimits _limits;

  static const int _maxBankNameRunes = 200;
  static const int _maxGoalRunes = 120;
  static const int _minDailyTarget = 1;
  static const int _maxDailyTarget = 200;
  static const int _minHorizonDays = 1;
  static const int _maxHorizonDays = 90;

  static const Set<String> _allowedKeys = <String>{
    'bank_name',
    'goal',
    'daily_target',
    'priority',
    'horizon_days',
  };

  static const Set<String> _forbiddenAuthorityKeys = <String>{
    'sourceConversationId',
    'source_conversation_id',
    'sourceMessageId',
    'source_message_id',
    'sourceUserMessageId',
    'source_user_message_id',
    'sourceScope',
    'source_scope',
    'projectId',
    'project_id',
    'draftId',
    'draft_id',
    'planId',
    'plan_id',
    'expectedActivePlanId',
    'expected_active_plan_id',
    'replacementConfirmed',
    'replacement_confirmed',
    'adopted_at',
    'adoptedAt',
  };

  Future<AgentToolDispatchResult> dispatchWithReceipt(
      AgentStudyPlanToolCall call,
      {bool Function()? lifecycleMutationAllowed}) async {
    final context = CapabilityContext(
        principal: CapabilityPrincipal.builtInAgent,
        capabilities: const [proposeStudyPlan],
        permissions: const [CapabilityPermission.stage],
        scope: call.scope,
        authorizedScope: call.scope,
        sourceConversationId: call.sourceConversationId,
        sourceMessageId: call.sourceMessageId,
        budgetAllowed: lifecycleMutationAllowed);
    AgentToolDispatchResult invalid() => AgentToolDispatchResult(
        json: _failure('invalid_plan', 'The study plan request is invalid.'),
        receipt: _executor
            .reject(proposeStudyPlan, context, CapabilityFailure.invalidPlan)
            .receipt);
    final ProposeStudyPlanInput input;
    try {
      if (utf8.encode(call.argumentsJson).length >
          _limits.maxToolArgumentUtf8Bytes) {
        return invalid();
      }
      final decoded = jsonDecode(call.argumentsJson);
      if (decoded is! Map<String, dynamic> ||
          decoded.keys.any((key) =>
              _forbiddenAuthorityKeys.contains(key) ||
              !_allowedKeys.contains(key))) {
        return invalid();
      }
      input = _parseArguments(decoded);
    } catch (_) {
      return invalid();
    }
    final result = await _executor.execute(proposeStudyPlan, input, context);
    if (result.failure case final failure?) {
      final (code, message) = switch (failure) {
        CapabilityFailure.targetUnavailable ||
        CapabilityFailure.accessDenied =>
          ('target_unavailable', 'The study plan target is not available.'),
        CapabilityFailure.invalidPlan || CapabilityFailure.invalidRequest => (
            'invalid_plan',
            'The study plan request is invalid.'
          ),
        CapabilityFailure.temporarilyUnavailable => (
            'temporarily_unavailable',
            'The study plan data source is temporarily unavailable.'
          ),
        _ => ('internal_error', 'An internal error occurred.'),
      };
      return AgentToolDispatchResult(
          json: _failure(code, message), receipt: result.receipt);
    }
    try {
      final encoded = jsonEncode(<String, Object?>{
        'ok': true,
        'result': _formatStagedResult(result.output!)
      });
      if (utf8.encode(encoded).length > _limits.maxToolResultUtf8Bytes) {
        throw const FormatException();
      }
      return AgentToolDispatchResult(json: encoded, receipt: result.receipt);
    } catch (_) {
      return AgentToolDispatchResult(
          json: _failure('internal_error', 'An internal error occurred.'),
          receipt:
              result.receipt.withFailure(CapabilityFailure.encodingFailed));
    }
  }

  ProposeStudyPlanInput _parseArguments(Map<String, dynamic> arguments) {
    final rawBankName = arguments['bank_name'];
    if (rawBankName is! String) {
      throw const FormatException('Missing bank_name');
    }
    final bankName = rawBankName.trim();
    if (bankName.isEmpty || bankName.runes.length > _maxBankNameRunes) {
      throw const FormatException('Invalid bank_name length');
    }

    String? goal;
    if (arguments.containsKey('goal')) {
      final rawGoal = arguments['goal'];
      if (rawGoal != null) {
        if (rawGoal is! String) {
          throw const FormatException('Invalid goal type');
        }
        // Raw goal is passed through unmodified: canonical validation (which
        // rejects U+0000..U+001F and U+007F before any normalization) remains
        // the authority. Only the defensive upper bound is enforced here.
        if (rawGoal.runes.length > _maxGoalRunes) {
          throw const FormatException('Invalid goal length');
        }
        goal = rawGoal;
      }
    }

    int? dailyTarget;
    if (arguments.containsKey('daily_target')) {
      final rawTarget = arguments['daily_target'];
      if (rawTarget != null) {
        if (rawTarget is! int ||
            rawTarget < _minDailyTarget ||
            rawTarget > _maxDailyTarget) {
          throw const FormatException('Invalid daily_target');
        }
        dailyTarget = rawTarget;
      }
    }

    StudyPlanPriority? priority;
    if (arguments.containsKey('priority')) {
      final rawPriority = arguments['priority'];
      if (rawPriority != null) {
        if (rawPriority is! String) {
          throw const FormatException('Invalid priority type');
        }
        priority = StudyPlanPriority.fromCanonicalCode(rawPriority);
      }
    }

    int? horizonDays;
    if (arguments.containsKey('horizon_days')) {
      final rawHorizon = arguments['horizon_days'];
      if (rawHorizon != null) {
        if (rawHorizon is! int ||
            rawHorizon < _minHorizonDays ||
            rawHorizon > _maxHorizonDays) {
          throw const FormatException('Invalid horizon_days');
        }
        horizonDays = rawHorizon;
      }
    }

    return ProposeStudyPlanInput(
      bankName: bankName,
      goal: goal,
      dailyTarget: dailyTarget,
      priority: priority,
      horizonDays: horizonDays,
    );
  }

  Map<String, Object?> _formatStagedResult(StudyPlanDraft draft) {
    return <String, Object?>{
      'status': 'staged',
      'draft_id': draft.draftId,
      'outcome': _outcomeString(draft.outcome),
      'preview': <String, Object?>{
        'bank_name': draft.preview.bankName,
        'goal': draft.preview.goal,
        'daily_target': draft.preview.dailyTarget,
        'priority': draft.preview.priority.canonicalCode,
        'horizon_days': draft.preview.horizonDays,
        'question_count': draft.preview.questionCount,
        'mastered_count': draft.preview.masteredCount,
        'due_count': draft.preview.dueCount,
        'weak_count': draft.preview.weakCount,
        'new_count': draft.preview.newCount,
        'estimated_days': draft.preview.estimatedDays,
      },
    };
  }

  String _outcomeString(StudyPlanDraftOutcome outcome) {
    return switch (outcome) {
      StudyPlanDraftOutcome.pending => 'pending',
      StudyPlanDraftOutcome.committing => 'committing',
      StudyPlanDraftOutcome.committed => 'committed',
      StudyPlanDraftOutcome.rejected => 'rejected',
      StudyPlanDraftOutcome.superseded => 'superseded',
    };
  }

  String _failure(String code, String message) {
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

final class AgentStudyPlanToolDispatcher {
  AgentStudyPlanToolDispatcher(
      {required StudyPlanDraftService draftService,
      CapabilityExecutor? executor,
      AgentRuntimeLimits limits = const AgentRuntimeLimits()})
      : _projection = AgentStudyPlanToolProjection(
            draftService: draftService, executor: executor, limits: limits);
  final AgentStudyPlanToolProjection _projection;
  Future<AgentToolDispatchResult> dispatchWithReceipt(
          AgentStudyPlanToolCall call,
          {bool Function()? lifecycleMutationAllowed}) =>
      _projection.dispatchWithReceipt(call,
          lifecycleMutationAllowed: lifecycleMutationAllowed);
  Future<String> dispatch(AgentStudyPlanToolCall call,
          {bool Function()? lifecycleMutationAllowed}) async =>
      (await dispatchWithReceipt(call,
              lifecycleMutationAllowed: lifecycleMutationAllowed))
          .json;
}
