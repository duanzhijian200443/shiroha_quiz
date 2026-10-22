part of 'agent_runtime_test.dart';

const _r7Capabilities = AgentProviderCapabilities(
    functionTools: true, nativeWebSearch: true, canonicalToolHistory: true);

_Script _r7Failure(
        [AgentProviderFailure failure = AgentProviderFailure.rateLimited]) =>
    (_, __) async* {
      throw AgentProviderException(failure);
    };

AgentProviderFunctionCall _r7Call(String id, [int input = 1]) =>
    _call(id, name: 'r7_read', arguments: '{"n":$input}');

final class _ReadContinuationFixture {
  _ReadContinuationFixture({
    CapabilityPermission permission = CapabilityPermission.read,
    CapabilityExecutionStatus status = CapabilityExecutionStatus.completed,
    CapabilityEffect? effect = CapabilityEffect.none,
    CapabilityFailure? failure,
    bool carryPermit = true,
    bool replaceReceipt = false,
  }) {
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
      CapabilityDefinition<int, String>(
          id: id,
          permission: permission,
          permittedEffects: CapabilityEffect.values,
          semantics: permission == CapabilityPermission.read
              ? CapabilityExecutionSemantics.repeatableRead
              : CapabilityExecutionSemantics.transientStage,
          authorize: (_, __) async => readAllowed,
          release: (_, context) async {
            if (context.providerProfileId == 'profile-fallback') {
              await beforeTargetRelease?.call();
              return releaseAllowed;
            }
            return true;
          },
          handler:
              CapabilityHandler<int, String>((input, context, evidence) async {
            handlerEntries++;
            return CapabilityEvidence(
                output: '$input:$payload',
                status: status,
                effect: effect,
                failure: failure);
          })),
    ]));
    surface = AgentSurface([
      RegisteredAgentProjection(
          capabilityId: id,
          permission: permission,
          definition: AgentFunctionToolDefinition(
              name: 'r7_read',
              description: 'Synthetic read.',
              inputSchema: const {'type': 'object'}),
          dispatch: (invocation) async {
            final args = jsonDecode(invocation.argumentsJson) as Map;
            final result = await executor.execute(
                id, args['n'] as int, invocation.context);
            return AgentToolDispatchResult(
                json: jsonEncode(
                    {'ok': result.failure == null, 'result': result.output}),
                receipt: replaceReceipt
                    ? result.receipt.withFailure(CapabilityFailure.notFound)
                    : result.receipt,
                readReuse: carryPermit ? result.readReuse : null);
          }),
    ]);
  }
  static const id = CapabilityId<int, String>('r7_fixture_read');
  late final AgentSurface surface;
  final String payload = 'synthetic-read-result';
  int handlerEntries = 0;
  bool readAllowed = true;
  bool releaseAllowed = true;
  Future<void> Function()? beforeTargetRelease;

  _Harness harness(
          {required List<_Script> scripts,
          List<_Script>? fallbackScripts,
          bool enabled = true,
          AgentRuntimeLimits? limits,
          AgentProviderCapabilities? capabilities}) =>
      _Harness(
          agentSurface: surface,
          enableBoundedReadContinuation: enabled,
          fallbackProfileId: 'profile-fallback',
          fallbackCapabilities: capabilities ?? _r7Capabilities,
          scripts: scripts,
          fallbackScripts: fallbackScripts ?? [_finalAnswer('continued')],
          limits: limits);
}

void _readContinuationTests() {
  group('AR-R7 bounded READ continuation', () {
    for (final registered in [false, true]) {
      test(
          'real Study projection carries executor proof: registered=$registered',
          () async {
        final metrics = CapabilityMetricsPort();
        final service = StudyQueryService(
            questionQuery: CapabilityQuestionPort(),
            metricsQuery: metrics,
            clock: const CapabilityClock());
        final h = _Harness(
            enableBoundedReadContinuation: true,
            agentSurface: registered
                ? const ModuleComposer()
                    .compose([studyModule(service)]).agentSurface
                : null,
            studyOverride:
                registered ? null : AgentStudyToolDispatcher(service: service),
            fallbackProfileId: 'profile-fallback',
            fallbackCapabilities: _r7Capabilities,
            scripts: [
              _toolRound([
                _call('study',
                    name: 'get_study_overview', arguments: '{"timezone":"UTC"}')
              ], const _TestContinuationState('private')),
              _r7Failure()
            ],
            fallbackScripts: [
              _finalAnswer('study continued')
            ]);
        final (cid, mid) = await h.seedUser('question');
        expect(
            await h.runtime
                .startTurn(conversationId: cid, userMessageId: mid)
                .result,
            isA<AgentTurnSuccess>());
        expect(metrics.calls, ['overview']);
        expect(
            h.fallbackProvider.requests.single.canonicalToolHistory.single.call
                .callId,
            'study');
      });
    }

    test('a complete multi-call batch reuses every paired result', () async {
      final fixture = _ReadContinuationFixture();
      final h = fixture.harness(scripts: [
        _toolRound([_r7Call('batch-1'), _r7Call('batch-2', 2)],
            const _TestContinuationState('private')),
        _r7Failure()
      ]);
      final (cid, mid) = await h.seedUser('question');
      expect(
          await h.runtime
              .startTurn(conversationId: cid, userMessageId: mid)
              .result,
          isA<AgentTurnSuccess>());
      expect(
          h.fallbackProvider.requests.single.canonicalToolHistory
              .map((e) => e.result.callId),
          ['batch-1', 'batch-2']);
      expect(fixture.handlerEntries, 2);
    });

    for (final effect in [
      CapabilityEffect.none,
      CapabilityEffect.derivedCache
    ]) {
      test('receipt permits only known READ effects: $effect', () async {
        final fixture = _ReadContinuationFixture(effect: effect);
        final h = fixture.harness(scripts: [
          _toolRound(
              [_r7Call('read')], const _TestContinuationState('private')),
          _r7Failure()
        ]);
        final (cid, mid) = await h.seedUser('question');
        final session =
            h.runtime.startTurn(conversationId: cid, userMessageId: mid);
        expect(await session.result, isA<AgentTurnSuccess>());
        expect(
            session.transcript!.toolGroups.single.receipt.knownEffect, effect);
        expect(fixture.handlerEntries, 1);
      });
    }

    test(
        'complete business-error result retains receipt and is not executed again',
        () async {
      final fixture = _ReadContinuationFixture(
          status: CapabilityExecutionStatus.failedWithoutEffect,
          failure: CapabilityFailure.notFound);
      final h = fixture.harness(scripts: [
        _toolRound([_r7Call('read')], const _TestContinuationState('private')),
        _r7Failure()
      ]);
      final (cid, mid) = await h.seedUser('question');
      expect(
          await h.runtime
              .startTurn(conversationId: cid, userMessageId: mid)
              .result,
          isA<AgentTurnSuccess>());
      expect(
          jsonDecode(h.fallbackProvider.requests.single.canonicalToolHistory
              .single.result.output)['ok'],
          isFalse);
      expect(fixture.handlerEntries, 1);
    });
    for (final rounds in [1, 2]) {
      test(
          '$rounds complete READ rounds reuse canonical pairs once and append one answer',
          () async {
        final sink = _MemoryLogSink();
        AppLogger.setSink(sink);
        addTearDown(() => AppLogger.setSink(null));
        final fixture = _ReadContinuationFixture();
        final h = fixture.harness(scripts: [
          for (var i = 0; i < rounds; i++)
            _toolRound([_r7Call('read-$i', i)],
                const _TestContinuationState('private-reasoning-marker')),
          (request, token) async* {
            yield _r7Call('failed-fragment', 99);
            throw const AgentProviderException(
                AgentProviderFailure.rateLimited);
          },
        ]);
        final (cid, mid) = await h.seedUser('question');
        final session =
            h.runtime.startTurn(conversationId: cid, userMessageId: mid);
        expect(await session.result, isA<AgentTurnSuccess>());
        final request = h.fallbackProvider.requests.single;
        expect(request.continuationState, isNull);
        expect(request.toolOutputs, isEmpty);
        expect(request.tools, isEmpty);
        expect(request.messages.map((m) => m.content), ['question']);
        final groups = session.transcript!.toolGroups;
        expect(groups, hasLength(rounds));
        expect(request.canonicalToolHistory, hasLength(rounds));
        for (var i = 0; i < rounds; i++) {
          final exchange = request.canonicalToolHistory[i];
          expect(exchange.call, same(groups[i].call));
          expect(exchange.result, same(groups[i].result));
          expect(jsonDecode(exchange.result.output)['result'],
              '$i:${fixture.payload}');
          expect(groups[i].receipt.status, CapabilityExecutionStatus.completed);
        }
        expect(fixture.handlerEntries, rounds);
        expect(h.provider.callCount, rounds + 1);
        expect(h.fallbackProvider.lastToken, same(h.provider.lastToken));
        final messages = await h.messagesOf(cid);
        expect(messages.map((m) => m.role),
            [ConversationMessageRole.user, ConversationMessageRole.assistant]);
        expect(messages.last.content, 'continued');
        expect(sink.records.map((r) => r.data).toString(),
            isNot(contains(fixture.payload)));
        expect(messages.map((m) => m.content).toString(),
            isNot(contains(fixture.payload)));
      });
    }

    for (final denied in [
      'disabled',
      'missing-proof',
      'replaced-receipt',
      'stage-none',
      'stage-effect',
      'formal-mutation',
      'unknown-effect',
      'unknown-outcome',
      'failed-with-effect',
      'incompatible',
      'no-function-tools',
      'text',
      'web',
      'revoked-read',
      'revoked-release',
      'profile-deleted',
      'new-user',
      'scope-changed',
      'pruned',
      'minimum-overflow',
      'cancelled',
      'timeout',
      'ineligible'
    ]) {
      test('denies $denied and preserves failure without releasing to fallback',
          () async {
        final fixture = _ReadContinuationFixture(
            permission: denied.startsWith('stage')
                ? CapabilityPermission.stage
                : CapabilityPermission.read,
            status: denied == 'unknown-outcome'
                ? CapabilityExecutionStatus.outcomeUnknown
                : denied == 'failed-with-effect'
                    ? CapabilityExecutionStatus.failedWithoutEffect
                    : CapabilityExecutionStatus.completed,
            effect: switch (denied) {
              'stage-effect' => CapabilityEffect.proposalStaged,
              'formal-mutation' => CapabilityEffect.formalMutation,
              'unknown-effect' => null,
              'failed-with-effect' => CapabilityEffect.derivedCache,
              _ => CapabilityEffect.none,
            },
            carryPermit: denied != 'missing-proof',
            replaceReceipt: denied == 'replaced-receipt');
        late _Harness h;
        late AgentTurnSession session;
        late String cid;
        final scripts = <_Script>[
          _toolRound([_r7Call('read-1')],
              const _TestContinuationState('private-state')),
          if (denied == 'pruned')
            _toolRound([_r7Call('read-2', 2)],
                const _TestContinuationState('private-state-2')),
          (request, token) async* {
            if (denied == 'text') yield AgentProviderTextDelta('visible');
            if (denied == 'web') {
              yield const AgentProviderWebSearchEvent(
                  AgentProviderWebSearchPhase.searching);
            }
            if (denied == 'revoked-read') fixture.readAllowed = false;
            if (denied == 'revoked-release') fixture.releaseAllowed = false;
            if (denied == 'profile-deleted') {
              h.profileResolver.fallbackProfile = null;
            }
            if (denied == 'new-user') await h.appendUser(cid, 'new target');
            if (denied == 'scope-changed') {
              final c = h.repository._conversations[cid]!;
              h.repository._conversations[cid] = c.withScope(
                  scope: ConversationScope.unavailableLearningSpace(),
                  updatedAt: c.updatedAt);
            }
            if (denied == 'cancelled') session.cancel();
            if (denied == 'timeout') {
              await token.whenCancelled;
            }
            throw AgentProviderException(denied == 'ineligible'
                ? AgentProviderFailure.invalidRequest
                : AgentProviderFailure.rateLimited);
          },
        ];
        h = fixture.harness(
            scripts: scripts,
            enabled: denied != 'disabled',
            capabilities: denied == 'incompatible'
                ? const AgentProviderCapabilities(
                    functionTools: true, nativeWebSearch: true)
                : denied == 'no-function-tools'
                    ? const AgentProviderCapabilities(
                        functionTools: false,
                        nativeWebSearch: true,
                        canonicalToolHistory: true)
                    : null,
            limits: denied == 'pruned'
                ? const AgentRuntimeLimits(maxHistoryMessages: 2)
                : denied == 'minimum-overflow'
                    ? const AgentRuntimeLimits(maxHistoryUtf8Bytes: 20)
                    : denied == 'timeout'
                        ? const AgentRuntimeLimits(
                            turnTimeout: Duration(milliseconds: 60))
                        : null);
        final seeded = await h.seedUser('question');
        cid = seeded.$1;
        session =
            h.runtime.startTurn(conversationId: cid, userMessageId: seeded.$2);
        final result = await session.result;
        expect(result, isA<AgentTurnFailed>());
        expect(h.fallbackProvider.callCount, 0);
        expect(fixture.handlerEntries, denied == 'pruned' ? 2 : 1);
        if ([
          'disabled',
          'missing-proof',
          'replaced-receipt',
          'stage-none',
          'stage-effect',
          'formal-mutation',
          'unknown-effect',
          'incompatible',
          'no-function-tools',
          'text',
          'web',
          'revoked-read',
          'revoked-release',
          'profile-deleted',
          'new-user',
          'scope-changed',
          'pruned'
        ].contains(denied)) {
          expect(_failureOf(result), AgentTurnFailure.rateLimited);
        }
        expect(
            h.repository._messagesByConversation[cid]!
                .where((m) => m.role == ConversationMessageRole.assistant),
            isEmpty);
      });
    }

    for (final barrier in [
      'fallback-fails',
      'repeated-call',
      'cancel-authorization',
      'timeout-authorization'
    ]) {
      test(
          '$barrier does not rerun READ, reset deadline or attempt a third Provider',
          () async {
        final fixture = _ReadContinuationFixture();
        final entered = Completer<void>();
        final release = Completer<void>();
        if (barrier.endsWith('authorization')) {
          fixture.beforeTargetRelease = () async {
            entered.complete();
            await release.future;
          };
        }
        final h = fixture.harness(
            limits: barrier == 'timeout-authorization'
                ? const AgentRuntimeLimits(
                    turnTimeout: Duration(milliseconds: 60))
                : null,
            scripts: [
              _toolRound(
                  [_r7Call('read')], const _TestContinuationState('private')),
              _r7Failure()
            ],
            fallbackScripts: [
              barrier == 'repeated-call'
                  ? _toolRound([_r7Call('repeat')],
                      const _TestContinuationState('fallback'))
                  : _r7Failure(AgentProviderFailure.temporarilyUnavailable)
            ]);
        final (cid, mid) = await h.seedUser('question');
        final session =
            h.runtime.startTurn(conversationId: cid, userMessageId: mid);
        if (barrier.endsWith('authorization')) {
          await entered.future;
          if (barrier == 'cancel-authorization') session.cancel();
        }
        final result = await session.result;
        release.complete();
        expect(result, isA<AgentTurnFailed>());
        expect(fixture.handlerEntries, 1);
        expect(h.provider.callCount, 2);
        expect(h.fallbackProvider.callCount,
            barrier.endsWith('authorization') ? 0 : 1);
      });
    }

    test(
        'whole visible-history pruning is allowed; exact context-byte bound is inclusive',
        () async {
      for (final delta in [0, -1]) {
        final fixture = _ReadContinuationFixture();
        final call = _r7Call('read');
        final output =
            jsonEncode({'ok': true, 'result': '1:${fixture.payload}'});
        final bytes = utf8
            .encode(
                'question${call.callId}${call.name}${call.argumentsJson}$output')
            .length;
        final h = fixture.harness(
            limits: AgentRuntimeLimits(maxHistoryUtf8Bytes: bytes + delta),
            scripts: [
              _toolRound([call], const _TestContinuationState('private')),
              _r7Failure()
            ]);
        final (cid, _) = await h.seedUser('old');
        await h.appendAssistant(cid, 'old answer');
        await h.appendUser(cid, 'question');
        final messages = await h.messagesOf(cid);
        final result = await h.runtime
            .startTurn(
                conversationId: cid, userMessageId: messages.last.messageId)
            .result;
        expect(result,
            delta == 0 ? isA<AgentTurnSuccess>() : isA<AgentTurnFailed>());
        expect(h.fallbackProvider.callCount, delta == 0 ? 1 : 0);
        if (delta == 0) {
          expect(
              h.fallbackProvider.requests.single.messages.map((m) => m.content),
              ['question']);
        }
      }
    });

    test('shared tool budget remains closed after its last READ', () async {
      final fixture = _ReadContinuationFixture();
      final h = fixture.harness(
          limits: const AgentRuntimeLimits(maxLocalCalls: 1, maxToolRounds: 1),
          scripts: [
            _toolRound(
                [_r7Call('read')], const _TestContinuationState('private')),
            _r7Failure()
          ]);
      final (cid, mid) = await h.seedUser('question');
      expect(
          await h.runtime
              .startTurn(conversationId: cid, userMessageId: mid)
              .result,
          isA<AgentTurnSuccess>());
      expect(h.provider.requests.last.tools, isEmpty);
      expect(h.fallbackProvider.requests.single.tools, isEmpty);
      expect(fixture.handlerEntries, 1);
    });

    test('READ fallback uses the original global deadline and token', () async {
      final fixture = _ReadContinuationFixture();
      final h = fixture.harness(
          limits: const AgentRuntimeLimits(
              turnTimeout: Duration(milliseconds: 250)),
          scripts: [
            _toolRound(
                [_r7Call('read')], const _TestContinuationState('private')),
            _r7Failure()
          ],
          fallbackScripts: [
            (request, token) async* {
              await token.whenCancelled;
              token.throwIfCancelled();
            }
          ]);
      final (cid, mid) = await h.seedUser('question');
      final result = await h.runtime
          .startTurn(conversationId: cid, userMessageId: mid)
          .result;
      expect(_failureOf(result), AgentTurnFailure.timeout);
      expect(h.fallbackProvider.callCount, 1);
      expect(h.fallbackProvider.lastToken, same(h.provider.lastToken));
      expect(fixture.handlerEntries, 1);
    });

    test('R7 blocks configured Web capability mismatch before releasing READs',
        () async {
      final fixture = _ReadContinuationFixture();
      final h = _Harness(
          agentSurface: fixture.surface,
          enableBoundedReadContinuation: true,
          webEnabled: true,
          fallbackProfileId: 'profile-fallback',
          fallbackCapabilities: const AgentProviderCapabilities(
              functionTools: true,
              nativeWebSearch: false,
              canonicalToolHistory: true),
          scripts: [
            _toolRound(
                [_r7Call('read')], const _TestContinuationState('private')),
            _r7Failure()
          ]);
      final (cid, mid) = await h.seedUser('question');
      expect(
          _failureOf(await h.runtime
              .startTurn(conversationId: cid, userMessageId: mid)
              .result),
          AgentTurnFailure.rateLimited);
      expect(h.fallbackProvider.callCount, 0);
    });

    test('R7 never transfers completed file retrieval or its grant', () async {
      final h = _Harness(
          enableBoundedReadContinuation: true,
          wireRetrieval: true,
          fallbackProfileId: 'profile-fallback',
          fallbackCapabilities: _r7Capabilities,
          scripts: [
            _toolRound([
              _call('file-read',
                  name: AgentRetrievalToolCatalog.toolName,
                  arguments: '{"query":"function","file_ids":["file-1"]}')
            ], const _TestContinuationState('private')),
            _r7Failure()
          ]);
      final (cid, mid) = await h.seedUser('question', fileIds: ['file-1']);
      final session = h.runtime.startTurnWithRetrieval(
          conversationId: cid,
          userMessageId: mid,
          approval: RetrievalEgressApproval(['file-1']));
      expect(_failureOf(await session.result), AgentTurnFailure.rateLimited);
      expect(session.transcript!.toolGroups.single.egress, isNotNull);
      expect(h.fallbackProvider.callCount, 0);
    });

    test('R7 still blocks a file-approved turn before any READ', () async {
      final h = _Harness(
          enableBoundedReadContinuation: true,
          fallbackProfileId: 'profile-fallback',
          scripts: [_r7Failure()],
          fallbackScripts: [_finalAnswer('forbidden')]);
      final (cid, mid) = await h.seedUser('question', fileIds: ['file-1']);
      final result = await h.runtime
          .startTurnWithRetrieval(
              conversationId: cid,
              userMessageId: mid,
              approval: RetrievalEgressApproval(['file-1']))
          .result;
      expect(result, isA<AgentTurnFailed>());
      expect(h.fallbackProvider.callCount, 0);
    });
  });
}
