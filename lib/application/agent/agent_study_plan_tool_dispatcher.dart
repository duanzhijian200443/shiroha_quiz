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
import '../study_plan/study_plan_ports.dart';
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

final class AgentStudyPlanToolDispatcher {
  AgentStudyPlanToolDispatcher({
    required StudyPlanDraftService draftService,
    AgentRuntimeLimits limits = const AgentRuntimeLimits(),
  })  : _draftService = draftService,
        _limits = limits;

  final StudyPlanDraftService _draftService;
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

  Future<String> dispatch(
    AgentStudyPlanToolCall call, {
    bool Function()? lifecycleMutationAllowed,
  }) async {
    if (utf8.encode(call.argumentsJson).length >
        _limits.maxToolArgumentUtf8Bytes) {
      return _failure('invalid_plan', 'The study plan request is invalid.');
    }

    final Map<String, dynamic> arguments;
    try {
      final decoded = jsonDecode(call.argumentsJson);
      if (decoded is! Map<String, dynamic>) {
        return _failure('invalid_plan', 'The study plan request is invalid.');
      }
      arguments = decoded;
    } on FormatException {
      return _failure('invalid_plan', 'The study plan request is invalid.');
    }

    // Strict validation: reject any forbidden authority keys or unknown keys
    for (final key in arguments.keys) {
      if (_forbiddenAuthorityKeys.contains(key) ||
          !_allowedKeys.contains(key)) {
        return _failure('invalid_plan', 'The study plan request is invalid.');
      }
    }

    final _ParsedPlanArguments parsed;
    try {
      parsed = _parseArguments(arguments);
    } catch (_) {
      return _failure('invalid_plan', 'The study plan request is invalid.');
    }

    try {
      final stageResult = await _draftService.stage(
        sourceConversationId: call.sourceConversationId,
        sourceMessageId: call.sourceMessageId,
        sourceScope: call.scope,
        bankName: parsed.bankName,
        goal: parsed.goal,
        dailyTarget: parsed.dailyTarget,
        priority: parsed.priority,
        horizonDays: parsed.horizonDays,
        lifecycleMutationAllowed: lifecycleMutationAllowed,
      );

      switch (stageResult) {
        case StudyPlanStageResultStaged(:final draft):
          final encoded = jsonEncode(<String, Object?>{
            'ok': true,
            'result': _formatStagedResult(draft),
          });
          if (utf8.encode(encoded).length > _limits.maxToolResultUtf8Bytes) {
            return _failure('internal_error', 'An internal error occurred.');
          }
          return encoded;
        case StudyPlanStageResultUnavailable():
          return _failure(
            'target_unavailable',
            'The study plan target is not available.',
          );
        case StudyPlanStageResultInvalid() ||
              StudyPlanStageResultBusy() ||
              StudyPlanStageResultStale():
          return _failure('invalid_plan', 'The study plan request is invalid.');
        case StudyPlanStageResultCancelled():
          return _failure('internal_error', 'An internal error occurred.');
      }
    } on StudyPlanException catch (e) {
      if (e.failure == StudyPlanFailure.temporarilyUnavailable) {
        return _failure(
          'temporarily_unavailable',
          'The study plan data source is temporarily unavailable.',
        );
      }
      return _failure('internal_error', 'An internal error occurred.');
    } catch (_) {
      return _failure('internal_error', 'An internal error occurred.');
    }
  }

  _ParsedPlanArguments _parseArguments(Map<String, dynamic> arguments) {
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

    return _ParsedPlanArguments(
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

final class _ParsedPlanArguments {
  const _ParsedPlanArguments({
    required this.bankName,
    this.goal,
    this.dailyTarget,
    this.priority,
    this.horizonDays,
  });

  final String bankName;
  final String? goal;
  final int? dailyTarget;
  final StudyPlanPriority? priority;
  final int? horizonDays;
}
