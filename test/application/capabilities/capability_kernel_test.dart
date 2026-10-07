import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';

const _read = CapabilityId<int, String>('synthetic_read');
const _stage = CapabilityId<int, String>('synthetic_stage');

CapabilityContext _context({
  Iterable<CapabilityId> capabilities = const [_read, _stage],
  Iterable<CapabilityPermission> permissions = const [
    CapabilityPermission.read,
    CapabilityPermission.stage
  ],
  CapabilityPrincipal principal = CapabilityPrincipal.builtInAgent,
  ConversationScope? scope,
  Future<bool> Function()? authorize,
  bool Function()? budget,
  bool Function()? cancelled,
  Future<void>? signal,
  DateTime? deadline,
}) =>
    CapabilityContext(
        principal: principal,
        capabilities: capabilities,
        permissions: permissions,
        scope: scope ?? ConversationScope.global(),
        authorizedScope: ConversationScope.global(),
        authorizationCurrent: authorize,
        budgetAllowed: budget,
        isCancelled: cancelled,
        cancellationSignal: signal,
        deadline: deadline);

CapabilityDefinition<int, String> _definition({
  CapabilityId<int, String> id = _read,
  CapabilityPermission permission = CapabilityPermission.read,
  Future<CapabilityEvidence<String>> Function(
          int, CapabilityContext, CapabilityExecutionEvidence)?
      handler,
  CapabilityFailure? Function(int)? admit,
  Future<bool> Function(int, CapabilityContext)? release,
}) =>
    CapabilityDefinition<int, String>(
        id: id,
        permission: permission,
        permittedEffects: const [
          CapabilityEffect.none,
          CapabilityEffect.proposalStaged,
          CapabilityEffect.derivedCache
        ],
        semantics: permission == CapabilityPermission.read
            ? CapabilityExecutionSemantics.repeatableRead
            : CapabilityExecutionSemantics.transientStage,
        admit: admit,
        release: release,
        handler: CapabilityHandler<int, String>(handler ??
            (input, _, __) async =>
                CapabilityEvidence.completed('$input', CapabilityEffect.none)));

void main() {
  test(
      'registry freezes explicit deterministic registration and rejects duplicates',
      () {
    final definitions = [
      _definition(),
      _definition(id: _stage, permission: CapabilityPermission.stage)
    ];
    final registry = ApplicationCapabilityRegistry(definitions);
    definitions.clear();
    expect(registry.definitions.map((d) => d.id), [_read, _stage]);
    expect(() => registry.definitions.clear(), throwsUnsupportedError);
    expect(() => registry.definitions.first.permittedEffects.clear(),
        throwsUnsupportedError);
    expect(registry.definition(_read)!.handler.inputType, int);
    expect(() => ApplicationCapabilityRegistry([_definition(), _definition()]),
        throwsArgumentError);
  });

  test('input/output identity and definition/handler mismatches fail fast', () {
    final registry = ApplicationCapabilityRegistry([_definition()]);
    expect(
        () => registry
            .definition(const CapabilityId<String, String>('synthetic_read')),
        throwsArgumentError);
    expect(
        () =>
            registry.definition(const CapabilityId<int, int>('synthetic_read')),
        throwsArgumentError);
    expect(
        () => CapabilityDefinition<Object, Object>(
            id: _read,
            permission: CapabilityPermission.read,
            permittedEffects: const [CapabilityEffect.none],
            semantics: CapabilityExecutionSemantics.repeatableRead,
            handler: CapabilityHandler<Object, Object>((_, __, ___) async =>
                CapabilityEvidence.completed(Object(), CapabilityEffect.none))),
        throwsArgumentError);
    final dynamic wrongHandler = CapabilityHandler<String, String>(
        (_, __, ___) async =>
            CapabilityEvidence.completed('x', CapabilityEffect.none));
    expect(
        () => CapabilityDefinition<int, String>(
            id: _read,
            permission: CapabilityPermission.read,
            permittedEffects: const [CapabilityEffect.none],
            semantics: CapabilityExecutionSemantics.repeatableRead,
            handler: wrongHandler),
        throwsA(isA<TypeError>()));
  });

  test(
      'direct admission/authorization/scope/budget rejection never enters handler',
      () async {
    var calls = 0;
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
      _definition(
          admit: (i) => i < 0 ? CapabilityFailure.invalidRequest : null,
          handler: (i, _, __) async {
            calls++;
            return CapabilityEvidence.completed('$i', CapabilityEffect.none);
          }),
      _definition(
          id: _stage,
          permission: CapabilityPermission.stage,
          handler: (i, _, __) async {
            calls++;
            return CapabilityEvidence.completed(
                '$i', CapabilityEffect.proposalStaged);
          }),
    ]));
    for (final context in [
      _context(capabilities: const []),
      _context(principal: CapabilityPrincipal.denied),
      _context(scope: ConversationScope.learningSpace('other')),
      _context(authorize: () async => false),
      _context(budget: () => false),
      _context(cancelled: () => true),
      _context(deadline: DateTime.utc(2000)),
    ]) {
      final result = await executor.execute(_read, 1, context);
      expect(result.output, isNull);
      expect(result.receipt.status, CapabilityExecutionStatus.notStarted);
      expect(result.receipt.knownEffect, CapabilityEffect.none);
    }
    final deniedStage = await executor.execute(
        _stage, 1, _context(permissions: const [CapabilityPermission.read]));
    expect(deniedStage.failure, CapabilityFailure.accessDenied);
    expect((await executor.execute(_read, -1, _context())).failure,
        CapabilityFailure.invalidRequest);
    expect(
        (await executor.execute(
                const CapabilityId<int, String>('unknown'), 1, _context()))
            .receipt
            .status,
        CapabilityExecutionStatus.notStarted);
    expect(calls, 0);
    final allowed = await executor.execute(_read, 1, _context());
    expect(allowed.output, '1');
    expect(calls, 1);
    expect(allowed.receipt.status, CapabilityExecutionStatus.completed);
  });

  test(
      'fixed order includes final authorization and egress; receipt is App-generated',
      () async {
    final events = <String>[];
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
      _definition(admit: (_) {
        events.add('admission');
        return null;
      }, handler: (_, __, ___) async {
        events.add('handler');
        return CapabilityEvidence.completed('safe', CapabilityEffect.none);
      }, release: (_, __) async {
        events.add('egress');
        return true;
      }),
    ]));
    final context = _context(authorize: () async {
      events.add('authorization');
      return true;
    }, budget: () {
      events.add('budget');
      return true;
    });
    final a = await executor.execute(_read, 1, context);
    expect(events, [
      'admission',
      'authorization',
      'budget',
      'handler',
      'budget',
      'authorization',
      'egress'
    ]);
    final b = await executor.execute(_read, 1, context);
    expect(a.receipt.executionId, isNot(b.receipt.executionId));
    expect(a.receipt.executionId, matches(RegExp(r'^[a-f0-9-]{36}$')));
  });

  test(
      'caught handler error is unknown; owning zero-effect evidence is distinct',
      () async {
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
      _definition(
          handler: (_, __, ___) async => throw StateError('private marker')),
      _definition(
          id: _stage,
          permission: CapabilityPermission.stage,
          handler: (_, __, ___) async => CapabilityEvidence.zeroEffectFailure(
              CapabilityFailure.cancelled)),
    ]));
    final unknown = await executor.execute(_read, 1, _context());
    expect(unknown.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
    expect(unknown.receipt.knownEffect, isNull);
    final zero = await executor.execute(_stage, 1, _context());
    expect(zero.receipt.status, CapabilityExecutionStatus.failedWithoutEffect);
    expect(zero.receipt.knownEffect, CapabilityEffect.none);
  });

  test('cancellation after entry retains confirmed effects and never repeats',
      () async {
    final entered = Completer<void>();
    final cancel = Completer<void>();
    final finish = Completer<CapabilityEvidence<String>>();
    var calls = 0;
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
      _definition(
          id: _stage,
          permission: CapabilityPermission.stage,
          handler: (_, __, confirmed) {
            calls++;
            confirmed.confirm(CapabilityEffect.proposalStaged);
            entered.complete();
            return finish.future;
          }),
    ]));
    final pending =
        executor.execute(_stage, 1, _context(signal: cancel.future));
    await entered.future;
    cancel.complete();
    final result = await pending;
    expect(result.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
    expect(result.receipt.knownEffect, CapabilityEffect.proposalStaged);
    expect(result.output, isNull);
    finish.complete(
        CapabilityEvidence.completed('late', CapabilityEffect.proposalStaged));
    await Future<void>.value();
    expect(result.output, isNull);
    expect(calls, 1);
  });

  test('deadline after handler entry is unknown, never a zero-effect failure',
      () async {
    final entered = Completer<void>();
    final finish = Completer<CapabilityEvidence<String>>();
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
      _definition(handler: (_, __, ___) {
        entered.complete();
        return finish.future;
      }),
    ]));
    final pending = executor.execute(_read, 1,
        _context(deadline: DateTime.now().add(const Duration(seconds: 1))));
    await entered.future;
    final result = await pending;
    expect(result.receipt.failure, CapabilityFailure.deadlineExceeded);
    expect(result.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
    expect(result.receipt.knownEffect, isNull);
    finish
        .complete(CapabilityEvidence.completed('late', CapabilityEffect.none));
  });

  test(
      'egress revocation and adapter failure preserve completed effect evidence',
      () async {
    var calls = 0;
    for (final failWithException in [false, true]) {
      final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
        _definition(handler: (_, __, ___) async {
          calls++;
          return CapabilityEvidence.completed(
              'private output', CapabilityEffect.derivedCache);
        }, release: (_, __) async {
          if (failWithException) throw StateError('private');
          return false;
        }),
      ]));
      final result = await executor.execute(_read, 1, _context());
      expect(result.output, isNull);
      expect(result.failure, CapabilityFailure.accessDenied);
      expect(result.receipt.status, CapabilityExecutionStatus.completed);
      expect(result.receipt.knownEffect, CapabilityEffect.derivedCache);
    }
    expect(calls, 2);
  });

  test(
      'cancellation during authorization is not_started; during egress retains handler evidence',
      () async {
    for (final beforeHandler in [true, false]) {
      final reached = Completer<void>();
      final gate = Completer<bool>();
      final cancelled = Completer<void>();
      var calls = 0;
      final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
        _definition(handler: (_, __, ___) async {
          calls++;
          return CapabilityEvidence.completed(
              'safe', CapabilityEffect.derivedCache);
        }, release: (_, __) {
          reached.complete();
          return gate.future;
        }),
      ]));
      final context = _context(
          signal: cancelled.future,
          authorize: beforeHandler
              ? () {
                  reached.complete();
                  return gate.future;
                }
              : null);
      final pending = executor.execute(_read, 1, context);
      await reached.future;
      cancelled.complete();
      final result = await pending;
      expect(calls, beforeHandler ? 0 : 1);
      expect(result.output, isNull);
      expect(
          result.receipt.status,
          beforeHandler
              ? CapabilityExecutionStatus.notStarted
              : CapabilityExecutionStatus.completed);
      expect(
          result.receipt.knownEffect,
          beforeHandler
              ? CapabilityEffect.none
              : CapabilityEffect.derivedCache);
      gate.complete(true);
    }
  });

  test('kernel and handlers cannot depend on projections, transports or UI',
      () {
    final paths = [
      'lib/application/capabilities/capability.dart',
      'lib/application/study_query/study_capabilities.dart',
      'lib/application/retrieval/retrieval_capability.dart',
      'lib/application/safe_write/missing_answer_capability.dart',
      'lib/application/study_plan/study_plan_capability.dart',
    ];
    for (final path in paths) {
      final source = File(path).readAsStringSync();
      for (final token in [
        "package:flutter/",
        'package:mcp_dart',
        'dart:io',
        'AgentFunctionToolDefinition',
        'AgentProviderFunctionCall',
        'agent_provider.dart',
        'tool_dispatcher.dart',
        'inputSchema',
        'jsonEncode',
        'CapabilityManager',
        'CapabilityFactoryRegistry',
        'DynamicCapabilityResolver'
      ]) {
        expect(source, isNot(contains(token)), reason: '$path: $token');
      }
    }
  });
}
