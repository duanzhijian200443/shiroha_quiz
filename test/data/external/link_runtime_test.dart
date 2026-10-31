import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/link/host_handoff.dart';
import 'package:shiroha_quiz/data/external/link/link_adapter_process.dart';
import 'package:shiroha_quiz/data/external/link/link_installation.dart';
import 'package:shiroha_quiz/data/external/link/link_runtime.dart';
import 'package:shiroha_quiz/data/external/link/link_state_store.dart';
import 'package:shiroha_quiz/data/external/link/link_values.dart';
import 'package:shiroha_quiz/data/external/windows_local_relay.dart';
import 'link_handoff_test.dart' show OldOwner, preparedRecord;

final class Backend implements LinkBackend {
  Backend(this.owner);
  @override
  final LinkOwnerReference owner;
  @override
  LinkVerifiedTarget get target => preparedRecord().target;
  final entered = Completer<void>();
  final lost = Completer<void>();
  @override
  Future<void> get disconnected => lost.future;
  final result = Completer<Map<String, Object?>>();
  bool cancelled = false, closed = false, failClose = false;
  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled}) async {
    final subscription = cancelled.listen((_) => this.cancelled = true);
    entered.complete();
    try {
      return await result.future;
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (failClose) throw const LinkException('owner_unsettled');
  }
}

/// Simulates a pipe whose unread output would be discarded by close.
final class ControlPipe implements LocalRelayServerConnection {
  ControlPipe({this.pendingAccept = false});
  final bool pendingAccept;
  final accepted = Completer<void>();
  final input = StreamController<Map<String, Object?>>();
  final output = StreamController<Map<String, Object?>>();
  late final reader = StreamIterator(input.stream);
  bool closed = false;
  @override
  bool get isCurrent => !closed && !pendingAccept;
  @override
  String get linkPeerIdentity => 'test-peer';
  @override
  Future<void> accept() async {
    if (pendingAccept) {
      await accepted.future;
      throw const LocalRelayException();
    }
  }

  @override
  Future<void> send(Map<String, Object?> message, Duration deadline) async =>
      output.add(message);
  @override
  Future<Map<String, Object?>> receive(Duration deadline) async {
    if (!await reader.moveNext()) throw const LocalRelayException();
    return reader.current;
  }

  @override
  Future<void> disconnect() async => close();
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!accepted.isCompleted) accepted.complete();
  }

  Future<void> dispose() async {
    final unread = pendingAccept ? input.stream.drain<void>() : null;
    if (!pendingAccept) await reader.cancel();
    await input.close();
    await unread;
    final drain = pendingAccept ? output.stream.drain<void>() : null;
    await output.close();
    await drain;
  }
}

void main() {
  late Directory root;
  late LinkRuntime runtime;
  late LinkStateStore store;
  late Backend backend;
  var starts = 0;
  var loseDuringAttach = false;
  Future<void> attach() async {
    await runtime.connect();
    await runtime.attach('verified-peer', 'frontend-1');
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('link-runtime-');
    final state = await Directory(p.join(root.path, 'state')).create();
    final slot = await Directory(p.join(root.path, 'slot')).create();
    store = await LinkStateStore.open(state, initializeInstance: 'new-owner');
    final handoff = HostHandoffStore(slot);
    await handoff.release(OldOwner(handoff), 'new-owner');
    await handoff.claim(store, slotRef: 'phone');
    starts = 0;
    loseDuringAttach = false;
    runtime = LinkRuntime(
        installation: LinkInstallation(
            stateDirectory: state.path,
            slotDirectory: slot.path,
            slotRef: 'phone',
            connectorInstanceId: 'new-owner',
            adapterExecutable: 'unused'),
        store: store,
        backendFactory: (
            {required proof,
            required runId,
            required resourceId,
            required acquired}) async {
          starts++;
          final owner = LinkOwnerReference(
              runId: runId,
              resourceId: resourceId,
              processId: 123,
              processStarted: 'synthetic-creation',
              slotRef: 'phone');
          await acquired(owner);
          backend = Backend(owner);
          if (!proof && loseDuringAttach) backend.lost.complete();
          return backend;
        });
  });
  tearDown(() async {
    try {
      await runtime.close();
    } catch (_) {
      await store.close();
    }
    await root.delete(recursive: true);
  });
  test(
      'control shutdown retains its original output until the client receives it',
      () async {
    final business = ControlPipe(pendingAccept: true), control = ControlPipe();
    final responses = StreamIterator(control.output.stream);
    final serving = LinkPipeServer(runtime, business, control).serve();
    expect(
        await responses.moveNext().timeout(const Duration(seconds: 5),
            onTimeout: () => throw StateError('hello_not_observed')),
        isTrue);
    final hello = responses.current;
    control.input.add({
      ...hello,
      'action': 'shutdown',
      'targetRef': null,
      'expectedSelectionRevision': null,
      'expectedRevision': null
    });
    expect(
        await responses.moveNext().timeout(const Duration(seconds: 5),
            onTimeout: () => throw StateError('result_not_observed')),
        isTrue);
    expect(responses.current['error'], isNull);
    await Future<void>.delayed(Duration.zero);
    expect(control.closed, isFalse);
    expect(business.closed, isFalse);
    control.input.add({...hello, 'kind': 'received'});
    await serving.timeout(const Duration(seconds: 5),
        onTimeout: () => throw StateError('server_not_settled'));
    expect(control.closed, isTrue);
    expect(business.closed, isTrue);
    await responses.cancel().timeout(const Duration(seconds: 5));
    await control.dispose().timeout(const Duration(seconds: 5),
        onTimeout: () => throw StateError('control_fixture_not_disposed'));
    await business.dispose().timeout(const Duration(seconds: 5),
        onTimeout: () => throw StateError('business_fixture_not_disposed'));
  });
  test('idle adapter loss withdraws availability and cannot revive its lease',
      () async {
    await attach();
    backend.failClose = true;
    backend.lost.complete();
    await Future<void>.delayed(Duration.zero);
    expect(runtime.inspect()['ready'], isFalse);
    expect(runtime.mayDeliver('verified-peer', 'frontend-1'), isFalse);
    await expectLater(runtime.disconnect(), throwsA(isA<LinkException>()));
    expect(store.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
    await expectLater(
        runtime.call('verified-peer', 'frontend-1', 1, 'open_context', {}),
        throwsA(isA<LinkException>()));
    expect(starts, 2);
  });
  test('loss during lease publication joins the original attach before close',
      () async {
    await runtime.connect();
    loseDuringAttach = true;
    await expectLater(runtime.attach('verified-peer', 'frontend-1'),
        throwsA(isA<LinkException>()));
    await runtime.disconnect();
    expect(runtime.inspect()['ready'], isFalse);
    expect(store.state.lease, isNull);
    expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
    expect(backend.closed, isTrue);
  });
  test('explicit cancellation during the initial journal write is not lost',
      () async {
    await attach();
    final call =
        runtime.call('verified-peer', 'frontend-1', 2, 'open_context', {});
    runtime.cancel('verified-peer', 'frontend-1', 2);
    await backend.entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(backend.cancelled, isTrue);
    backend.result.completeError(StateError('synthetic_cancel'));
    await call;
  });
  test('a second shutdown preserves the first failed settlement result',
      () async {
    await attach();
    backend.failClose = true;
    await expectLater(runtime.close(), throwsA(isA<LinkException>()));
    await expectLater(runtime.close(), throwsA(isA<LinkException>()));
    expect(store.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
  });

  test(
      'construction never authenticates; second frontend cannot replace original lease',
      () async {
    expect(starts, 0);
    await attach();
    final lease = store.state.lease!;
    await expectLater(runtime.attach('different-peer', 'frontend-2'),
        throwsA(isA<LinkException>()));
    expect(starts, 2);
    expect(store.state.lease!.leaseId, lease.leaseId);
    expect(lease.frontendPeerIdentity, 'verified-peer');
    expect(lease.target.toJson(), preparedRecord().target.toJson());
    expect(lease.connectorRunId, runtime.runId);
  });
  test('frontend loss joins original call without manufacturing cancellation',
      () async {
    await attach();
    final call = runtime
        .call('verified-peer', 'frontend-1', 1, 'get_study_overview', {});
    await backend.entered.future;
    var done = false;
    final close = runtime.disconnect().then((_) => done = true);
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);
    expect(backend.closed, isFalse);
    expect(backend.cancelled, isFalse);
    backend.result.complete({
      'profileVersion': 3,
      'data': {},
      'error': null,
      'source': {'kind': 'android', 'deviceRef': 'a' * 64}
    });
    await call;
    await close;
    expect(backend.closed, isTrue);
    expect(backend.cancelled, isFalse);
    expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
    expect(store.state.delivery, LinkDelivery.unknown);
    expect(store.state.businessResult, LinkBusinessResult.returned);
  });
  test('only matching peer, connection and request may cancel', () async {
    await attach();
    final call = runtime.call(
        'verified-peer', 'frontend-1', 9, 'propose_generated_questions', {});
    await backend.entered.future;
    runtime.cancel('foreign', 'frontend-1', 9);
    runtime.cancel('verified-peer', 'old-frontend', 9);
    runtime.cancel('verified-peer', 'frontend-1', 8);
    await Future<void>.delayed(Duration.zero);
    expect(backend.cancelled, isFalse);
    runtime.cancel('verified-peer', 'frontend-1', 9);
    await Future<void>.delayed(Duration.zero);
    expect(backend.cancelled, isTrue);
    backend.result.completeError(StateError('synthetic_unknown'));
    expect((await call)['error'], 'outcome_unknown');
    expect(starts, 2); // no retry or second key/request
  });
  test(
      'failed original close retains target, lease, revision and dirty custody',
      () async {
    await attach();
    backend.failClose = true;
    final selection = store.state.selectionRevision,
        lease = store.state.lease!.leaseId;
    await expectLater(
        runtime.select('phone', selection), throwsA(isA<LinkException>()));
    expect(store.state.targetRef, 'phone');
    expect(store.state.selectionRevision, selection);
    expect(store.state.lease!.leaseId, lease);
    expect(store.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
    await expectLater(runtime.connect(), throwsA(isA<LinkException>()));
    expect(starts, 2);
  });
  test(
      'switch settles old owner before changing generation and rejects old connection',
      () async {
    await attach();
    final old = store.state;
    await runtime.select('phone', old.selectionRevision);
    expect(backend.closed, isTrue);
    expect(store.state.routeGeneration, greaterThan(old.routeGeneration));
    expect(store.state.selectionRevision, old.selectionRevision + 1);
    expect(store.state.lease, isNull);
    await expectLater(
        runtime.call('verified-peer', 'frontend-1', 1, 'open_context', {}),
        throwsA(isA<LinkException>()));
  });
}
