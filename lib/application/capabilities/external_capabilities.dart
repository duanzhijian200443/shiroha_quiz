part of 'capability.dart';

/// Internal receipt metadata only. No encoder, credential or permission factory.
final class ExternalCapabilityAuthorization {
  ExternalCapabilityAuthorization._(
      this._runtime,
      this.revision,
      Iterable<ExternalGrantScope> scopes,
      Iterable<CapabilityPermission> permissions,
      Iterable<ExternalContentCategory> categories,
      this.recipient,
      this.contextReference)
      : scopes = List.unmodifiable(scopes),
        permissions = Set.unmodifiable(permissions),
        categories = Set.unmodifiable(categories);
  final ExternalRuntimeAccess _runtime;
  String get profileId => _runtime.profileId;
  int get generation => _runtime.generation;
  final int revision;
  final List<ExternalGrantScope> scopes;
  final Set<CapabilityPermission> permissions;
  final Set<ExternalContentCategory> categories;
  final String recipient;
  final String? contextReference;
  bool belongsToSession(ExternalSession session) =>
      identical(_runtime.session, session);
}

/// App-minted execution identity. Existing READ references remain separately
/// Principal/generation bound. This object cannot be rebound to another Session.
final class ExternalExecutionContext {
  ExternalExecutionContext._(this._owner, this.authorization, this.capabilities,
      this.scope, this.expiresAt,
      {this.readAccess,
      this.studyAccess,
      this.stageContext,
      this.submissionKey});
  final ExternalCapabilityGateway _owner;
  final ExternalCapabilityAuthorization authorization;
  final Set<CapabilityId> capabilities;
  final ConversationScope scope;
  final DateTime expiresAt;
  final ExternalQuestionReadAccess? readAccess;
  final ExternalStudyReadAccess? studyAccess;
  final ExternalStageContext? stageContext;
  final String? submissionKey;
  ExternalSession get session => authorization._runtime.session;

  void _validate() {
    if (_owner._closed ||
        !_owner.admission.trust.clock.now().isBefore(expiresAt)) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    authorization._runtime.validate();
    readAccess?.validate();
    studyAccess?.validate();
    stageContext?.validate();
  }
}

final class ExternalTargetQuery {
  const ExternalTargetQuery({this.pageSize = 20, this.cursor});
  final int pageSize;
  final String? cursor;
}

final class ExternalTargetSelection {
  const ExternalTargetSelection(this.targetRef);
  final String targetRef;
}

final class ExternalQuestionQuery {
  const ExternalQuestionQuery(this.query, {this.pageSize = 20, this.cursor});
  final String query;
  final int pageSize;
  final String? cursor;
}

final class ExternalQuestionSelection {
  const ExternalQuestionSelection(this.questionRef);
  final String questionRef;
}

final class ExternalFileSelections {
  ExternalFileSelections(Iterable<String> fileRefs)
      : fileRefs = List.unmodifiable(fileRefs);
  final List<String> fileRefs;
}

final class ExternalFileQuery {
  const ExternalFileQuery(this.query, {this.limit = 8});
  final String query;
  final int limit;
}

final class ExternalPassageSelection {
  const ExternalPassageSelection(this.passageRef, {this.cursor});
  final String passageRef;
  final String? cursor;
}

final class ExternalStageSubmission {
  const ExternalStageSubmission(this.submissionJson, {this.externalRequestId});
  final String submissionJson;
  final String? externalRequestId;
}

final class ExternalNoInput {
  const ExternalNoInput();
}

final class ExternalStudySelection {
  const ExternalStudySelection(this.targetRef);
  final String? targetRef;
}

final class ExternalStudyQuery {
  const ExternalStudyQuery(
      {this.timezone = 'UTC',
      this.pageSize = 20,
      this.cursor,
      this.from,
      this.to});
  final String timezone;
  final int pageSize;
  final String? cursor;
  final DateTime? from, to;
}

final class ExternalStudyResult {
  ExternalStudyResult(Map<String, Object?> value)
      : _value = Map.unmodifiable(value);
  final Map<String, Object?> _value;
  Map<String, Object?> toJson() => _value;
  List<String> get references => [
        for (final item in (_value['items'] as List? ?? const []))
          if (item is Map &&
              (item['targetRef'] ?? item['questionRef']) is String)
            (item['targetRef'] ?? item['questionRef']) as String,
        if (_value['nextCursor'] is String) _value['nextCursor'] as String,
      ];
}

/// Explicit, independent external allowlist. No Built-in definitions are copied.
abstract final class ExternalCapabilities {
  static const openStudyContext = CapabilityId<ExternalStudySelection, String>(
      'external_open_study_context');
  static const listStudyBanks =
      CapabilityId<ExternalStudyQuery, ExternalStudyResult>(
          'external_list_study_banks');
  static const studyOverview =
      CapabilityId<ExternalStudyQuery, ExternalStudyResult>(
          'external_study_overview');
  static const dueReviewSummary =
      CapabilityId<ExternalStudyQuery, ExternalStudyResult>(
          'external_due_review_summary');
  static const weakQuestions =
      CapabilityId<ExternalStudyQuery, ExternalStudyResult>(
          'external_weak_questions');
  static const studyRoutes = <CapabilityId>[
    openStudyContext,
    listStudyBanks,
    studyOverview,
    dueReviewSummary,
    weakQuestions,
  ];
  static const listTargets =
      CapabilityId<ExternalTargetQuery, ExternalTargetPage>(
          'external_list_targets');
  static const createReadContext =
      CapabilityId<ExternalTargetSelection, String>(
          'external_create_read_context');
  static const searchQuestions =
      CapabilityId<ExternalQuestionQuery, ExternalQuestionSearchPage>(
          'external_search_questions');
  static const getQuestionDetail =
      CapabilityId<ExternalQuestionSelection, ExternalQuestionDetail>(
          'external_get_question_detail');
  static const listFileSelections =
      CapabilityId<ExternalTargetQuery, ExternalFilePage>(
          'external_list_file_selections');
  static const createFileContext = CapabilityId<ExternalFileSelections, String>(
      'external_create_file_context');
  static const retrieveFileContent =
      CapabilityId<ExternalFileQuery, ExternalFilePage>(
          'external_retrieve_file_content');
  static const getFilePassage =
      CapabilityId<ExternalPassageSelection, ExternalFilePage>(
          'external_get_file_passage');
  static const stage =
      CapabilityId<ExternalStageSubmission, ExternalStageSummary>(
          'external_stage_generated_questions');
  static const reconcile = CapabilityId<ExternalNoInput, ExternalStageSummary>(
      'external_reconcile_generated_stage');
  static const proposalLifecycle =
      CapabilityId<ExternalNoInput, ExternalProposalLifecycle>(
          'external_get_proposal_lifecycle');
}

/// Unpublished App composition seam. Uses the existing registry/executor and
/// owning P3-P6 services; creates no Host, wire projection or business writer.
final class ExternalCapabilityGateway {
  ExternalCapabilityGateway(
      {required this.stages,
      required this.reads,
      this.enableStudyQueries = false}) {
    if (!identical(stages.runtimeAdmission, reads.admission)) {
      throw ArgumentError('External services must share runtime admission.');
    }
    executor =
        CapabilityExecutor(ApplicationCapabilityRegistry(_definitions()));
    admission.onClose(close);
  }
  final ExternalGeneratedStageService stages;
  final ExternalReadContextService reads;
  final bool enableStudyQueries;
  ExternalRuntimeAdmission get admission => stages.runtimeAdmission;
  late final CapabilityExecutor executor;
  bool _closed = false;
  final _active = <Object, int>{};
  Completer<void>? _idle;
  int get pendingCount => _active.values.fold(0, (sum, count) => sum + count);
  Future<void> get whenIdle => _idle?.future ?? Future.value();
  void close() {
    _closed = true;
    admission.removeOnClose(close);
  }

  Future<ExternalExecutionContext> openRead(
      {required ExternalSession session,
      String? context,
      String? questionRef}) async {
    final runtime = await admission.admit(session);
    final grant = _grant(runtime, CapabilityPermission.read,
        ExternalContentCategory.questionContent);
    final access = context == null
        ? null
        : questionRef == null
            ? await reads.capabilityAccess(session: session, context: context)
            : await reads.capabilityAccessForQuestion(
                session: session, context: context, questionRef: questionRef);
    if (access != null && access.revision != grant.revision) {
      externalAuthFail(ExternalAuthFailure.staleRevision);
    }
    return _mint(
        runtime,
        grant,
        access == null
            ? {
                ExternalCapabilities.listTargets,
                ExternalCapabilities.createReadContext
              }
            : {
                ExternalCapabilities.searchQuestions,
                ExternalCapabilities.getQuestionDetail,
                ExternalCapabilities.listFileSelections,
                ExternalCapabilities.createFileContext,
                ExternalCapabilities.retrieveFileContent,
                ExternalCapabilities.getFilePassage
              },
        context: context,
        readAccess: access);
  }

  Future<ExternalExecutionContext> openStudy(
      {required ExternalSession session, String? context}) async {
    final runtime = await admission.admit(session);
    final grant = runtime.grantSnapshot;
    if (!enableStudyQueries ||
        !reads.studyQueriesAvailable ||
        grant == null ||
        grant.revokedAtUtcMs != null ||
        !grant.policy.permissions.contains(CapabilityPermission.read) ||
        !grant.policy.categories.any((c) =>
            c == ExternalContentCategory.questionContent ||
            c == ExternalContentCategory.studyStatistics)) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    final access = context == null
        ? null
        : await reads.studyCapabilityAccess(session: session, context: context);
    return _mint(
        runtime,
        grant,
        context == null
            ? {ExternalCapabilities.openStudyContext}
            : {
                ExternalCapabilities.listStudyBanks,
                ExternalCapabilities.studyOverview,
                ExternalCapabilities.dueReviewSummary,
                ExternalCapabilities.weakQuestions
              },
        context: context,
        studyAccess: access);
  }

  Future<ExternalExecutionContext> openStage(
      {required ExternalSession session,
      required ExternalStageContext context}) async {
    final runtime = await admission.admit(session);
    final grant = _grant(runtime, CapabilityPermission.stage,
        ExternalContentCategory.proposalMetadata);
    await stages.validateCapabilityContext(session, context);
    if (context.grantRevision != grant.revision) {
      externalAuthFail(ExternalAuthFailure.staleRevision);
    }
    return _mint(runtime, grant, {ExternalCapabilities.stage},
        stageContext: context);
  }

  /// No old Context needed and no automatic restage; owning history supplies scope.
  Future<ExternalExecutionContext> openReconciliation(
      {required ExternalSession session, required String submissionKey}) async {
    generatedToken(submissionKey);
    final runtime = await admission.admit(session);
    final grant = _grant(runtime, CapabilityPermission.stage,
        ExternalContentCategory.proposalMetadata);
    return _mint(runtime, grant, {ExternalCapabilities.reconcile},
        submissionKey: submissionKey);
  }

  ExternalGrant _grant(ExternalRuntimeAccess runtime,
      CapabilityPermission permission, ExternalContentCategory category) {
    final grant = runtime.grantSnapshot;
    if (_closed ||
        grant == null ||
        grant.revokedAtUtcMs != null ||
        !grant.policy.permissions.contains(permission) ||
        !grant.policy.categories.contains(category)) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    return grant;
  }

  Future<ExternalExecutionContext> openProposalLifecycle(
      {required ExternalSession session, required String submissionKey}) async {
    generatedToken(submissionKey);
    final runtime = await admission.admit(session);
    final grant = _grant(runtime, CapabilityPermission.read,
        ExternalContentCategory.proposalMetadata);
    return _mint(runtime, grant, {ExternalCapabilities.proposalLifecycle},
        submissionKey: submissionKey);
  }

  ExternalExecutionContext _mint(ExternalRuntimeAccess runtime,
      ExternalGrant grant, Set<CapabilityId> capabilities,
      {String? context,
      ExternalQuestionReadAccess? readAccess,
      ExternalStudyReadAccess? studyAccess,
      ExternalStageContext? stageContext,
      String? submissionKey}) {
    final project =
        readAccess?.target.projectId ?? stageContext?.target.projectId;
    final scopes = studyAccess != null
        ? studyAccess.targets.map((t) => t.scope).toList()
        : readAccess == null && stageContext == null
            ? grant.policy.scopes
            : [
                if (readAccess != null) readAccess.target.scope,
                if (stageContext != null)
                  ExternalGrantScope(
                      kind: ExternalTargetKind.bank,
                      targetId: stageContext.target.bankName,
                      projectId: project),
                if (readAccess != null)
                  for (final file in readAccess.files)
                    ExternalGrantScope(
                        kind: ExternalTargetKind.file,
                        targetId: file.fileId,
                        projectId: project),
                if (stageContext != null)
                  for (final file in stageContext.evidence)
                    ExternalGrantScope(
                        kind: ExternalTargetKind.file,
                        targetId: file.fileId,
                        projectId: project)
              ];
    final result = ExternalExecutionContext._(
        this,
        ExternalCapabilityAuthorization._(
            runtime,
            grant.revision,
            scopes,
            grant.policy.permissions,
            grant.policy.categories,
            runtime.profileId,
            context),
        Set.unmodifiable(capabilities),
        project == null
            ? ConversationScope.global()
            : ConversationScope.learningSpace(project),
        readAccess?.expiresAt ??
            studyAccess?.expiresAt ??
            stageContext?.expiresAt ??
            admission.trust.clock.now().add(const Duration(minutes: 15)),
        readAccess: readAccess,
        studyAccess: studyAccess,
        stageContext: stageContext,
        submissionKey: submissionKey);
    result._validate();
    return result;
  }

  Future<CapabilityResult<O>> execute<I, O>(CapabilityId<I, O> id, I input,
      {required ExternalSession session,
      required ExternalExecutionContext context,
      ExternalCallControl? control,
      bool Function()? responseAvailable}) async {
    final clock = admission.trust.clock;
    DateTime? deadline = control?.deadline;
    if (context.capabilities.contains(id) &&
        context.stageContext == null &&
        (context.submissionKey == null ||
            context.capabilities
                .contains(ExternalCapabilities.proposalLifecycle))) {
      final readDeadline = clock.now().add(reads.maxQueryDuration);
      if (deadline == null || readDeadline.isBefore(deadline)) {
        deadline = readDeadline;
      }
    }
    final operationControl =
        ExternalCallControl(clock: clock, deadline: deadline);
    void forward(ExternalFailure failure) {
      if (failure == ExternalFailure.cancelled) {
        operationControl.cancel();
      } else {
        operationControl.expireDeadline();
      }
    }

    if (control?.failure != null) forward(control!.failure!);
    control?.interrupted.then(forward);
    final timer = deadline == null
        ? null
        : Timer(
            deadline.difference(clock.now()), operationControl.expireDeadline);
    final call = _ExternalCapabilityCall(this, context, session,
        operationControl, responseAvailable ?? () => true);
    final kernelContext = CapabilityContext._external(call);
    if (!call.belongsTo(this)) {
      timer?.cancel();
      return executor.reject(id, kernelContext, CapabilityFailure.accessDenied);
    }
    final read = context.stageContext == null &&
        (context.submissionKey == null ||
            context.capabilities
                .contains(ExternalCapabilities.proposalLifecycle));
    final key = read ? session.principal : session as Object;
    final maxCalls = read ? reads.maxInFlight : stages.maxInFlight;
    final maxOwned =
        read ? reads.maxInFlightPerProfile : stages.maxInFlightPerSession;
    if (_closed ||
        pendingCount >= maxCalls ||
        (_active[key] ?? 0) >= maxOwned) {
      timer?.cancel();
      return executor.reject(
          id,
          kernelContext,
          _closed
              ? CapabilityFailure.accessDenied
              : CapabilityFailure.budgetDenied);
    }
    if (pendingCount == 0) _idle = Completer<void>();
    _active[key] = (_active[key] ?? 0) + 1;
    try {
      final result = await executor.execute(id, input, kernelContext);
      if (result.output == null && call.allocations.isNotEmpty) {
        reads.discardCapabilityOutput(session, call.allocations);
      }
      return result;
    } finally {
      timer?.cancel();
      void releaseSlot() {
        final count = _active[key]! - 1;
        if (count == 0) {
          _active.remove(key);
        } else {
          _active[key] = count;
        }
        if (_active.isEmpty) {
          _idle?.complete();
          _idle = null;
        }
      }

      if (call.pendingCount == 0 &&
          reads.pendingCount == 0 &&
          stages.pendingCount == 0) {
        releaseSlot();
      } else {
        // Kernel interruption never frees unfinished authorization/release work
        // or a delegated owning-service slot. No historical execution journal.
        Future.wait([call.whenIdle, reads.whenIdle, stages.whenIdle])
            .then((_) => releaseSlot(), onError: (_) => releaseSlot());
      }
    }
  }

  CapabilityDefinition<I, O> _read<I, O>(
          CapabilityId<I, O> id,
          Future<O> Function(
                  I, _ExternalCapabilityCall, CapabilityExecutionEvidence)
              invoke,
          List<String> Function(I, O) references,
          {bool mayBuildCache = false,
          bool existingSelection = false,
          bool study = false}) =>
      CapabilityDefinition<I, O>(
          id: id,
          permission: CapabilityPermission.read,
          permittedEffects: {
            CapabilityEffect.none,
            if (mayBuildCache) CapabilityEffect.derivedCache
          },
          semantics: CapabilityExecutionSemantics.repeatableRead,
          authorize: (_, context) async =>
              context._externalCall?.belongsTo(this) ?? false,
          handler: CapabilityHandler<I, O>((input, context, confirmed) async {
            final call = context._externalCall!;
            if (!mayBuildCache) confirmed.confirm(CapabilityEffect.none);
            try {
              final output = await invoke(input, call, confirmed);
              final refs = references(input, output);
              if (!existingSelection) {
                call.allocations.addAll(refs);
              } else if (output is ExternalFilePage &&
                  output.nextCursor != null) {
                call.allocations.add(output.nextCursor!);
              }
              call.release = () =>
                  (study || call.context.readAccess?.isAggregate == true)
                      ? reads.releaseStudyCapabilityOutput(
                          session: call.session,
                          context: call.context.authorization.contextReference,
                          references: refs,
                          control: call.control)
                      : reads.releaseCapabilityOutput(
                          session: call.session,
                          context: call.context.authorization.contextReference,
                          references: refs,
                          control: call.control);
              return CapabilityEvidence(
                  output: output,
                  status: call.cache?.effectKnown == false
                      ? CapabilityExecutionStatus.outcomeUnknown
                      : CapabilityExecutionStatus.completed,
                  effect: confirmed.knownEffect);
            } on ExternalFileReadException catch (error) {
              final effect = _cacheEffect(error.evidence);
              if (effect != null) confirmed.confirm(effect);
              return _readFailure(error.failure, effect);
            } on ExternalReadException catch (error) {
              return _readFailure(error.failure, confirmed.knownEffect);
            }
          }),
          release: (_, context) => context._externalCall!.releaseOutput());

  Iterable<CapabilityDefinition> _definitions() => [
        if (enableStudyQueries) ...[
          _read<ExternalStudySelection, String>(
              ExternalCapabilities.openStudyContext,
              (input, call, _) => reads.openStudyContext(
                  session: call.session,
                  targetRef: input.targetRef,
                  control: call.control),
              (_, token) => [token],
              study: true),
          _read<ExternalStudyQuery, ExternalStudyResult>(
              ExternalCapabilities.listStudyBanks,
              (input, call, _) async => ExternalStudyResult(
                  await reads.listStudyBanks(
                      session: call.session,
                      context: call.context.authorization.contextReference!,
                      pageSize: input.pageSize,
                      cursor: input.cursor,
                      control: call.control)),
              (_, output) => output.references,
              study: true),
          _read<ExternalStudyQuery, ExternalStudyResult>(
              ExternalCapabilities.studyOverview,
              (input, call, _) async => ExternalStudyResult(
                  await reads.studyOverview(
                      session: call.session,
                      context: call.context.authorization.contextReference!,
                      timezone: input.timezone,
                      control: call.control)),
              (_, output) => output.references,
              study: true),
          _read<ExternalStudyQuery, ExternalStudyResult>(
              ExternalCapabilities.dueReviewSummary,
              (input, call, _) async => ExternalStudyResult(
                  await reads.studyDueSummary(
                      session: call.session,
                      context: call.context.authorization.contextReference!,
                      timezone: input.timezone,
                      from: input.from!,
                      to: input.to!,
                      control: call.control)),
              (_, output) => output.references,
              study: true),
          _read<ExternalStudyQuery, ExternalStudyResult>(
              ExternalCapabilities.weakQuestions,
              (input, call, _) async => ExternalStudyResult(
                  await reads.studyWeakQuestions(
                      session: call.session,
                      context: call.context.authorization.contextReference!,
                      pageSize: input.pageSize,
                      cursor: input.cursor,
                      control: call.control)),
              (_, output) => output.references,
              study: true),
        ],
        CapabilityDefinition<ExternalNoInput, ExternalProposalLifecycle>(
            id: ExternalCapabilities.proposalLifecycle,
            permission: CapabilityPermission.read,
            permittedEffects: {CapabilityEffect.none},
            semantics: CapabilityExecutionSemantics.repeatableRead,
            authorize: (_, context) async =>
                context._externalCall?.belongsTo(this) ?? false,
            handler: CapabilityHandler((_, context, confirmed) async {
              final call = context._externalCall!;
              confirmed.confirm(CapabilityEffect.none);
              try {
                final output = await Future.any([
                  call._track(() => stages.proposalLifecycle.query(
                      call.context.authorization._runtime,
                      call.context.submissionKey!)),
                  call.control.interrupted.then<ExternalProposalLifecycle>(
                      (failure) => throw _CapabilityInterrupted(
                          _externalInterruption(failure)!)),
                ]);
                call.release = () => stages.proposalLifecycle
                    .release(call.context.authorization._runtime, output);
                return CapabilityEvidence.completed(
                    output, CapabilityEffect.none);
              } on _CapabilityInterrupted catch (error) {
                return CapabilityEvidence(
                    failure: error.failure,
                    status: CapabilityExecutionStatus.outcomeUnknown,
                    effect: CapabilityEffect.none);
              } on GeneratedQuestionException catch (error) {
                return CapabilityEvidence(
                    failure: _generatedFailure(error.failure),
                    status: CapabilityExecutionStatus.failedWithoutEffect,
                    effect: CapabilityEffect.none);
              }
            }),
            release: (_, context) => context._externalCall!.releaseOutput()),
        _read<ExternalTargetQuery, ExternalTargetPage>(
            ExternalCapabilities.listTargets,
            (input, call, _) => reads.listTargets(
                session: call.session,
                pageSize: input.pageSize,
                cursor: input.cursor,
                control: call.control),
            (_, page) => [
                  ...page.items.map((e) => e.targetRef),
                  if (page.nextCursor != null) page.nextCursor!
                ]),
        _read<ExternalTargetSelection, String>(
            ExternalCapabilities.createReadContext,
            (input, call, _) => reads.createContext(
                session: call.session,
                targetRef: input.targetRef,
                control: call.control),
            (_, token) => [token]),
        _read<ExternalQuestionQuery, ExternalQuestionSearchPage>(
            ExternalCapabilities.searchQuestions,
            (input, call, _) => reads.searchQuestions(
                session: call.session,
                context: call.context.authorization.contextReference!,
                query: input.query,
                pageSize: input.pageSize,
                cursor: input.cursor,
                control: call.control),
            (_, page) => [
                  ...page.items.map((e) => e.questionRef),
                  if (page.nextCursor != null) page.nextCursor!
                ]),
        _read<ExternalQuestionSelection, ExternalQuestionDetail>(
            ExternalCapabilities.getQuestionDetail,
            (input, call, _) => reads.getQuestionDetail(
                session: call.session,
                context: call.context.authorization.contextReference!,
                questionRef: input.questionRef,
                control: call.control),
            (input, _) => [input.questionRef],
            existingSelection: true),
        _read<ExternalTargetQuery, ExternalFilePage>(
            ExternalCapabilities.listFileSelections,
            (input, call, __) => reads.listFileSelections(
                pageSize: input.pageSize,
                cursor: input.cursor,
                session: call.session,
                context: call.context.authorization.contextReference!,
                control: call.control),
            (_, page) => [
                  ...page.items.map((e) => e['fileRef']! as String),
                  if (page.nextCursor != null) page.nextCursor!,
                ]),
        _read<ExternalFileSelections, String>(
            ExternalCapabilities.createFileContext,
            (input, call, _) => reads.createFileContext(
                session: call.session,
                context: call.context.authorization.contextReference!,
                fileRefs: input.fileRefs,
                control: call.control),
            (_, token) => [token]),
        _read<ExternalFileQuery, ExternalFilePage>(
            ExternalCapabilities.retrieveFileContent,
            (input, call, confirmed) async {
          final page = await reads.retrieveFileContent(
              session: call.session,
              context: call.context.authorization.contextReference!,
              query: input.query,
              limit: input.limit,
              control: call.control,
              onDerivedCacheCommitted: () =>
                  confirmed.confirm(CapabilityEffect.derivedCache));
          final cache = page.executionEvidence!;
          call.cache = cache;
          final effect = _cacheEffect(cache);
          if (effect != null) confirmed.confirm(effect);
          return page;
        },
            (_, page) =>
                page.items.map((e) => e['passageRef']! as String).toList(),
            mayBuildCache: true),
        _read<ExternalPassageSelection, ExternalFilePage>(
            ExternalCapabilities.getFilePassage,
            (input, call, _) => reads.getFilePassage(
                session: call.session,
                context: call.context.authorization.contextReference!,
                passageRef: input.passageRef,
                cursor: input.cursor,
                control: call.control),
            (input, page) => [
                  input.passageRef,
                  if (page.nextCursor != null) page.nextCursor!
                ],
            existingSelection: true),
        _stageDefinition<ExternalStageSubmission>(
            ExternalCapabilities.stage,
            (input, call, evidence) => stages.stage(
                session: call.session,
                context: call.context.stageContext!,
                submissionJson: input.submissionJson,
                externalRequestId: input.externalRequestId,
                control: call.control,
                responseAvailable: call.responseAvailable,
                onEffectConfirmed: evidence.confirm)),
        _stageDefinition<ExternalNoInput>(
            ExternalCapabilities.reconcile,
            (_, call, evidence) => stages.reconcile(
                session: call.session,
                submissionKey: call.context.submissionKey!,
                control: call.control,
                responseAvailable: call.responseAvailable,
                onEffectConfirmed: evidence.confirm)),
      ];

  CapabilityDefinition<I, ExternalStageSummary> _stageDefinition<I>(
          CapabilityId<I, ExternalStageSummary> id,
          Future<ExternalStageResult> Function(
                  I, _ExternalCapabilityCall, CapabilityExecutionEvidence)
              invoke) =>
      CapabilityDefinition<I, ExternalStageSummary>(
          id: id,
          permission: CapabilityPermission.stage,
          permittedEffects: {
            CapabilityEffect.none,
            CapabilityEffect.proposalStaged,
            CapabilityEffect.formalMutation,
          },
          semantics: CapabilityExecutionSemantics.durableStage,
          authorize: (_, context) async =>
              context._externalCall?.belongsTo(this) ?? false,
          handler: CapabilityHandler<I, ExternalStageSummary>(
              (input, context, confirmed) async {
            final call = context._externalCall!;
            final result = await invoke(input, call, confirmed);
            if (result.output != null) {
              call.release = () =>
                  stages.releaseCapabilityOutput(call.session, result.output!);
            }
            // The Kernel handler was entered. Owning pre-publication rejection
            // proves zero effect but is not Kernel notStarted.
            return CapabilityEvidence(
                output: result.output,
                failure: result.failure == null
                    ? _externalInterruption(result.interruption)
                    : _generatedFailure(result.failure!),
                status: result.status == CapabilityExecutionStatus.notStarted
                    ? CapabilityExecutionStatus.failedWithoutEffect
                    : result.status,
                effect: result.effect,
                durableReconciliation: result.evidence.durableReconciliation);
          }),
          release: (_, context) => context._externalCall!.releaseOutput());
}

final class _ExternalCapabilityCall {
  _ExternalCapabilityCall(this.owner, this.context, this.session, this.control,
      this.responseAvailable);
  final ExternalCapabilityGateway owner;
  final ExternalExecutionContext context;
  final ExternalSession session;
  final ExternalCallControl control;
  final bool Function() responseAvailable;
  final allocations = <String>[];
  RetrievalExecutionEvidence? cache;
  Future<void> Function()? release;
  int pendingCount = 0;
  Completer<void>? _idle;
  Future<void> get whenIdle => _idle?.future ?? Future.value();
  Future<T> _track<T>(Future<T> Function() work) async {
    if (pendingCount++ == 0) _idle = Completer<void>();
    try {
      return await work();
    } finally {
      if (--pendingCount == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  CapabilityFailure? get interruption => _externalInterruption(control.failure);
  bool belongsTo(ExternalCapabilityGateway gateway) =>
      identical(owner, gateway) &&
      identical(context._owner, gateway) &&
      context.authorization.belongsToSession(session);
  Future<bool> authorize() => _track(_authorize);
  Future<bool> _authorize() async {
    if (!belongsTo(owner)) return false;
    context._validate();
    final current = await context.authorization._runtime
        .revisionIsCurrent(context.authorization.revision);
    context._validate();
    return current;
  }

  Future<bool> releaseOutput() => _track(_releaseOutput);
  Future<bool> _releaseOutput() async {
    if (!await authorize()) return false;
    try {
      await release?.call();
    } on ExternalReadException catch (error) {
      throw _CapabilityInterrupted(_externalReadFailure(error.failure));
    } on GeneratedQuestionException catch (error) {
      throw _CapabilityInterrupted(_generatedFailure(error.failure));
    }
    context._validate();
    final stopped = interruption;
    if (stopped != null) throw _CapabilityInterrupted(stopped);
    if (!responseAvailable()) {
      throw const _CapabilityInterrupted(
          CapabilityFailure.externalResponseLost);
    }
    return true;
  }
}

CapabilityEffect? _cacheEffect(RetrievalExecutionEvidence evidence) =>
    evidence.derivedCacheWritten
        ? CapabilityEffect.derivedCache
        : evidence.effectKnown
            ? CapabilityEffect.none
            : null;

CapabilityEvidence<O> _readFailure<O>(
        ExternalReadFailure failure, CapabilityEffect? effect) =>
    CapabilityEvidence(
        failure: _externalReadFailure(failure),
        status: failure == ExternalReadFailure.cancelled ||
                failure == ExternalReadFailure.deadlineExceeded ||
                effect != CapabilityEffect.none
            ? CapabilityExecutionStatus.outcomeUnknown
            : CapabilityExecutionStatus.failedWithoutEffect,
        effect: effect);

CapabilityFailure? _externalInterruption(ExternalFailure? failure) =>
    switch (failure) {
      null => null,
      ExternalFailure.cancelled => CapabilityFailure.cancelled,
      ExternalFailure.deadlineExceeded => CapabilityFailure.deadlineExceeded,
      ExternalFailure.responseLost => CapabilityFailure.externalResponseLost,
      _ => CapabilityFailure.internalError,
    };
CapabilityFailure _externalReadFailure(ExternalReadFailure failure) =>
    switch (failure) {
      ExternalReadFailure.denied => CapabilityFailure.externalReadDenied,
      ExternalReadFailure.stale => CapabilityFailure.externalReadStale,
      ExternalReadFailure.resourceLimit =>
        CapabilityFailure.externalReadResourceLimit,
      ExternalReadFailure.cancelled => CapabilityFailure.cancelled,
      ExternalReadFailure.deadlineExceeded =>
        CapabilityFailure.deadlineExceeded,
      ExternalReadFailure.unavailable =>
        CapabilityFailure.externalReadUnavailable,
      ExternalReadFailure.invalidRequest =>
        CapabilityFailure.externalReadInvalidRequest,
      ExternalReadFailure.dataCorrupt =>
        CapabilityFailure.externalReadDataCorrupt,
      ExternalReadFailure.sourceNotReady =>
        CapabilityFailure.externalReadSourceNotReady,
    };
CapabilityFailure _generatedFailure(GeneratedFailure failure) =>
    switch (failure) {
      GeneratedFailure.invalidSubmission =>
        CapabilityFailure.generatedInvalidSubmission,
      GeneratedFailure.unsupportedContent =>
        CapabilityFailure.generatedUnsupportedContent,
      GeneratedFailure.unsafePayload =>
        CapabilityFailure.generatedUnsafePayload,
      GeneratedFailure.resourceLimit =>
        CapabilityFailure.generatedResourceLimit,
      GeneratedFailure.invalidEvidence =>
        CapabilityFailure.generatedInvalidEvidence,
      GeneratedFailure.unauthorized => CapabilityFailure.generatedUnauthorized,
      GeneratedFailure.targetChanged =>
        CapabilityFailure.generatedTargetChanged,
      GeneratedFailure.proposalUnavailable =>
        CapabilityFailure.generatedProposalUnavailable,
      GeneratedFailure.staleRevision =>
        CapabilityFailure.generatedStaleRevision,
      GeneratedFailure.terminalConflict =>
        CapabilityFailure.generatedTerminalConflict,
      GeneratedFailure.idempotencyConflict =>
        CapabilityFailure.generatedIdempotencyConflict,
      GeneratedFailure.duplicateContent =>
        CapabilityFailure.generatedDuplicateContent,
      GeneratedFailure.reviewIncomplete =>
        CapabilityFailure.generatedReviewIncomplete,
      GeneratedFailure.qualityBlocked =>
        CapabilityFailure.generatedQualityBlocked,
      GeneratedFailure.staleEvidence =>
        CapabilityFailure.generatedStaleEvidence,
      GeneratedFailure.invalidEdit => CapabilityFailure.generatedInvalidEdit,
      GeneratedFailure.corruptState => CapabilityFailure.generatedCorruptState,
      GeneratedFailure.persistenceFailed =>
        CapabilityFailure.generatedPersistenceFailed,
    };
