part of 'agent_runtime.dart';

final class AgentToolExecutor {
  AgentToolExecutor(
      {required ConversationService conversationService,
      required AgentRuntimeConfigResolver configResolver,
      AgentStudyToolDispatcher? toolDispatcher,
      AgentSurface? agentSurface,
      AgentWriteProposalToolDispatcher? proposalDispatcher,
      AgentStudyPlanToolDispatcher? studyPlanDispatcher,
      AgentRetrievalToolDispatcher? retrievalDispatcher,
      AgentRuntimeLimits limits = const AgentRuntimeLimits()})
      : _conversationService = conversationService,
        _configResolver = configResolver,
        _toolDispatcher = toolDispatcher,
        _surface = agentSurface,
        _proposalDispatcher = proposalDispatcher,
        _studyPlanDispatcher = studyPlanDispatcher,
        _retrievalDispatcher = retrievalDispatcher,
        _limits = limits {
    if (agentSurface == null && toolDispatcher == null) {
      throw ArgumentError(
          'An Agent surface or legacy Study dispatcher is required.');
    }
    if (agentSurface != null &&
        (toolDispatcher != null ||
            proposalDispatcher != null ||
            studyPlanDispatcher != null ||
            retrievalDispatcher != null)) {
      throw ArgumentError(
          'Agent surface and legacy Dispatchers cannot be combined.');
    }
    _bindings = Map.unmodifiable(agentSurface != null
        ? {
            for (final projection in agentSurface.projections)
              projection.definition.name: _AgentProjectionBinding(
                  id: projection.capabilityId,
                  definition: projection.definition,
                  dispatch: projection.requiresEgress
                      ? _dispatchRetrieval
                      : (turn, call, trusted) =>
                          _dispatchRegistered(projection, turn, call, trusted),
                  requiresEgress: projection.requiresEgress),
          }
        : {
            for (final definition in AgentStudyToolCatalog.definitions)
              definition.name: _AgentProjectionBinding(
                  id: StudyCapabilities.ids
                      .singleWhere((id) => id.value == definition.name),
                  definition: definition,
                  dispatch: _dispatchStudy),
            if (proposalDispatcher != null)
              AgentWriteProposalToolCatalog.toolName: _AgentProjectionBinding(
                  id: proposeMissingAnswer,
                  definition: AgentWriteProposalToolCatalog.definition,
                  dispatch: _dispatchProposal),
            if (studyPlanDispatcher != null)
              AgentStudyPlanToolCatalog.toolName: _AgentProjectionBinding(
                  id: proposeStudyPlan,
                  definition: AgentStudyPlanToolCatalog.definition,
                  dispatch: _dispatchStudyPlan),
            if (retrievalDispatcher != null)
              AgentRetrievalToolCatalog.toolName: _AgentProjectionBinding(
                  id: retrieveFileContent,
                  definition: AgentRetrievalToolCatalog.definition,
                  dispatch: _dispatchRetrieval,
                  requiresEgress: true),
          });
  }
  final ConversationService _conversationService;
  final AgentRuntimeConfigResolver _configResolver;
  final AgentStudyToolDispatcher? _toolDispatcher;
  final AgentSurface? _surface;
  final AgentWriteProposalToolDispatcher? _proposalDispatcher;
  final AgentStudyPlanToolDispatcher? _studyPlanDispatcher;
  final AgentRetrievalToolDispatcher? _retrievalDispatcher;
  final AgentRuntimeLimits _limits;
  bool get proposalCapabilityEnabled => _proposalDispatcher != null;
  bool get studyPlanCapabilityEnabled => _studyPlanDispatcher != null;
  AgentEffectiveFileIds? get effectiveFileIds =>
      _surface?.effectiveFileIds ??
      (_surface == null ? _retrievalDispatcher?.effectiveFileIds : null);

  String buildPrompt(
          {required ConversationScope scope,
          required List<ConversationFileRef> files,
          required RetrievalEgressGrant? grant}) =>
      const ShirohaSystemPrompt().build(
          scope: scope,
          files: files,
          proposalCapabilityEnabled: proposalCapabilityEnabled,
          studyPlanCapabilityEnabled: studyPlanCapabilityEnabled,
          retrievalCapabilityEnabled: grant != null,
          retrievableFileIds: grant?.approvedFileIds.toSet() ?? const {},
          registeredGuidance: _surface?.guidance(fileAccess: grant != null));

  late final Map<String, _AgentProjectionBinding> _bindings;
  final CapabilityExecutor _rejections =
      CapabilityExecutor(ApplicationCapabilityRegistry(const []));
  static const _unknownId = CapabilityId<void, void>('unregistered_agent_tool');

  List<AgentFunctionToolDefinition> definitions(RetrievalEgressGrant? grant) =>
      _surface != null
          ? List.unmodifiable(_surface
              .exposed(fileAccess: grant != null)
              .map((p) => p.definition))
          : List.unmodifiable(_bindings.values
              .where((binding) => !binding.requiresEgress || grant != null)
              .map((binding) => binding.definition));

  CapabilityContext _readContext(_ActiveTurn turn, _AgentToolContext trusted) =>
      CapabilityContext(
          principal: CapabilityPrincipal.builtInAgent,
          capabilities: StudyCapabilities.ids,
          permissions: const [CapabilityPermission.read],
          scope: ConversationScope.global(),
          authorizedScope: ConversationScope.global(),
          turnRequestId: turn.requestId,
          sourceConversationId: trusted.conversationId,
          sourceMessageId: trusted.userMessageId,
          providerProfileId: trusted.providerProfileId,
          deadline: turn.policy.deadline,
          cancellationSignal: turn.cancellation.token.whenCancelled,
          isCancelled: () => turn.cancellation.token.isCancelled,
          budgetAllowed: () => turn.remainingBudget() > Duration.zero);

  AgentToolDispatchResult _rejectBudget(_ActiveTurn turn,
          AgentProviderFunctionCall call, _AgentToolContext trusted) =>
      AgentToolDispatchResult(
          json: _toolBudgetInsufficientOutput(),
          receipt: _rejections
              .reject(_bindings[call.name]?.id ?? _unknownId,
                  _readContext(turn, trusted), CapabilityFailure.budgetDenied)
              .receipt);

  Future<({AgentToolDispatchResult dispatch, AgentToolEgressMetadata? egress})>
      _execute(_ActiveTurn turn, AgentProviderFunctionCall call,
          _AgentToolContext trusted) async {
    final binding = _bindings[call.name];
    final remaining = turn.remainingBudget();
    if (remaining <= Duration.zero) throw const _TurnTimeoutException();
    AgentToolDispatchResult result;
    // Projection entry can execute a handler. Unclassified adapter failure after
    // this boundary cannot establish zero effect or justify an automatic retry.
    try {
      final pending = binding == null
          ? _dispatchStudy(turn, call, trusted)
          : binding.dispatch(turn, call, trusted);
      result = await pending.timeout(remaining);
    } catch (error) {
      final failure = turn.cancellation.token.isCancelled
          ? (turn.timedOut
              ? CapabilityFailure.deadlineExceeded
              : CapabilityFailure.cancelled)
          : error is TimeoutException
              ? CapabilityFailure.deadlineExceeded
              : CapabilityFailure.internalError;
      result = AgentToolDispatchResult(
          json: _internalErrorOutput(),
          receipt: ExecutionReceipt(
              executionId: TraceContext.createTraceId(),
              capabilityId: binding?.id ?? _unknownId,
              status: CapabilityExecutionStatus.outcomeUnknown,
              knownEffect: null,
              failure: failure,
              principal: CapabilityPrincipal.builtInAgent,
              scope: trusted.scope,
              authorization: CapabilityAuthorizationReferences(
                  turnRequestId: turn.requestId,
                  conversationId: trusted.conversationId,
                  sourceMessageId: trusted.userMessageId,
                  providerProfileId: trusted.providerProfileId)));
    }
    if (result.receipt.knownEffect == CapabilityEffect.proposalStaged) {
      if (binding?.id == proposeMissingAnswer) {
        turn.policy.proposalStaged = true;
        _maybeEmitProposalStaged(turn, result.json);
      } else if (binding?.id == proposeStudyPlan) {
        turn.policy.studyPlanDraftStaged = true;
        _maybeEmitStudyPlanDraftStaged(turn, result.json);
      }
    }
    return (
      dispatch: result,
      egress: binding?.requiresEgress == true && trusted.grant != null
          ? AgentToolEgressMetadata(
              providerProfileId: trusted.providerProfileId,
              scope: trusted.scope,
              grant: trusted.grant!)
          : null
    );
  }

  CapabilityContext _registeredContext(RegisteredAgentProjection projection,
          _ActiveTurn turn, _AgentToolContext trusted,
          {List<String> currentFileIds = const [],
          Future<bool> Function()? serializationAllowed}) =>
      CapabilityContext(
          principal: CapabilityPrincipal.builtInAgent,
          capabilities: [projection.capabilityId],
          permissions: [projection.permission],
          scope: projection.permission == CapabilityPermission.read
              ? ConversationScope.global()
              : trusted.scope,
          authorizedScope: projection.permission == CapabilityPermission.read
              ? ConversationScope.global()
              : trusted.scope,
          sourceConversationId: trusted.conversationId,
          sourceMessageId: trusted.userMessageId,
          providerProfileId: trusted.providerProfileId,
          turnRequestId: turn.requestId,
          deadline: turn.policy.deadline,
          cancellationSignal: turn.cancellation.token.whenCancelled,
          isCancelled: () => turn.cancellation.token.isCancelled,
          budgetAllowed: () => turn.remainingBudget() > Duration.zero,
          retrievalGrant: trusted.grant,
          currentFileIds: currentFileIds,
          serializationAllowed: serializationAllowed);

  Future<AgentToolDispatchResult> _dispatchRegistered(
          RegisteredAgentProjection projection,
          _ActiveTurn turn,
          AgentProviderFunctionCall call,
          _AgentToolContext trusted) =>
      projection.dispatch(AgentProjectionInvocation(
          argumentsJson: call.argumentsJson,
          context: _registeredContext(projection, turn, trusted)));

  Future<AgentToolDispatchResult> _dispatchStudy(_ActiveTurn turn,
          AgentProviderFunctionCall call, _AgentToolContext trusted) =>
      _toolDispatcher?.dispatchWithReceipt(call.name, call.argumentsJson,
          context: _readContext(turn, trusted)) ??
      Future.value(AgentToolDispatchResult(
          json: jsonEncode(const {
            'ok': false,
            'error': {
              'code': 'invalid_request',
              'message': 'The request is invalid.',
              'retryable': false
            }
          }),
          receipt: _rejections
              .reject(_unknownId, _readContext(turn, trusted),
                  CapabilityFailure.invalidRequest)
              .receipt));

  Future<AgentToolDispatchResult> _dispatchProposal(_ActiveTurn turn,
          AgentProviderFunctionCall call, _AgentToolContext trusted) =>
      _proposalDispatcher!.dispatchWithReceipt(
          AgentWriteProposalToolCall(
              argumentsJson: call.argumentsJson,
              sourceConversationId: trusted.conversationId,
              sourceMessageId: trusted.userMessageId,
              scope: trusted.scope),
          proposalMutationAllowed: () =>
              !turn.cancellation.token.isCancelled &&
              turn.remainingBudget() > Duration.zero,
          cancellationSignal: turn.cancellation.token.whenCancelled,
          isCancelled: () => turn.cancellation.token.isCancelled,
          deadline: turn.policy.deadline);

  Future<AgentToolDispatchResult> _dispatchStudyPlan(_ActiveTurn turn,
          AgentProviderFunctionCall call, _AgentToolContext trusted) =>
      _studyPlanDispatcher!.dispatchWithReceipt(
          AgentStudyPlanToolCall(
              argumentsJson: call.argumentsJson,
              sourceConversationId: trusted.conversationId,
              sourceMessageId: trusted.userMessageId,
              scope: trusted.scope),
          lifecycleMutationAllowed: () =>
              !turn.cancellation.token.isCancelled &&
              turn.remainingBudget() > Duration.zero,
          cancellationSignal: turn.cancellation.token.whenCancelled,
          isCancelled: () => turn.cancellation.token.isCancelled,
          deadline: turn.policy.deadline);

  Future<AgentToolDispatchResult> _dispatchRetrieval(_ActiveTurn turn,
      AgentProviderFunctionCall call, _AgentToolContext trusted) async {
    final current = await _loadSlice(turn, trusted.conversationId);
    final source = current.messages
        .where((m) => m.messageId == trusted.userMessageId)
        .firstOrNull;
    if (source == null ||
        current.messages.any((m) =>
            m.role == ConversationMessageRole.user &&
            m.sequence > source.sequence)) {
      return AgentToolDispatchResult(
          json: retrievalAccessDeniedOutput(),
          receipt: _rejections
              .reject(retrieveFileContent, _readContext(turn, trusted),
                  CapabilityFailure.accessDenied)
              .receipt);
    }
    final currentFileIds = await effectiveFileIds!(
        scope: current.conversation.scope,
        conversationFileIds:
            current.files.map((f) => f.fileId).toList(growable: false));
    return _dispatchRetrievalWithTrace(
        turn: turn,
        argumentsJson: call.argumentsJson,
        grant: trusted.grant,
        conversationId: trusted.conversationId,
        sourceUserMessageId: trusted.userMessageId,
        providerProfileId: trusted.providerProfileId,
        currentFileIds: currentFileIds,
        remaining: turn.remainingBudget());
  }

  String _internalErrorOutput() => jsonEncode(const <String, Object?>{
        'ok': false,
        'error': <String, Object?>{
          'code': 'internal_error',
          'message': 'An internal error occurred.',
          'retryable': false
        },
      });

  /// OBS-1: the actual RAG retrieval runs as a child trace of the current
  /// Agent turn (same correlation, new trace, parent = Agent trace) and logs
  /// only structural counts and fixed status/failure codes. Retrieval
  /// authorization stays untouched: the grant, per-turn approval and
  /// serialization gate run inside the wrapped action unchanged. Logging is
  /// best effort and never changes the retrieval outcome.
  Future<AgentToolDispatchResult> _dispatchRetrievalWithTrace({
    required _ActiveTurn turn,
    required String argumentsJson,
    required RetrievalEgressGrant? grant,
    required String conversationId,
    required String sourceUserMessageId,
    required String providerProfileId,
    required List<String> currentFileIds,
    required Duration remaining,
  }) async {
    final retrievalDispatcher = _retrievalDispatcher;
    final stopwatch = Stopwatch()..start();
    final requestedCounts = _retrievalRequestCounts(argumentsJson);
    return TraceContext.runOperation(
      operationKind: TraceOperationKind.ragRetrieval,
      action: () async {
        try {
          final registered =
              _surface?.projections.where((p) => p.requiresEgress).firstOrNull;
          final Future<AgentToolDispatchResult> pending;
          if (registered != null) {
            pending = registered.dispatch(AgentProjectionInvocation(
                argumentsJson: argumentsJson,
                context: _registeredContext(
                    registered,
                    turn,
                    _AgentToolContext(
                        conversationId: conversationId,
                        userMessageId: sourceUserMessageId,
                        scope: ConversationScope.global(),
                        providerProfileId: providerProfileId,
                        grant: grant),
                    currentFileIds: currentFileIds,
                    serializationAllowed: () => _retrievalSerializationAllowed(
                        turn,
                        conversationId: conversationId,
                        userMessageId: sourceUserMessageId,
                        providerProfileId: providerProfileId,
                        grant: grant))));
          } else {
            pending = retrievalDispatcher!.dispatchWithReceipt(
              argumentsJson: argumentsJson,
              grant: grant,
              turnRequestId: turn.requestId,
              conversationId: conversationId,
              sourceUserMessageId: sourceUserMessageId,
              providerProfileId: providerProfileId,
              currentFileIds: currentFileIds,
              cancellationSignal: turn.cancellation.token.whenCancelled,
              isCancelled: () => turn.cancellation.token.isCancelled,
              deadline: turn.policy.deadline,
              serializationAllowed: () => _retrievalSerializationAllowed(
                turn,
                conversationId: conversationId,
                userMessageId: sourceUserMessageId,
                providerProfileId: providerProfileId,
                grant: grant,
              ),
            );
          }
          final output = await pending.timeout(remaining);
          final outcome = _retrievalOutcome(output.json);
          LogWriter.info(
            'Agent file retrieval completed',
            module: 'Retrieval',
            data: <String, Object?>{
              'stage': 'retrieval_completed',
              'requestedFileCount': requestedCounts?.requested,
              'effectiveFileCount': currentFileIds.length,
              if (requestedCounts?.limit != null)
                'limit': requestedCounts!.limit,
              'hitCount': outcome.hitCount,
              'issueCount': outcome.issueCount,
              'status': outcome.status,
              if (outcome.failureCode != null)
                'failureCode': outcome.failureCode,
              'durationMs': stopwatch.elapsedMilliseconds,
            },
          );
          return output;
        } catch (error) {
          LogWriter.error(
            'Agent file retrieval failed',
            module: 'Retrieval',
            data: <String, Object?>{
              'stage': 'retrieval_completed',
              'requestedFileCount': requestedCounts?.requested,
              'effectiveFileCount': currentFileIds.length,
              if (requestedCounts?.limit != null)
                'limit': requestedCounts!.limit,
              'status': 'failed',
              'errorType': error.runtimeType.toString(),
              'durationMs': stopwatch.elapsedMilliseconds,
            },
          );
          rethrow;
        }
      },
    );
  }

  /// Counts only; never decodes retrieval content.
  ({int requested, int? limit})? _retrievalRequestCounts(
    String argumentsJson,
  ) {
    try {
      final decoded = jsonDecode(argumentsJson);
      if (decoded is! Map || decoded['file_ids'] is! List) return null;
      final limit = decoded['limit'];
      return (
        requested: (decoded['file_ids'] as List).length,
        limit: limit is int ? limit : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Extracts counts and fixed codes from the structured tool output only.
  ({
    String status,
    int? hitCount,
    int? issueCount,
    String? failureCode,
  }) _retrievalOutcome(String output) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is Map && decoded['ok'] == true && decoded['result'] is Map) {
        final result = decoded['result'] as Map;
        final hits = result['hits'];
        final issues = result['issues'];
        return (
          status: 'success',
          hitCount: hits is List ? hits.length : null,
          issueCount: issues is List ? issues.length : null,
          failureCode: null,
        );
      }
      if (decoded is Map && decoded['error'] is Map) {
        final code = (decoded['error'] as Map)['code'];
        return (
          status: 'failed',
          hitCount: null,
          issueCount: null,
          failureCode: code is String ? code : null,
        );
      }
    } catch (_) {}
    return (
      status: 'failed',
      hitCount: null,
      issueCount: null,
      failureCode: null
    );
  }

  Future<bool> _retrievalSerializationAllowed(
    _ActiveTurn turn, {
    required String conversationId,
    required String userMessageId,
    required String providerProfileId,
    required RetrievalEgressGrant? grant,
  }) async {
    if (turn.cancellation.token.isCancelled ||
        turn.remainingBudget() <= Duration.zero ||
        grant == null) {
      return false;
    }
    final fileIds = effectiveFileIds;
    if (fileIds == null) return false;
    try {
      final latest = await _loadSlice(turn, conversationId);
      final sourceMessage = latest.messages
          .where((message) => message.messageId == userMessageId)
          .firstOrNull;
      final hasLaterUserMessage = latest.messages.any(
        (message) =>
            message.role == ConversationMessageRole.user &&
            sourceMessage != null &&
            message.sequence > sourceMessage.sequence,
      );
      if (sourceMessage == null || hasLaterUserMessage) return false;
      final latestFileIds = await fileIds(
        scope: latest.conversation.scope,
        conversationFileIds:
            latest.files.map((file) => file.fileId).toList(growable: false),
      );
      final latestConfig = await _resolveConfig();
      if (latestConfig.profile.profileId != providerProfileId) return false;
      return grant.permits(
        turnRequestId: turn.requestId,
        conversationId: conversationId,
        sourceUserMessageId: userMessageId,
        providerProfileId: providerProfileId,
        currentFileIds: latestFileIds,
      );
    } catch (_) {
      return false;
    }
  }

  String retrievalAccessDeniedOutput() => jsonEncode(const <String, Object?>{
        'ok': false,
        'error': <String, Object?>{
          'code': 'access_denied',
          'message': 'File content is unavailable.',
          'retryable': false,
        },
      });

  String _toolBudgetInsufficientOutput() => jsonEncode(const <String, Object?>{
        'ok': false,
        'error': <String, Object?>{
          'code': 'tool_budget_insufficient',
          'message': 'The requested tool batch exceeds the remaining tool budget. '
              'Use the information already available and provide the best bounded answer.',
          'retryable': false,
        },
      });

  /// Emits a typed proposal-staged event when the proposal tool returned a
  /// successful staging/replay result. Event shaping never fails the turn.
  void _maybeEmitProposalStaged(_ActiveTurn turn, String output) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is! Map<String, dynamic> || decoded['ok'] != true) return;
      final result = decoded['result'];
      if (result is! Map<String, dynamic>) return;
      final proposalId = result['proposal_id'];
      final outcome = result['outcome'];
      final preview = result['preview'];
      if (proposalId is! String || outcome is! String || preview is! Map) {
        return;
      }
      LogWriter.info(
        'Agent proposal staged',
        module: 'Agent',
        data: <String, Object?>{
          'stage': 'proposal_staged',
          'outcome': outcome,
        },
      );
      _emit(
        turn,
        AgentTurnProposalStaged(
          proposalId: proposalId,
          outcome: outcome,
          preview: Map<String, Object?>.from(preview),
        ),
      );
    } catch (_) {
      // The tool output is still returned to the Provider unchanged.
    }
  }

  /// Emits a typed study-plan-draft-staged event when the study plan tool returned
  /// a successful staging/replay result. Event shaping never fails the turn.
  void _maybeEmitStudyPlanDraftStaged(_ActiveTurn turn, String output) {
    try {
      // Same runtime authority as the staging lifecycle gate: a cancelled or
      // expired turn must emit ZERO actionable StudyPlan presentation events,
      // even when a semantic replay resolves successfully.
      if (turn.cancellation.token.isCancelled ||
          turn.remainingBudget() <= Duration.zero) {
        return;
      }
      final decoded = jsonDecode(output);
      if (decoded is! Map<String, dynamic> || decoded['ok'] != true) return;
      final result = decoded['result'];
      if (result is! Map<String, dynamic>) return;
      final draftId = result['draft_id'];
      final outcome = result['outcome'];
      final preview = result['preview'];
      if (draftId is! String || outcome is! String || preview is! Map) {
        return;
      }
      LogWriter.info(
        'Agent study plan draft staged',
        module: 'Agent',
        data: <String, Object?>{
          'stage': 'study_plan_draft_staged',
          'studyPlanOutcome': outcome,
        },
      );
      _emit(
        turn,
        AgentTurnStudyPlanDraftStaged(
          draftId: draftId,
          outcome: outcome,
          preview: Map<String, Object?>.from(preview),
        ),
      );
    } catch (_) {}
  }

  Future<ConversationThreadSlice> _loadSlice(
    _ActiveTurn turn,
    String conversationId,
  ) async {
    _throwIfExpired(turn);
    _throwIfCancelled(turn);
    try {
      return await _conversationService.loadConversation(
        conversationId: conversationId,
        limit: _limits.maxHistoryMessages,
      );
    } on ConversationException catch (error) {
      throw _conversationReadFailure(error.failure);
    }
  }

  Future<ResolvedAgentConfig> _resolveConfig() async {
    try {
      return await _configResolver.resolve();
    } on AgentConfigException catch (error) {
      throw _TurnFailure(switch (error.failure) {
        AgentConfigFailure.invalidInput => AgentTurnFailure.internalError,
        AgentConfigFailure.unconfigured => AgentTurnFailure.agentUnconfigured,
        AgentConfigFailure.corruptStoredConfig =>
          AgentTurnFailure.agentUnconfigured,
        AgentConfigFailure.profileNotFound =>
          AgentTurnFailure.profileUnavailable,
        AgentConfigFailure.profileIncomplete =>
          AgentTurnFailure.profileUnavailable,
        AgentConfigFailure.temporarilyUnavailable =>
          AgentTurnFailure.temporarilyUnavailable,
      });
    }
  }

  /// Registered local tool names. Anything else is provider-controlled and
  /// must never be logged as-is.
  static final Set<String> _registeredToolNames = <String>{
    ...AgentStudyToolCatalog.toolNames,
    AgentRetrievalToolCatalog.toolName,
    AgentWriteProposalToolCatalog.toolName,
    AgentStudyPlanToolCatalog.toolName,
  };

  /// Normalizes a provider-supplied tool name: known registered names keep
  /// their canonical form; anything else becomes the fixed safe token.
  static String safeToolName(String name) =>
      _registeredToolNames.contains(name) ? name : 'unknown_tool';

  /// Strict opaque provider call token. Anything else (embedded user text,
  /// punctuation, unbounded length) is normalized to the fixed safe token.
  static final RegExp _opaqueCallIdPattern = RegExp(r'^[A-Za-z0-9_\-]{1,64}$');

  static String safeCallId(String callId) =>
      _opaqueCallIdPattern.hasMatch(callId) ? callId : 'invalid_call_id';

  /// Fixed status/code derived from the structured tool output only; never
  /// logs tool arguments or result bodies.
  static Map<String, Object?> toolCallStatus(String output) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is Map && decoded['ok'] == true) {
        return const <String, Object?>{'status': 'success'};
      }
      if (decoded is Map && decoded['error'] is Map) {
        final code = (decoded['error'] as Map)['code'];
        return <String, Object?>{
          'status': 'failed',
          if (code is String && code.isNotEmpty) 'failureCode': code,
        };
      }
    } catch (_) {}
    return const <String, Object?>{'status': 'failed'};
  }
}

/// Explicit immutable projection binding, not a module or capability registry.
final class _AgentProjectionBinding {
  const _AgentProjectionBinding(
      {required this.id,
      required this.definition,
      required this.dispatch,
      this.requiresEgress = false});
  final CapabilityId id;
  final AgentFunctionToolDefinition definition;
  final Future<AgentToolDispatchResult> Function(
      _ActiveTurn, AgentProviderFunctionCall, _AgentToolContext) dispatch;
  final bool requiresEgress;
}

final class _AgentToolContext {
  const _AgentToolContext(
      {required this.conversationId,
      required this.userMessageId,
      required this.scope,
      required this.providerProfileId,
      required this.grant});
  final String conversationId;
  final String userMessageId;
  final ConversationScope scope;
  final String providerProfileId;
  final RetrievalEgressGrant? grant;
}
