/// Dependency-free unit runner: execute this exact file with the Dart VM.
/// No Flutter host, test service, plugins, database, files or network fixtures.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/data/external/local_protocol_memory.dart';

void check(bool condition) {
  if (!condition) throw StateError('Memory assertion failed');
}

void coreFailure(void Function() action, ExternalFailure expected) {
  try {
    action();
  } on ExternalCoreException catch (error) {
    check(error.failure == expected);
    return;
  }
  throw StateError('Expected core rejection');
}

void frameFailure(
    MemoryFrameDecoder decoder, Uint8List input, MemoryFrameFailure expected) {
  try {
    decoder.feed(input);
  } on MemoryFrameException catch (error) {
    check(error.failure == expected);
    check(decoder.isClosed &&
        decoder.allocatedBodyBytes == 0 &&
        decoder.bufferedBytes == 0);
    return;
  }
  throw StateError('Expected framing rejection');
}

final class FakeClock implements ExternalClock {
  DateTime value = DateTime.utc(2026);
  @override
  DateTime now() => value;
  void advance(Duration duration, [ExternalCallControl? control]) {
    value = value.add(duration);
    control?.checkDeadline();
  }
}

final class FakeCredentialPort implements ExternalCredentialPort {
  final attempts = <Object, AuthenticatedPeerEvidence>{};
  final proofs = <Object, PairingProof>{};
  int authentications = 0;
  bool throwAuthentication = false;
  bool throwProof = false;
  @override
  AuthenticatedPeerEvidence? authenticate(Object attempt) {
    authentications++;
    if (throwAuthentication) throw StateError('Synthetic failure');
    return attempts[attempt];
  }

  @override
  PairingProof? provePossession(Object attempt) {
    if (throwProof) throw StateError('Synthetic failure');
    return proofs[attempt];
  }
}

final class FakeGrantState {
  int revision = 1;
  bool active = true;
  bool read = true;
  bool stage = true;
  final scope = Object();
}

final class FakeReceiptStore {
  final receipts = <(ExternalPrincipal, String), CapabilityEvidence<String>>{};
}

final class FakeHandler implements ExternalCapabilityPort<int, String> {
  FakeHandler(this.principal, this.grant, this.receipts);
  final ExternalPrincipal principal;
  final FakeGrantState grant;
  final FakeReceiptStore receipts;
  int calls = 0;
  int queries = 0;
  int publications = 0;
  Completer<CapabilityEvidence<String>>? pending;
  Completer<CapabilityEvidence<String>>? pendingQuery;
  void Function()? beforePublication;
  bool throwInvocation = false;
  bool throwAuthorization = false;
  bool confirmBeforeWaiting = false;
  CapabilityEffect effect = CapabilityEffect.none;

  @override
  bool authorize(ExternalAuthorizedContext context,
      CapabilityPermission permission, ExternalInvocationPhase phase) {
    if (throwAuthorization) throw StateError('Synthetic failure');
    return identical(context.principal, principal) &&
        grant.active &&
        context.revision == grant.revision &&
        identical(context.scope, grant.scope) &&
        (permission == CapabilityPermission.read ? grant.read : grant.stage);
  }

  @override
  Future<CapabilityEvidence<String>> invoke(
      int input,
      ExternalAuthorizedContext context,
      CapabilityExecutionEvidence evidence,
      String? submissionKey) async {
    calls++;
    if (throwInvocation) throw StateError('Synthetic failure');
    if (confirmBeforeWaiting) evidence.confirm(effect);
    if (pending != null) return pending!.future;
    beforePublication?.call();
    if (!authorize(
        context,
        submissionKey == null
            ? CapabilityPermission.read
            : CapabilityPermission.stage,
        ExternalInvocationPhase.execution)) {
      return CapabilityEvidence.zeroEffectFailure(
          CapabilityFailure.accessDenied);
    }
    final result = CapabilityEvidence.completed('synthetic-result', effect);
    if (submissionKey != null) {
      publications++;
      receipts.receipts[(principal, submissionKey)] = result;
    }
    return result;
  }

  @override
  Future<CapabilityEvidence<String>> reconcile(
      ExternalAuthorizedContext context, String submissionKey) async {
    queries++;
    if (pendingQuery != null) return pendingQuery!.future;
    return receipts.receipts[(principal, submissionKey)] ??
        const CapabilityEvidence(
            status: CapabilityExecutionStatus.outcomeUnknown, effect: null);
  }
}

final class Fixture {
  Fixture(
      {int maxConnections = 8,
      int perSession = 4,
      int global = 16,
      int stageKeys = 64}) {
    trust = ExternalTrustCore(
        credentials: credentials,
        clock: clock,
        mintProfileId: () => 'profile-${++ids}');
    principal = trust.createProfile();
    handler = FakeHandler(principal, grant, receipts);
    read = ExternalOperation(const CapabilityId<int, String>('memory.read'),
        CapabilityPermission.read, handler);
    stage = ExternalOperation(const CapabilityId<int, String>('memory.stage'),
        CapabilityPermission.stage, handler);
    invocations = ExternalInvocationCore([read, stage],
        maxInFlightPerSession: perSession,
        maxInFlight: global,
        maxStageKeys: stageKeys);
    hub = MemoryProtocolHub(
        trust: trust,
        invocations: invocations,
        installation: 'synthetic-installation',
        maxConnections: maxConnections);
  }
  final clock = FakeClock();
  final credentials = FakeCredentialPort();
  final grant = FakeGrantState();
  final receipts = FakeReceiptStore();
  final authentication = Object();
  final proof = Object();
  int ids = 0;
  late final ExternalTrustCore trust;
  late final ExternalPrincipal principal;
  late final FakeHandler handler;
  late final ExternalOperation<int, String> read;
  late final ExternalOperation<int, String> stage;
  late final ExternalInvocationCore invocations;
  late final MemoryProtocolHub hub;

  void request() {
    trust.requestPairing(principal,
        requestId: 'request', credentialIdentity: 'credential');
    credentials.proofs[proof] = const PairingProof('request', 'credential');
    credentials.attempts[authentication] =
        const AuthenticatedPeerEvidence('credential');
  }

  void pair() {
    request();
    trust.approvePairing(principal);
    trust.completePairing(principal, proof);
  }

  void enable() => trust.enable(principal, const Duration(minutes: 5));
  MemoryProtocolConnection ready() {
    pair();
    enable();
    return reconnect();
  }

  MemoryProtocolConnection reconnect() {
    final connection = hub.connect(authentication);
    connection.acknowledge(connection.hello);
    return connection;
  }

  ExternalAuthorizedContext context(
          {ExternalPrincipal? owner,
          int? revision,
          int? generation,
          Object? scope}) =>
      ExternalAuthorizedContext(
          principal: owner ?? principal,
          generation: generation ?? trust.generation,
          revision: revision ?? grant.revision,
          scope: scope ?? grant.scope);
  ExternalCallControl control({Duration? deadline}) => ExternalCallControl(
      clock: clock,
      deadline: deadline == null ? null : clock.now().add(deadline));
  Future<ExternalInvocationResult<String>> call(
          MemoryProtocolConnection connection,
          {bool staging = false,
          String requestId = 'call',
          String key = 'original-key',
          ExternalAuthorizedContext? authority,
          ExternalCallControl? cancellation,
          ExternalOperation<int, String>? operation}) =>
      connection.invoke(
          context: authority ?? context(),
          operation: operation ?? (staging ? stage : read),
          requestId: requestId,
          input: 1,
          control: cancellation ?? control(),
          submissionKey: staging ? key : null);
  Future<ExternalInvocationResult<String>> query(
          {ExternalAuthorizedContext? authority,
          ExternalCallControl? cancellation}) =>
      invocations.reconcile(
          session: trust.openSession(trust.authenticate(authentication)),
          context: authority ?? context(),
          operation: stage,
          submissionKey: 'original-key',
          control: cancellation ?? control(),
          responseAvailable: () => true);
}

void rejected(
    ExternalInvocationResult<String> result, Fixture f, ExternalFailure failure,
    {int calls = 0,
    ExternalInvocationPhase phase = ExternalInvocationPhase.admission,
    CapabilityExecutionStatus status = CapabilityExecutionStatus.notStarted,
    CapabilityEffect? effect = CapabilityEffect.none}) {
  check(result.phase == phase &&
      result.failure == failure &&
      result.output == null);
  check(result.status == status &&
      result.effect == effect &&
      f.handler.calls == calls);
}

Uint8List rawFrame(String body, {int kind = 0}) =>
    byteFrame(utf8.encode(body), kind: kind);
Uint8List byteFrame(List<int> body, {int kind = 0}) {
  final result = Uint8List(5 + body.length);
  result[0] = kind;
  ByteData.sublistView(result).setUint32(1, body.length);
  result.setRange(5, result.length, body);
  return result;
}

Uint8List lengthHeader(int length, {int kind = 0}) {
  final result = Uint8List(5);
  result[0] = kind;
  ByteData.sublistView(result).setUint32(1, length);
  return result;
}

final helloFields = <String, Object?>{
  'type': 'hello_ack',
  'version': 1,
  'installation': 'synthetic-installation',
  'generation': 1
};
final requestFields = <String, Object?>{
  'type': 'request',
  'requestId': 'a',
  'capability': 'memory.read',
  'context': 'opaque',
  'body': <String, Object?>{}
};

Future<void> main() async {
  final cases = <String, FutureOr<void> Function()>{
    'unpaired cannot enable or authenticate': () {
      final f = Fixture();
      coreFailure(f.enable, ExternalFailure.unpaired);
      coreFailure(() => f.hub.connect(f.authentication),
          ExternalFailure.authenticationRejected);
      check(f.handler.calls == 0 && f.hub.connectionCount == 0);
      check(f.trust.snapshot(f.principal).state == PairingState.unpaired);
    },
    'request pending and approved pending proof remain unpaired': () {
      final f = Fixture();
      f.request();
      coreFailure(
          () => f.hub.connect(f.authentication), ExternalFailure.unpaired);
      f.trust.approvePairing(f.principal);
      coreFailure(f.enable, ExternalFailure.unpaired);
      coreFailure(() => f.trust.completePairing(f.principal, Object()),
          ExternalFailure.authenticationRejected);
      check(f.trust.snapshot(f.principal).state ==
          PairingState.approvedPendingProof);
      check(f.handler.calls == 0);
    },
    'wrong credential or request proof cannot complete pairing': () {
      final f = Fixture();
      f.request();
      f.trust.approvePairing(f.principal);
      for (final proof in [
        const PairingProof('wrong', 'credential'),
        const PairingProof('request', 'wrong')
      ]) {
        f.credentials.proofs[f.proof] = proof;
        coreFailure(() => f.trust.completePairing(f.principal, f.proof),
            ExternalFailure.authenticationRejected);
      }
      check(f.trust.snapshot(f.principal).state ==
          PairingState.approvedPendingProof);
    },
    'duplicate pairing request preserves one identity': () {
      final f = Fixture();
      f.request();
      f.request();
      f.trust.approvePairing(f.principal);
      f.trust.completePairing(f.principal, f.proof);
      f.request();
      final peer = f.trust.authenticate(f.authentication);
      check(identical(peer.principal, f.principal) && f.ids == 1);
      check(f.trust.snapshot(f.principal).state == PairingState.pairedDisabled);
    },
    'conflicting request and cross-profile credential reuse reject': () {
      final f = Fixture();
      f.request();
      coreFailure(
          () => f.trust.requestPairing(f.principal,
              requestId: 'request', credentialIdentity: 'different'),
          ExternalFailure.pairingConflict);
      final other = f.trust.createProfile();
      coreFailure(
          () => f.trust.requestPairing(other,
              requestId: 'other', credentialIdentity: 'credential'),
          ExternalFailure.pairingConflict);
      coreFailure(
          () => f.trust.requestPairing(other,
              requestId: 'request', credentialIdentity: 'different'),
          ExternalFailure.pairingConflict);
      check(f.trust.snapshot(other).state == PairingState.unpaired);
    },
    'paired defaults disabled until explicit finite enable': () {
      final f = Fixture();
      f.pair();
      final c = f.hub.connect(f.authentication);
      coreFailure(() => c.acknowledge(c.hello), ExternalFailure.disabled);
      check(c.state == MemoryConnectionState.closed && f.handler.calls == 0);
      coreFailure(() => f.trust.enable(f.principal, Duration.zero),
          ExternalFailure.invalidRequest);
      coreFailure(() => f.trust.enable(f.principal, const Duration(days: 1)),
          ExternalFailure.invalidRequest);
      f.enable();
      check(f.reconnect().state == MemoryConnectionState.ready);
    },
    'only selected profile is enabled': () {
      final f = Fixture();
      f.ready();
      final other = f.trust.createProfile();
      f.trust.requestPairing(other,
          requestId: 'other', credentialIdentity: 'other');
      f.trust.approvePairing(other);
      final proof = Object();
      final auth = Object();
      f.credentials.proofs[proof] = const PairingProof('other', 'other');
      f.credentials.attempts[auth] = const AuthenticatedPeerEvidence('other');
      f.trust.completePairing(other, proof);
      final c = f.hub.connect(auth);
      coreFailure(() => c.acknowledge(c.hello), ExternalFailure.disabled);
      check(f.trust.snapshot(f.principal).state ==
          PairingState.enabledForCurrentRuntime);
    },
    'forged clientInfo and untrusted evidence cannot authenticate': () {
      final f = Fixture();
      f.ready();
      for (final attempt in <Object>[
        {'clientInfo': 'Codex', 'profileId': f.principal.profileId},
        const AuthenticatedPeerEvidence('credential'),
        Object()
      ]) {
        coreFailure(() => f.hub.connect(attempt),
            ExternalFailure.authenticationRejected);
      }
      check(f.handler.calls == 0 && f.hub.connectionCount == 1);
    },
    'credential adapter failures fail closed': () {
      final f = Fixture();
      f.request();
      f.trust.approvePairing(f.principal);
      f.credentials.throwProof = true;
      coreFailure(() => f.trust.completePairing(f.principal, f.proof),
          ExternalFailure.authenticationRejected);
      f.credentials.throwAuthentication = true;
      coreFailure(() => f.hub.connect(f.authentication),
          ExternalFailure.authenticationRejected);
      check(f.handler.calls == 0);
    },
    'foreign authority cannot reuse same display profile id': () {
      final f = Fixture();
      f.ready();
      final foreign = ExternalTrustCore(
          credentials: f.credentials,
          clock: f.clock,
          mintProfileId: () => f.principal.profileId);
      final other = foreign.createProfile();
      coreFailure(() => f.trust.enable(other, const Duration(minutes: 1)),
          ExternalFailure.authenticationRejected);
      coreFailure(
          () => foreign.openSession(f.trust.authenticate(f.authentication)),
          ExternalFailure.authenticationRejected);
    },
    'legitimate reconnect reauthenticates and does not expand grant': () async {
      final f = Fixture();
      final first = f.ready();
      first.close();
      f.grant.read = false;
      final second = f.reconnect();
      check(f.credentials.authentications == 2);
      rejected(await f.call(second), f, ExternalFailure.accessDenied);
      check(f.trust.snapshot(f.principal).state ==
          PairingState.enabledForCurrentRuntime);
    },
    'same credential proxy is admitted without claiming process identity': () {
      final f = Fixture();
      f.ready();
      final proxy = Object();
      f.credentials.attempts[proxy] =
          const AuthenticatedPeerEvidence('credential');
      final c = f.hub.connect(proxy);
      c.acknowledge(c.hello);
      check(c.state == MemoryConnectionState.ready &&
          f.credentials.authentications == 2);
    },
    'business before ready has no handler or body': () async {
      final f = Fixture();
      f.pair();
      f.enable();
      final c = f.hub.connect(f.authentication);
      rejected(await f.call(c), f, ExternalFailure.notReady);
      check(c.state == MemoryConnectionState.awaitingAck);
    },
    'unknown version installation generation each close connection': () {
      for (final entry in [
        (
          const MemoryHello(2, 'synthetic-installation', 1),
          ExternalFailure.protocolVersion
        ),
        (
          const MemoryHello(1, 'wrong', 1),
          ExternalFailure.installationMismatch
        ),
        (
          const MemoryHello(1, 'synthetic-installation', 2),
          ExternalFailure.staleGeneration
        ),
      ]) {
        final f = Fixture();
        f.pair();
        f.enable();
        final c = f.hub.connect(f.authentication);
        coreFailure(() => c.acknowledge(entry.$1), entry.$2);
        check(c.state == MemoryConnectionState.closed &&
            f.hub.connectionCount == 0 &&
            f.handler.calls == 0);
      }
    },
    'double ack cannot set arbitrary ready': () async {
      final f = Fixture();
      final c = f.ready();
      coreFailure(() => c.acknowledge(c.hello), ExternalFailure.invalidState);
      rejected(await f.call(c), f, ExternalFailure.notReady);
      check(c.state == MemoryConnectionState.closed);
    },
    'restart between hello and ack rejects': () {
      final f = Fixture();
      f.pair();
      f.enable();
      final c = f.hub.connect(f.authentication);
      f.trust.restart();
      coreFailure(
          () => c.acknowledge(c.hello), ExternalFailure.staleGeneration);
      check(c.state == MemoryConnectionState.closed);
    },
    'expiry at exact deadline rejects new invocation': () async {
      final f = Fixture();
      final c = f.ready();
      f.clock.advance(const Duration(minutes: 5));
      rejected(await f.call(c), f, ExternalFailure.expired);
      final state = f.trust.snapshot(f.principal);
      check(state.state == PairingState.pairedDisabled &&
          state.disableReason == ExternalFailure.expired);
    },
    'disable then reenable never revives old session': () async {
      final f = Fixture();
      final c = f.ready();
      f.trust.disable(f.principal);
      rejected(await f.call(c), f, ExternalFailure.disabled);
      f.enable();
      rejected(await f.call(c), f, ExternalFailure.disabled);
      final result = await f.call(f.reconnect());
      check(result.output != null && f.handler.calls == 1);
    },
    'revoke prevents new credentials and old invocation': () async {
      final f = Fixture();
      final c = f.ready();
      f.trust.revoke(f.principal);
      rejected(await f.call(c), f, ExternalFailure.revoked);
      coreFailure(
          () => f.hub.connect(f.authentication), ExternalFailure.revoked);
      coreFailure(f.enable, ExternalFailure.revoked);
      check(f.trust.snapshot(f.principal).state == PairingState.revoked);
    },
    'restart disables new runtime and invalidates old context': () async {
      final f = Fixture();
      final c = f.ready();
      final context = f.context();
      f.trust.restart();
      rejected(await f.call(c), f, ExternalFailure.staleGeneration);
      final next = f.hub.connect(f.authentication);
      coreFailure(
          () => next.acknowledge(next.hello), ExternalFailure.staleGeneration);
      f.enable();
      rejected(await f.call(f.reconnect(), authority: context), f,
          ExternalFailure.staleContext);
      check(f.trust.generation == 2);
    },
    'restore requires fresh pairing and old proof cannot reactivate': () async {
      final f = Fixture();
      final c = f.ready();
      f.trust.restore();
      rejected(await f.call(c), f, ExternalFailure.staleGeneration);
      coreFailure(() => f.hub.connect(f.authentication),
          ExternalFailure.recoveryRequired);
      coreFailure(f.enable, ExternalFailure.recoveryRequired);
      coreFailure(f.request, ExternalFailure.pairingConflict);
      f.trust.requestPairing(f.principal,
          requestId: 'fresh', credentialIdentity: 'fresh');
      f.trust.approvePairing(f.principal);
      coreFailure(() => f.trust.completePairing(f.principal, f.proof),
          ExternalFailure.authenticationRejected);
      check(f.trust.snapshot(f.principal).state ==
          PairingState.approvedPendingProof);
    },
    'ready lacks read and stage unless Application allows each': () async {
      final f = Fixture();
      final c = f.ready();
      f.grant.read = false;
      f.grant.stage = false;
      rejected(await f.call(c), f, ExternalFailure.accessDenied);
      rejected(await f.call(c, staging: true), f, ExternalFailure.accessDenied);
      check(f.invocations.stageKeyCount == 0);
    },
    'scope revision generation and cross profile contexts cannot bypass':
        () async {
      final f = Fixture();
      final c = f.ready();
      rejected(await f.call(c, authority: f.context(scope: Object())), f,
          ExternalFailure.accessDenied);
      rejected(await f.call(c, authority: f.context(revision: 0)), f,
          ExternalFailure.accessDenied);
      rejected(await f.call(c, authority: f.context(generation: 0)), f,
          ExternalFailure.staleContext);
      rejected(
          await f.call(c, authority: f.context(owner: f.trust.createProfile())),
          f,
          ExternalFailure.staleContext);
    },
    'operation cannot substitute read permission or a new handler': () async {
      final f = Fixture();
      final c = f.ready();
      final forged =
          ExternalOperation(f.stage.id, CapabilityPermission.read, f.handler);
      rejected(
          await f.call(c, operation: forged), f, ExternalFailure.accessDenied);
      coreFailure(() => f.trust.approvePairing(f.principal),
          ExternalFailure.invalidState);
    },
    'commit and destructive cannot be registered externally': () {
      final f = Fixture();
      for (final permission in [
        CapabilityPermission.commit,
        CapabilityPermission.destructive
      ]) {
        var failed = false;
        try {
          ExternalInvocationCore(
              [ExternalOperation(f.read.id, permission, f.handler)]);
        } on ArgumentError {
          failed = true;
        }
        check(failed);
      }
    },
    'authorization throw fails before handler': () async {
      final f = Fixture();
      final c = f.ready();
      f.handler.throwAuthorization = true;
      rejected(await f.call(c), f, ExternalFailure.accessDenied);
    },
    'revoked grant before admission yields known zero': () async {
      final f = Fixture();
      final c = f.ready();
      f.grant.active = false;
      rejected(await f.call(c, staging: true), f, ExternalFailure.accessDenied);
      check(f.handler.publications == 0 && f.receipts.receipts.isEmpty);
    },
    'read revocation before release suppresses completed body': () async {
      final f = Fixture();
      final c = f.ready();
      f.handler.pending = Completer();
      final pending = f.call(c);
      f.trust.revoke(f.principal);
      f.handler.pending!.complete(CapabilityEvidence.completed(
          'private-fixture', CapabilityEffect.none));
      rejected(await pending, f, ExternalFailure.revoked,
          calls: 1,
          phase: ExternalInvocationPhase.release,
          status: CapabilityExecutionStatus.completed);
      check(f.invocations.totalActive == 0);
    },
    'revision changes invalidate egress and reuse': () async {
      final f = Fixture();
      final c = f.ready();
      final old = f.context();
      f.handler.pending = Completer();
      final pending = f.call(c, authority: old);
      f.grant.revision++;
      f.handler.pending!.complete(CapabilityEvidence.completed(
          'private-fixture', CapabilityEffect.none));
      rejected(await pending, f, ExternalFailure.accessDenied,
          calls: 1,
          phase: ExternalInvocationPhase.release,
          status: CapabilityExecutionStatus.completed);
      rejected(await f.call(c, authority: old), f, ExternalFailure.accessDenied,
          calls: 1);
    },
    'fake publication boundary rejects revision winner with zero effect':
        () async {
      final f = Fixture();
      final c = f.ready();
      f.handler.effect = CapabilityEffect.proposalStaged;
      f.handler.beforePublication = () => f.grant.revision++;
      rejected(await f.call(c, staging: true), f, ExternalFailure.accessDenied,
          calls: 1,
          phase: ExternalInvocationPhase.release,
          status: CapabilityExecutionStatus.failedWithoutEffect);
      check(f.handler.publications == 0 && f.receipts.receipts.isEmpty);
    },
    'fake publication winning survives later revoke locally': () async {
      final f = Fixture();
      final c = f.ready();
      f.handler.effect = CapabilityEffect.proposalStaged;
      final result = await f.call(c, staging: true);
      check(result.status == CapabilityExecutionStatus.completed &&
          f.handler.publications == 1);
      f.trust.revoke(f.principal);
      check(f.receipts.receipts.length == 1);
      rejected(await f.call(c, staging: true), f, ExternalFailure.revoked,
          calls: 1);
    },
    'cancel and deadline before entry have zero calls': () async {
      final f = Fixture();
      final c = f.ready();
      final cancelled = f.control()..cancel();
      rejected(await f.call(c, cancellation: cancelled), f,
          ExternalFailure.cancelled);
      rejected(
          await f.call(c, cancellation: f.control(deadline: Duration.zero)),
          f,
          ExternalFailure.deadlineExceeded);
    },
    'cancelled stage remains unknown and retains unfinished capacity':
        () async {
      final f = Fixture(perSession: 1);
      final c = f.ready();
      f.handler.pending = Completer();
      final control = f.control();
      final pending = f.call(c, staging: true, cancellation: control);
      control.cancel();
      rejected(await pending, f, ExternalFailure.cancelled,
          calls: 1,
          phase: ExternalInvocationPhase.execution,
          status: CapabilityExecutionStatus.outcomeUnknown,
          effect: null);
      check(f.invocations.totalActive == 1 && f.invocations.stageKeyCount == 1);
      rejected(
          await f.call(c, requestId: 'next'), f, ExternalFailure.resourceLimit,
          calls: 1);
      f.handler.pending!.complete(CapabilityEvidence.completed(
          'late-stage', CapabilityEffect.proposalStaged));
      await Future<void>.value();
      await Future<void>.value();
      check(f.invocations.totalActive == 0 && f.handler.calls == 1);
    },
    'deadline during execution preserves unknown rather than rollback':
        () async {
      final f = Fixture();
      final c = f.ready();
      f.handler.pending = Completer();
      final control = f.control(deadline: const Duration(seconds: 1));
      final pending = f.call(c, staging: true, cancellation: control);
      f.clock.advance(const Duration(seconds: 1), control);
      rejected(await pending, f, ExternalFailure.deadlineExceeded,
          calls: 1,
          phase: ExternalInvocationPhase.execution,
          status: CapabilityExecutionStatus.outcomeUnknown,
          effect: null);
      f.handler.pending!.complete(CapabilityEvidence.completed(
          'late', CapabilityEffect.proposalStaged));
    },
    'known effect is preserved through interruption': () async {
      final f = Fixture();
      final c = f.ready();
      f.handler.pending = Completer();
      f.handler.confirmBeforeWaiting = true;
      f.handler.effect = CapabilityEffect.proposalStaged;
      final control = f.control();
      final pending = f.call(c, staging: true, cancellation: control);
      control.cancel();
      rejected(await pending, f, ExternalFailure.cancelled,
          calls: 1,
          phase: ExternalInvocationPhase.execution,
          status: CapabilityExecutionStatus.outcomeUnknown,
          effect: CapabilityEffect.proposalStaged);
      f.handler.pending!.complete(CapabilityEvidence.completed(
          'late', CapabilityEffect.proposalStaged));
    },
    'lost response reconciles original key without automatic resubmission':
        () async {
      final f = Fixture();
      final c = f.ready();
      f.handler.effect = CapabilityEffect.proposalStaged;
      final pending = f.call(c, staging: true);
      c.close();
      final result = await pending;
      rejected(result, f, ExternalFailure.responseLost,
          calls: 1,
          phase: ExternalInvocationPhase.release,
          status: CapabilityExecutionStatus.outcomeUnknown,
          effect: CapabilityEffect.proposalStaged);
      check(result.submissionKey == 'original-key' &&
          f.handler.publications == 1);
      final next = f.reconnect();
      rejected(await f.call(next, staging: true), f,
          ExternalFailure.reconciliationRequired,
          calls: 1);
      final receipt = await f.query();
      check(receipt.status == CapabilityExecutionStatus.completed &&
          receipt.output != null);
      check(receipt.submissionKey == 'original-key' &&
          f.handler.calls == 1 &&
          f.handler.queries == 1);
    },
    'unknown receipt cannot imply no effect': () async {
      final f = Fixture();
      final c = f.ready();
      f.handler.throwInvocation = true;
      rejected(await f.call(c, staging: true), f, ExternalFailure.handlerFailed,
          calls: 1,
          phase: ExternalInvocationPhase.execution,
          status: CapabilityExecutionStatus.outcomeUnknown,
          effect: null);
      final result = await f.query();
      check(result.status == CapabilityExecutionStatus.outcomeUnknown &&
          result.effect == null);
      check(f.invocations.totalActive == 0 && f.handler.calls == 1);
    },
    'receipt read checks current scope revision and read permission': () async {
      final f = Fixture();
      final c = f.ready();
      await f.call(c, staging: true);
      f.grant.read = false;
      rejected(await f.query(), f, ExternalFailure.accessDenied,
          calls: 1, phase: ExternalInvocationPhase.reconciliation);
      f.grant.read = true;
      rejected(await f.query(authority: f.context(scope: Object())), f,
          ExternalFailure.accessDenied,
          calls: 1, phase: ExternalInvocationPhase.reconciliation);
      check(f.handler.queries == 0);
    },
    'receipt query shares finite resource quota and cancellation semantics':
        () async {
      final f = Fixture(perSession: 1, global: 1);
      final c = f.ready();
      await f.call(c, staging: true);
      f.handler.pendingQuery = Completer();
      final control = f.control();
      final pending = f.query(cancellation: control);
      control.cancel();
      rejected(await pending, f, ExternalFailure.cancelled,
          calls: 1,
          phase: ExternalInvocationPhase.reconciliation,
          status: CapabilityExecutionStatus.outcomeUnknown,
          effect: null);
      rejected(await f.call(c), f, ExternalFailure.resourceLimit, calls: 1);
      f.handler.pendingQuery!.complete(CapabilityEvidence.completed(
          'receipt', CapabilityEffect.proposalStaged));
    },
    'connections use independent request correlations and cancellation':
        () async {
      final f = Fixture();
      final first = f.ready();
      final second = f.reconnect();
      f.handler.pending = Completer();
      final one = f.control();
      final two = f.control();
      final a = f.call(first, cancellation: one);
      final b = f.call(second, cancellation: two);
      one.cancel();
      rejected(await a, f, ExternalFailure.cancelled,
          calls: 2,
          phase: ExternalInvocationPhase.execution,
          status: CapabilityExecutionStatus.outcomeUnknown,
          effect: null);
      check(two.failure == null && f.invocations.totalActive == 2);
      f.handler.pending!.complete(
          CapabilityEvidence.completed('read', CapabilityEffect.none));
      check((await b).output != null && f.invocations.totalActive == 0);
    },
    'shared control cannot leak cancellation into second connection': () async {
      final f = Fixture();
      final first = f.ready();
      final second = f.reconnect();
      f.handler.pending = Completer();
      final shared = f.control();
      final a = f.call(first, cancellation: shared);
      rejected(await f.call(second, cancellation: shared), f,
          ExternalFailure.resourceLimit,
          calls: 1);
      shared.cancel();
      await a;
      f.handler.pending!.complete(
          CapabilityEvidence.completed('read', CapabilityEffect.none));
    },
    'duplicate request id and global limits do not invoke handler': () async {
      final f = Fixture(global: 2);
      final first = f.ready();
      final second = f.reconnect();
      f.handler.pending = Completer();
      final a = f.call(first);
      rejected(await f.call(first), f, ExternalFailure.resourceLimit, calls: 1);
      final b = f.call(second);
      rejected(await f.call(first, requestId: 'other'), f,
          ExternalFailure.resourceLimit,
          calls: 2);
      f.handler.pending!.complete(
          CapabilityEvidence.completed('read', CapabilityEffect.none));
      await a;
      await b;
      check(f.invocations.totalActive == 0);
    },
    'stage journal is bounded and duplicate key does not execute twice':
        () async {
      final f = Fixture(stageKeys: 1);
      final c = f.ready();
      await f.call(c, staging: true);
      rejected(await f.call(c, staging: true), f,
          ExternalFailure.reconciliationRequired,
          calls: 1);
      rejected(await f.call(c, staging: true, key: 'new-key'), f,
          ExternalFailure.resourceLimit,
          calls: 1);
      check(f.invocations.stageKeyCount == 1 && f.handler.publications == 1);
    },
    'connection and profile quotas reject without growth': () {
      final f = Fixture(maxConnections: 1);
      final c = f.ready();
      coreFailure(
          () => f.hub.connect(f.authentication), ExternalFailure.resourceLimit);
      c.close();
      check(f.reconnect().state == MemoryConnectionState.ready);
      final trust = ExternalTrustCore(
          credentials: f.credentials,
          clock: f.clock,
          mintProfileId: () => 'only',
          maxProfiles: 1);
      trust.createProfile();
      coreFailure(trust.createProfile, ExternalFailure.resourceLimit);
      check(f.hub.connectionCount == 1 && f.handler.calls == 0);
    },
    'invalid request identifiers and empty stage key fail before handler':
        () async {
      final f = Fixture();
      final c = f.ready();
      rejected(
          await f.call(c, requestId: ''), f, ExternalFailure.invalidRequest);
      rejected(await f.call(c, staging: true, key: ''), f,
          ExternalFailure.invalidRequest);
      check(f.invocations.totalActive == 0 && f.invocations.stageKeyCount == 0);
    },
    'frame every possible split and bytewise feeding roundtrip': () {
      final frame =
          MemoryFrameDecoder().encode(MemoryFrameKind.control, helloFields);
      for (var split = 0; split <= frame.length; split++) {
        final decoder = MemoryFrameDecoder();
        final messages = [
          ...decoder.feed(Uint8List.sublistView(frame, 0, split)),
          ...decoder.feed(Uint8List.sublistView(frame, split))
        ];
        check(messages.length == 1 &&
            messages.single.fields['type'] == 'hello_ack');
        check(decoder.allocatedBodyBytes == 0 && decoder.bufferedBytes == 0);
        decoder.finish();
      }
      final decoder = MemoryFrameDecoder();
      var count = 0;
      for (final byte in frame) {
        count += decoder.feed(Uint8List.fromList([byte])).length;
      }
      check(count == 1);
      decoder.finish();
    },
    'coalesced frames and independent partial buffers': () {
      final frame =
          MemoryFrameDecoder().encode(MemoryFrameKind.control, helloFields);
      final first = MemoryFrameDecoder();
      final second = MemoryFrameDecoder();
      first.feed(Uint8List.sublistView(frame, 0, 8));
      check(first.bufferedBytes == 8 && second.bufferedBytes == 0);
      check(second.feed(Uint8List.fromList([...frame, ...frame])).length == 2);
      check(first.feed(Uint8List.sublistView(frame, 8)).length == 1);
    },
    'negative zero and malicious length allocate no body': () {
      for (final length in [0, 0x80000000, 0xffffffff]) {
        frameFailure(MemoryFrameDecoder(), lengthHeader(length),
            MemoryFrameFailure.length);
      }
      frameFailure(MemoryFrameDecoder(), lengthHeader(0x7fffffff),
          MemoryFrameFailure.resourceLimit);
    },
    'control and business limits differ and valid exact limit succeeds': () {
      final control =
          MemoryFrameDecoder().encode(MemoryFrameKind.control, helloFields);
      final business =
          MemoryFrameDecoder().encode(MemoryFrameKind.business, requestFields);
      final decoder = MemoryFrameDecoder(
          controlLimit: control.length - 5, businessLimit: business.length - 5);
      check(decoder.feed(control).length == 1 &&
          decoder.feed(business).length == 1);
      frameFailure(MemoryFrameDecoder(controlLimit: 8, businessLimit: 128),
          control, MemoryFrameFailure.resourceLimit);
      check(MemoryFrameDecoder(controlLimit: 8, businessLimit: 128)
              .feed(business)
              .length ==
          1);
    },
    'truncated header and truncated body reject at finish': () {
      final frame =
          MemoryFrameDecoder().encode(MemoryFrameKind.control, helloFields);
      for (final size in [1, 4, 5, frame.length - 1]) {
        final decoder = MemoryFrameDecoder();
        decoder.feed(Uint8List.sublistView(frame, 0, size));
        var failed = false;
        try {
          decoder.finish();
        } on MemoryFrameException catch (error) {
          check(error.failure == MemoryFrameFailure.truncated);
          failed = true;
        }
        check(failed && decoder.isClosed && decoder.allocatedBodyBytes == 0);
      }
    },
    'bad UTF8 JSON and unknown message kind reject safely': () {
      frameFailure(MemoryFrameDecoder(), byteFrame([0xc3, 0x28]),
          MemoryFrameFailure.utf8);
      frameFailure(
          MemoryFrameDecoder(), rawFrame('{'), MemoryFrameFailure.json);
      frameFailure(
          MemoryFrameDecoder(), rawFrame('[]'), MemoryFrameFailure.message);
      frameFailure(MemoryFrameDecoder(), rawFrame('{"type":"READY"}'),
          MemoryFrameFailure.message);
      frameFailure(MemoryFrameDecoder(), rawFrame('{}', kind: 2),
          MemoryFrameFailure.message);
    },
    'required fields types present null and extra authority fields reject': () {
      for (final fields in <Map<String, Object?>>[
        {...helloFields}..remove('generation'),
        {...helloFields, 'generation': null},
        {...helloFields, 'version': '1'},
        {...helloFields, 'principal': 'trusted'},
        {...helloFields, 'installation': ''},
        {...helloFields, 'generation': 0},
      ]) {
        frameFailure(MemoryFrameDecoder(), rawFrame(jsonEncode(fields)),
            MemoryFrameFailure.message);
      }
      frameFailure(
          MemoryFrameDecoder(),
          rawFrame(jsonEncode(helloFields), kind: 1),
          MemoryFrameFailure.message);
      frameFailure(
          MemoryFrameDecoder(),
          rawFrame(jsonEncode({...requestFields, 'body': null}), kind: 1),
          MemoryFrameFailure.message);
    },
    'depth bound precedes JSON parser and quoted braces are literal': () {
      frameFailure(MemoryFrameDecoder(maxDepth: 3), rawFrame('[[[[0]]]]'),
          MemoryFrameFailure.depth);
      final fields = {
        ...requestFields,
        'body': {'text': '{ [ \\" literal ] }'}
      };
      final encoder = MemoryFrameDecoder(maxDepth: 2);
      final frame = encoder.encode(MemoryFrameKind.business, fields);
      check(MemoryFrameDecoder(maxDepth: 2).feed(frame).length == 1);
    },
    'decoded nested maps and arrays are immutable': () {
      final frame = MemoryFrameDecoder().encode(MemoryFrameKind.business, {
        ...requestFields,
        'body': {
          'array': [1, 2]
        }
      });
      final message = MemoryFrameDecoder().feed(frame).single;
      var rejected = 0;
      try {
        message.fields['type'] = 'changed';
      } on UnsupportedError {
        rejected++;
      }
      final body = message.fields['body'] as Map<String, Object?>;
      try {
        body['extra'] = true;
      } on UnsupportedError {
        rejected++;
      }
      try {
        (body['array'] as List<Object?>).add(3);
      } on UnsupportedError {
        rejected++;
      }
      check(rejected == 3);
    },
    'coalesced backlog limit rejects and decoder remains closed': () {
      final frame =
          MemoryFrameDecoder().encode(MemoryFrameKind.control, helloFields);
      final decoder = MemoryFrameDecoder(maxFramesPerFeed: 1);
      frameFailure(decoder, Uint8List.fromList([...frame, ...frame]),
          MemoryFrameFailure.resourceLimit);
      frameFailure(decoder, frame, MemoryFrameFailure.closed);
    },
    'partial maximum body is bounded and oversized header rejects immediately':
        () {
      final decoder = MemoryFrameDecoder(controlLimit: 32);
      decoder.feed(lengthHeader(32));
      check(decoder.allocatedBodyBytes == 32 && decoder.bufferedBytes == 5);
      frameFailure(MemoryFrameDecoder(controlLimit: 32), lengthHeader(33),
          MemoryFrameFailure.resourceLimit);
    },
  };
  var passed = 0;
  for (final entry in cases.entries) {
    try {
      await entry.value();
      passed++;
      Zone.current.print('PASS ${entry.key}');
    } catch (_) {
      Zone.current.print('FAIL ${entry.key}');
      rethrow;
    }
  }
  Zone.current.print('TCP_CORE_MEMORY_TESTS_PASS: $passed/${cases.length}');
}
