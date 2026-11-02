import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/link/link_adapter_process.dart';
import 'package:shiroha_quiz/data/external/link/link_initialization.dart';
import 'package:shiroha_quiz/data/external/link/link_installation.dart';
import 'package:shiroha_quiz/data/external/link/link_runtime.dart';
import 'package:shiroha_quiz/data/external/link/link_state_store.dart';
import 'package:shiroha_quiz/data/external/link/link_values.dart';
import 'package:shiroha_quiz/data/external/link/link_verification_log.dart';
import 'package:shiroha_quiz/data/external/link/link_call_diagnostics.dart';
import 'link_call_capture_cases.dart';
import 'package:shiroha_quiz/data/external/windows_local_relay.dart';
import '../../mcp/fixtures/codex_app_server_support.dart'
    show flutterDartExecutable;

Future<LinkAdapterProcess> _startBusinessChild(LinkInstallation installation,
        {required String runId,
        required String resourceId,
        required File exitSignal,
        required Future<void> Function(LinkOwnerReference) acquired,
        required LinkVerificationObserver observer,
        void Function(Process)? started,
        Process Function(Process)? wrap,
        bool settledBeforeExit = false}) =>
    LinkAdapterProcess.start(installation,
        runId: runId,
        resourceId: resourceId,
        proof: false,
        acquired: acquired,
        verificationObserver: observer, startProcess: (_, __,
            {required runInShell, required workingDirectory}) async {
      final dart = flutterDartExecutable();
      // New SDKs split the CLI launcher from the VM. Supervise the very
      // process that reports its PID, as with the distributed adapter.
      final vm = File(p.join(
          p.dirname(dart), Platform.isWindows ? 'dartvm.exe' : 'dartvm'));
      final process = await Process.start(vm.existsSync() ? vm.path : dart, [
        '--disable-dart-dev',
        '--packages=${p.absolute('.dart_tool/package_config.json')}',
        p.absolute('test/data/external/fixtures/link_business_child.dart'),
        runId,
        resourceId,
        exitSignal.path,
        settledBeforeExit ? 'settled' : 'missing',
      ]);
      started?.call(process);
      addTearDown(() async {
        await exitSignal.create();
        await process.exitCode.timeout(const Duration(seconds: 8));
      });
      return wrap?.call(process) ?? process;
    });

// Keep the real process and pipes. Hold one input barrier until the test
// explicitly lets it finish, so exit during a flush/close is deterministic.
final class _HeldInput implements StreamConsumer<List<int>> {
  _HeldInput(this.pipe, {required this.holdFlush});
  final IOSink pipe;
  final bool holdFlush;
  final entered = Completer<void>(), release = Completer<void>();
  Future<void> _hold() {
    entered.complete();
    return release.future;
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      pipe.add(chunk);
    }
    await pipe.flush();
    if (holdFlush) await _hold();
  }

  @override
  Future<void> close() async {
    if (!holdFlush) await _hold();
    await pipe.close();
  }
}

final class _ProcessWithInput implements Process {
  _ProcessWithInput(this.original, this.stdin);
  final Process original;
  @override
  final IOSink stdin;
  @override
  int get pid => original.pid;
  @override
  Future<int> get exitCode => original.exitCode;
  @override
  Stream<List<int>> get stdout => original.stdout;
  @override
  Stream<List<int>> get stderr => original.stderr;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      original.kill(signal);
}

final class _Relay implements LocalRelayServerConnection {
  _Relay() {
    input = StreamIterator(incoming.stream);
    output = StreamIterator(outgoing.stream);
  }
  final incoming = StreamController<Map<String, Object?>>();
  final outgoing = StreamController<Map<String, Object?>>();
  late final StreamIterator<Map<String, Object?>> input, output;
  final admitted = Completer<void>(), ended = Completer<void>();
  final sending = Completer<void>(), releaseSend = Completer<void>();
  bool holdResult = false, accepted = false, closed = false;
  bool holdAfterResult = false;
  bool rearmOnDisconnect = false, notifyDisconnect = false, delayEof = false;
  bool disconnected = false, eofSent = false;
  int resultSends = 0;
  final disconnectRequested = Completer<void>();
  void Function(Map<String, Object?>)? onReceive;
  @override
  bool get isCurrent => accepted && !closed && !disconnected;
  @override
  String get linkPeerIdentity => 'synthetic-peer';
  @override
  Future<void> accept() async {
    if (accepted) {
      await ended.future;
      throw const LocalRelayException();
    }
    await admitted.future;
    accepted = true;
  }

  @override
  Future<void> send(Map<String, Object?> message, Duration deadline) async {
    if (message['kind'] == 'result') resultSends++;
    if (holdResult && message['kind'] == 'result') {
      sending.complete();
      await releaseSend.future;
    }
    outgoing.add(message);
    if (holdAfterResult && message['kind'] == 'result') {
      sending.complete();
      await releaseSend.future;
    }
  }

  @override
  Future<Map<String, Object?>> receive(Duration deadline) async {
    if (!await input.moveNext()) throw const LocalRelayException();
    onReceive?.call(input.current);
    return input.current;
  }

  Future<Map<String, Object?>> next() async {
    if (!await output.moveNext()) throw StateError('synthetic channel ended');
    return output.current;
  }

  @override
  Future<void> disconnect() async {
    if (rearmOnDisconnect) accepted = false;
    if (notifyDisconnect && !disconnected) {
      disconnected = true;
      disconnectRequested.complete();
      if (!delayEof) finishDisconnect();
    }
  }

  void finishDisconnect() {
    if (!eofSent && !closed) {
      eofSent = true;
      incoming.addError(const LocalRelayException());
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!ended.isCompleted) ended.complete();
    unawaited(incoming.close());
    unawaited(outgoing.close());
  }

  Future<void> dispose() async {
    await close();
    await input.cancel();
    await output.cancel();
  }
}

final class _InputConsumer implements StreamConsumer<List<int>> {
  bool fail = false;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final _ in stream) {}
  }

  @override
  Future<void> close() async {
    if (fail) throw const LinkException('synthetic_input_failed');
  }
}

final class _OriginalProcess implements Process {
  _OriginalProcess() {
    stdin = IOSink(input);
  }
  final input = _InputConsumer();
  final output = StreamController<List<int>>();
  final events = StreamController<List<int>>();
  final exited = Completer<int>();
  @override
  late final IOSink stdin;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => events.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  int get pid => 42;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;

  void ownerAndSettlement({String resource = 'resource', int? ownerPid}) {
    for (final event in [
      {
        'type': 'owner',
        'runId': 'run',
        'resourceId': 'resource',
        'processId': ownerPid ?? pid,
        'processStarted': '123456',
        'slotRef': 'phone',
      },
      {
        'type': 'settled',
        'runId': 'run',
        'resourceId': resource,
        'mode': 'enable-proof',
        'targetClose': true,
        'tlsShutdown': true,
        'keyRetired': true,
      }
    ]) {
      events.add(utf8.encode('SHIROHA_LINK_EVENT ${jsonEncode(event)}\n'));
    }
  }
}

final class _Backend implements LinkBackend {
  _Backend(this.owner, this.target, this.settle);
  @override
  final LinkOwnerReference owner;
  @override
  final LinkVerifiedTarget target;
  final Future<void> Function() settle;
  final lost = Completer<void>(), entered = Completer<void>();
  final response = Completer<Map<String, Object?>>();
  bool cancelled = false;
  bool clientFailed = false;
  int closes = 0;
  @override
  Future<void> get disconnected => lost.future;
  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled, LinkCallTrace? diagnostic}) async {
    final sub = cancelled.listen((_) => this.cancelled = true);
    entered.complete();
    try {
      if (clientFailed) {
        diagnostic?.stage(LinkCallStage.backendCall, LinkCallOutcome.failed,
            LinkCallCause.clientFailure);
        throw StateError('synthetic client exception');
      }
      return await response.future;
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<void> close() {
    closes++;
    return settle();
  }
}

void main() {
  linkCallCaptureCases();
  group('original supervision observations', () {
    const config = LinkInstallation(
        stateDirectory: 'not-used',
        slotDirectory: 'not-used',
        slotRef: 'phone',
        connectorInstanceId: 'connector',
        operationId: 'operation',
        adapterExecutable: 'synthetic');
    Future<LinkAdapterProcess> start(
            _OriginalProcess original, LinkVerificationObserver observer) =>
        LinkAdapterProcess.start(config,
            runId: 'run',
            resourceId: 'resource',
            proof: true,
            acquired: (_) async {},
            verificationObserver: observer, startProcess:
                (executable, arguments,
                    {required runInShell, required workingDirectory}) async {
          expect(executable, 'synthetic');
          expect(arguments,
              ['--link-proof', 'run', 'resource', '--current-user-cng-import']);
          expect(runInShell, isFalse);
          return original;
        });

    test('exit alone cannot emit join; both original streams must finish',
        () async {
      final original = _OriginalProcess();
      final observations = <LinkVerificationObservation>[];
      final started = start(original, observations.add);
      original.ownerAndSettlement();
      original.exited.complete(0);
      await Future<void>.delayed(Duration.zero);
      expect(observations, isEmpty);
      await original.output.close();
      await Future<void>.delayed(Duration.zero);
      expect(observations, isEmpty);
      await original.events.close();
      final adapter = await started;
      expect(observations, hasLength(1));
      final value = jsonDecode(observations.single.encode(1)) as Map;
      expect((value['owner'] as Map)['processId'], 42);
      expect(value['stdinClosed'], isTrue);
      expect(value['stdoutDrained'], isTrue);
      expect(value['stderrDrained'], isTrue);
      await Future.wait([adapter.close(), adapter.close()]);
      expect(observations, hasLength(1));
    });

    for (final failure in [
      'stdin',
      'stdout',
      'stderr',
      'exit',
      'resource',
      'pid'
    ]) {
      test('$failure failure cannot emit original join success', () async {
        final original = _OriginalProcess();
        final observations = <LinkVerificationObservation>[];
        original.input.fail = failure == 'stdin';
        final started = start(original, observations.add);
        final refused = expectLater(started, throwsA(isA<LinkException>()));
        original.ownerAndSettlement(
            resource: failure == 'resource' ? 'other' : 'resource',
            ownerPid: failure == 'pid' ? 43 : null);
        if (failure == 'stdout') {
          original.output.addError(const LinkException('synthetic_stream'));
        }
        if (failure == 'stderr') {
          original.events.addError(const LinkException('synthetic_stream'));
        }
        original.exited.complete(failure == 'exit' ? 1 : 0);
        await Future.wait([original.output.close(), original.events.close()]);
        await refused;
        expect(observations, isEmpty);
      });
    }

    test('observer exception cannot change successful original settlement',
        () async {
      final original = _OriginalProcess();
      final started =
          start(original, (_) => throw StateError('synthetic_observer'));
      original.ownerAndSettlement();
      original.exited.complete(0);
      await Future.wait([original.output.close(), original.events.close()]);
      await (await started).close();
    });
  });

  group('bounded verification log', () {
    late Directory directory;
    const owner = LinkOwnerReference(
        runId: 'run',
        resourceId: 'resource',
        processId: 42,
        processStarted: '123456',
        slotRef: 'phone');
    setUp(() async => directory =
        await Directory.systemTemp.createTemp('link-verification-'));
    tearDown(() async => directory.delete(recursive: true));

    test('buffers until finish and writes ordered bounded terminal evidence',
        () async {
      final log = LinkVerificationLog(directory.path, 'run');
      log.record(LinkVerificationObservation.adapterJoined(owner,
          proof: false, processExitCode: 0));
      expect(await directory.list().toList(), isEmpty);
      expect(await log.finish(), isTrue);
      final file = File(p.join(directory.path, 'verification-run.jsonl'));
      final records = (await file.readAsLines()).map(jsonDecode).toList();
      expect(records, hasLength(2));
      expect(records.last['event'], 'verification-log-complete');
      expect(records.last['observationCount'], 1);
      expect(await file.length(), lessThanOrEqualTo(32768));
      final before = await file.readAsBytes();
      expect(await log.finish(), isFalse);
      expect(await file.readAsBytes(), before);
    });

    test('existing output is never replaced', () async {
      final file = File(p.join(directory.path, 'verification-run.jsonl'));
      await file.writeAsString('retained');
      final log = LinkVerificationLog(directory.path, 'run');
      expect(await log.finish(), isFalse);
      expect(await file.readAsString(), 'retained');
    });

    for (final failure in ['run', 'limit', 'write']) {
      test(
          '$failure latches diagnostics failure without throwing or success footer',
          () async {
        final log = LinkVerificationLog(
            failure == 'write'
                ? p.join(directory.path, 'absent')
                : directory.path,
            failure == 'run' ? 'different' : 'run');
        for (var n = 0; n < (failure == 'limit' ? 32 : 1); n++) {
          log.record(LinkVerificationObservation.adapterJoined(owner,
              proof: false, processExitCode: 0));
        }
        expect(await log.finish(), isFalse);
        expect(await directory.list().toList(), isEmpty);
      });
    }
  });

  late Directory root, slot;
  late LinkStateStore store;
  late LinkRuntime runtime;
  late _Backend backend;
  final target = LinkVerifiedTarget('a' * 64, 'installation', 'profile');
  var starts = 0, wrongReceipt = false, failClose = false;
  var observerThrows = false;
  late LinkCallDiagnostics calls;
  final callRows = <Map>[];
  var callObserverThrows = false;
  void Function(int, LinkCallStage, LinkCallOutcome, LinkCallCause)? stageHook;
  void Function()? callFinished;
  var holdProof = false, failAcquisition = false;
  Completer<void>? acquisitionEntered, acquisitionReleased;
  Completer<void>? closeEntered, closeReleased;
  final observations = <LinkVerificationObservation>[];
  Future<void> receipt(LinkOwnerReference owner, String mode) =>
      File(p.join(slot.path, 'link-settlement.json')).writeAsString(jsonEncode({
        'formatVersion': 2,
        'operationId': 'operation',
        'receiptRef': owner.resourceId,
        'runId': owner.runId,
        'resourceId': owner.resourceId,
        'processId': owner.processId,
        'processStarted': owner.processStarted,
        'slotRef': 'phone',
        'owner': 'connector',
        'mode': mode,
        'target': target.toJson(),
        'targetClose': true,
        'tlsShutdown': true,
        'keyRetired': true,
      }));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('link-runtime-');
    slot = await Directory(p.join(root.path, 'slot')).create();
    final state = await Directory(p.join(root.path, 'state')).create();
    final config = LinkInstallation(
        stateDirectory: state.path,
        slotDirectory: slot.path,
        slotRef: 'phone',
        connectorInstanceId: 'connector',
        operationId: 'operation',
        adapterExecutable: p.join(root.path, 'adapter.exe'));
    final init = LinkInitialization(config, processCurrent: (_, __) => false);
    store = await init.open(initialize: true);
    await File(p.join(slot.path, 'device.dpapi'))
        .writeAsString('synthetic-only');
    const original = LinkOwnerReference(
        runId: 'pair-run',
        resourceId: 'pair-resource',
        processId: 100,
        processStarted: '123456',
        slotRef: 'phone');
    await receipt(original, 'pairing');
    await File(p.join(slot.path, 'initialization-joined.json'))
        .writeAsString(jsonEncode({
      'formatVersion': 1,
      'operationId': 'operation',
      'slotRef': 'phone',
      'ownerInstanceId': 'connector',
      'runId': original.runId,
      'resourceId': original.resourceId,
      'processId': original.processId,
      'processStarted': original.processStarted,
      'adapterReceiptRef': original.resourceId,
      'target': target.toJson(),
      'processExitCode': 0,
      'stdinClosed': true,
      'stdoutDrained': true,
      'stderrDrained': true,
    }));
    await File(p.join(slot.path, 'adapter-origin.json'))
        .writeAsString(jsonEncode({
      'formatVersion': 1,
      'slotRef': 'phone',
      'origin': 'independent_adapter_pairing',
      'operationId': 'operation',
      'target': target.toJson(),
      'credentialSlotRef': 'device.dpapi',
      'resourceGeneration': 'pair-resource',
      'settlementRef': 'pair-resource',
    }));
    await init.complete(store, target);
    starts = 0;
    wrongReceipt = false;
    failClose = false;
    holdProof = false;
    failAcquisition = false;
    acquisitionEntered = acquisitionReleased = null;
    closeEntered = closeReleased = null;
    observations.clear();
    observerThrows = false;
    callObserverThrows = false;
    stageHook = null;
    callFinished = null;
    callRows.clear();
    calls = LinkCallDiagnostics((trace) {
      if (callObserverThrows) throw StateError('SENTINEL_DIAGNOSTIC');
      callRows.add(jsonDecode(trace.encode(callRows.length + 1)) as Map);
      callFinished?.call();
    },
        frontend: false,
        stageObserved: (ordinal, stage, outcome, cause) =>
            stageHook?.call(ordinal, stage, outcome, cause));
    runtime = LinkRuntime(
        installation: config,
        store: store,
        callDiagnostics: calls,
        verificationObserver: (observation) {
          if (observerThrows) throw StateError('synthetic_observer');
          observations.add(observation);
        },
        backendFactory: (
            {required proof,
            required runId,
            required resourceId,
            required acquired}) async {
          starts++;
          final owner = LinkOwnerReference(
              runId: runId,
              resourceId: resourceId,
              processId: 100 + starts,
              processStarted: '123456$starts',
              slotRef: 'phone');
          await acquired(owner);
          backend = _Backend(owner, target, () async {
            if (closeEntered?.isCompleted == false) closeEntered!.complete();
            await closeReleased?.future;
            if (failClose) throw const LinkException('owner_unsettled');
            if (!wrongReceipt) await receipt(owner, 'business');
          });
          if (proof == holdProof && acquisitionEntered != null) {
            acquisitionEntered!.complete();
            await acquisitionReleased!.future;
            if (failAcquisition) {
              throw const LinkException('owner_unsettled');
            }
          }
          if (proof) await receipt(owner, 'enable-proof');
          return backend;
        });
  });
  tearDown(() async {
    try {
      await runtime.close();
    } catch (_) {/* Preserve failure verdict. */}
    await store.close();
    await root.delete(recursive: true);
  });
  Future<Map<String, dynamic>> ownership() async => jsonDecode(
          await File(p.join(slot.path, 'slot-ownership.json')).readAsString())
      as Map<String, dynamic>;

  for (final exitsFirst in [false, true]) {
    test(
        'business child ${exitsFirst ? 'exits first' : 'receives EOF'} after Profile 3 READ',
        () async {
      final exitSignal = File(p.join(root.path, 'exit-after-read'));
      late Future<void> inputDone;
      final child = await _startBusinessChild(runtime.installation,
          runId: 'run',
          resourceId: 'resource',
          exitSignal: exitSignal,
          acquired: (_) async {},
          observer: observations.add,
          settledBeforeExit: true,
          started: (process) => inputDone = process.stdin.done
              .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      final reply = await child.call('open_context', {'scope': 'authorized'},
          cancelled: const Stream.empty());
      expect(reply['data'], {'contextRef': 'synthetic-read'});
      if (exitsFirst) {
        await exitSignal.create();
        await child.disconnected.timeout(const Duration(seconds: 5));
        await inputDone.timeout(const Duration(seconds: 5));
      }
      final closing = child.close();
      expect(identical(child.close(), closing), isTrue);
      final result = closing.timeout(const Duration(seconds: 4));
      if (exitsFirst) {
        // Even a matching event and exit 0 do not establish a flushed input.
        await expectLater(
            result,
            throwsA(isA<LinkException>()
                .having((e) => e.code, 'code', 'owner_unsettled')));
        expect(observations, isEmpty);
      } else {
        await result;
        expect(observations, hasLength(1));
      }
    });
  }

  for (final holdFlush in [true, false]) {
    test('business child exits during ${holdFlush ? 'flush' : 'close'}',
        () async {
      late _HeldInput held;
      final exitSignal = File(p.join(root.path, 'exit-during-close'));
      final child = await _startBusinessChild(runtime.installation,
          runId: 'run',
          resourceId: 'resource',
          exitSignal: exitSignal,
          acquired: (_) async {},
          observer: observations.add,
          settledBeforeExit: true, wrap: (process) {
        held = _HeldInput(process.stdin, holdFlush: holdFlush);
        return _ProcessWithInput(process, IOSink(held));
      });
      try {
        final reply = await child.call('open_context', {'scope': 'authorized'},
            cancelled: const Stream.empty());
        expect(reply['data'], {'contextRef': 'synthetic-read'});
        final closing = child.close();
        final rejected = expectLater(
            closing.timeout(const Duration(seconds: 5)),
            throwsA(isA<LinkException>()
                .having((e) => e.code, 'code', 'owner_unsettled')));
        await held.entered.future.timeout(const Duration(seconds: 5));
        expect(identical(child.close(), closing), isTrue);
        await exitSignal.create();
        await rejected;
        expect(observations, isEmpty);
      } finally {
        held.release.complete();
      }
    });
  }

  test('business child input error stays failed after a settled exit',
      () async {
    late IOSink input;
    final exitSignal = File(p.join(root.path, 'exit-after-input-error'));
    final child = await _startBusinessChild(runtime.installation,
        runId: 'run',
        resourceId: 'resource',
        exitSignal: exitSignal,
        acquired: (_) async {},
        observer: observations.add,
        settledBeforeExit: true, wrap: (process) {
      input = IOSink(_HeldInput(process.stdin, holdFlush: true));
      return _ProcessWithInput(process, input);
    });
    final reply = await child.call('open_context', {'scope': 'authorized'},
        cancelled: const Stream.empty());
    expect(reply['data'], {'contextRef': 'synthetic-read'});
    input.addError(const LinkException('synthetic_input_error'));
    // Let the owner observe the sink's error before anyone requests close.
    await Future<void>.delayed(Duration.zero);
    await expectLater(input.done, throwsA(isA<LinkException>()));
    final rejected = expectLater(
        child.close().timeout(const Duration(seconds: 5)),
        throwsA(isA<LinkException>()
            .having((e) => e.code, 'code', 'owner_unsettled')));
    await exitSignal.create();
    await rejected;
    expect(observations, isEmpty);
  });

  test('business child exit leaves the original runtime owner in recovery',
      () async {
    final exitSignal = File(p.join(root.path, 'exit-without-receipt'));
    late LinkAdapterProcess child;
    var businessStarts = 0;
    final active = LinkRuntime(
        installation: runtime.installation,
        store: store,
        backendFactory: (
            {required proof,
            required runId,
            required resourceId,
            required acquired}) async {
          if (proof) {
            final owner = LinkOwnerReference(
                runId: runId,
                resourceId: resourceId,
                processId: 100,
                processStarted: '123456',
                slotRef: 'phone');
            await acquired(owner);
            await receipt(owner, 'enable-proof');
            return _Backend(owner, target, () async {});
          }
          businessStarts++;
          return child = await _startBusinessChild(runtime.installation,
              runId: runId,
              resourceId: resourceId,
              exitSignal: exitSignal,
              acquired: acquired,
              observer: observations.add);
        });
    try {
      await active.connect();
      await active.attach('peer', 'connection');
      final originalOwner = store.state.owner!.toJson();
      final originalLease = store.state.lease!.toJson();
      final reply = await active.call(
          'peer', 'connection', 1, 'open_context', {'scope': 'authorized'});
      expect(reply['data'], {'contextRef': 'synthetic-read'});
      await exitSignal.create();
      await child.disconnected.timeout(const Duration(seconds: 5));
      await expectLater(
          active.disconnect().timeout(const Duration(seconds: 5)),
          throwsA(isA<LinkException>()
              .having((e) => e.code, 'code', 'owner_unsettled')));
      expect(store.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
      expect(store.state.settlement, LinkSettlement.unknown);
      expect(store.state.owner!.toJson(), originalOwner);
      expect(store.state.lease!.toJson(), originalLease);
      expect((await ownership())['lastSettlementState'], 'DIRTY');
      expect(
          jsonDecode(await File(p.join(slot.path, 'link-settlement.json'))
              .readAsString())['mode'],
          'enable-proof');
      await expectLater(
          active.attach('another-peer', 'new'), throwsA(isA<LinkException>()));
      expect(businessStarts, 1);
      expect(observations, isEmpty);
    } finally {
      try {
        await active.close().timeout(const Duration(seconds: 5));
      } on LinkException {
        /* Failed original custody is retained until fixture teardown. */
      }
    }
  });

  test(
      'normal proof and business closure settle exact resources, retaining owner generation',
      () async {
    await runtime.connect();
    expect((await ownership())['lastSettlementState'], 'CLEAN');
    await runtime.attach('peer', 'connection');
    expect((await ownership())['lastSettlementState'], 'DIRTY');
    expect(store.state.ownerGeneration, 'operation');
    await runtime.disconnect();
    expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
    expect((await ownership())['lastSettlementState'], 'CLEAN');
    expect((await ownership())['lastSettlementRef'], backend.owner.resourceId);
    expect((await ownership())['ownerGeneration'], 'operation');
    final observed = jsonDecode(observations.single.encode(1)) as Map;
    expect(observed['event'], 'runtime-settled');
    expect(observed['owner'], backend.owner.toJson());
    expect(observed['stateRevision'], store.state.revision);
  });

  test(
      'second frontend cannot start another adapter or steal the original lease',
      () async {
    await runtime.connect();
    await runtime.attach('first', 'connection');
    final lease = store.state.lease!.toJson();
    await expectLater(
        runtime.attach('second', 'other'), throwsA(isA<LinkException>()));
    expect(starts, 2);
    expect(store.state.lease!.toJson(), lease);
  });

  test('runtime observer failure cannot turn clean settlement into unknown',
      () async {
    observerThrows = true;
    await runtime.connect();
    await runtime.attach('peer', 'connection');
    await runtime.disconnect();
    expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
    expect((await ownership())['lastSettlementState'], 'CLEAN');
    expect(observations, isEmpty);
  });

  for (final observer in ['normal', 'stage-throws', 'summary-throws']) {
    test(
        'specific client failure survives runtime catch with $observer diagnostics and original clean close',
        () async {
      await runtime.connect();
      await runtime.attach('peer', 'connection');
      backend.clientFailed = true;
      if (observer == 'stage-throws') {
        stageHook =
            (_, stage, outcome, cause) => throw StateError('SENTINEL_STAGE');
      }
      callObserverThrows = observer == 'summary-throws';
      final trace = calls.begin('search_questions', {})!;
      final result = await runtime.call(
          'peer', 'connection', 1, 'search_questions', {},
          diagnostic: trace);
      calls.finish(trace);
      expect(result['error'], 'unavailable');
      expect(trace.stages[LinkCallStage.backendCall.index],
          [LinkCallOutcome.failed.index, LinkCallCause.clientFailure.index]);
      expect(calls.incomplete, observer != 'normal');
      await runtime.disconnect();
      expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
      expect((await ownership())['lastSettlementState'], 'CLEAN');
      expect(backend.closes, 1);
    });
  }

  test(
      'real delivered frame before send completion cannot regress observed acknowledgement',
      () async {
    await runtime.connect();
    final ack = Completer<void>(), summary = Completer<void>();
    stageHook = (ordinal, stage, outcome, cause) {
      if (ordinal == 1 &&
          stage == LinkCallStage.deliveryAck &&
          outcome == LinkCallOutcome.succeeded) {
        ack.complete();
      }
    };
    callFinished = summary.complete;
    final business = _Relay()..holdAfterResult = true;
    final control = _Relay();
    final serving = LinkPipeServer(runtime, business, control).serve();
    business.admitted.complete();
    final hello = await business.next();
    business.incoming.add({...hello, 'kind': 'attach'});
    await business.next();
    final lease = store.state.lease!;
    business.incoming.add({
      'version': 1,
      'runId': runtime.runId,
      'connectionId': lease.frontendConnectionId,
      'kind': 'call',
      'id': 1,
      'tool': 'open_context',
      'arguments': <String, dynamic>{}
    });
    await backend.entered.future;
    backend.response.complete({
      'profileVersion': 3,
      'data': <String, dynamic>{},
      'error': null,
      'source': {'kind': 'android', 'deviceRef': target.deviceIdentity}
    });
    final response = await business.next();
    expect(response['kind'], 'result');
    business.incoming.add({
      'version': 1,
      'runId': runtime.runId,
      'connectionId': lease.frontendConnectionId,
      'kind': 'delivered',
      'id': 1
    });
    try {
      await ack.future.timeout(const Duration(seconds: 2));
      expect(store.state.delivery, LinkDelivery.delivered);
      expect(callRows, isEmpty);
    } finally {
      business.releaseSend.complete();
    }
    await summary.future.timeout(const Duration(seconds: 2));
    expect(callRows.single['x'][LinkCallStage.deliveryAck.index][0],
        LinkCallOutcome.succeeded.index);
    control.admitted.complete();
    final ticket = await control.next();
    control.incoming.add({
      ...ticket,
      'action': 'shutdown',
      'targetRef': null,
      'expectedSelectionRevision': null,
      'expectedRevision': null
    });
    expect((await control.next())['error'], isNull);
    control.incoming.add({...ticket, 'kind': 'received'});
    await serving.timeout(const Duration(seconds: 2));
    await business.dispose();
    await control.dispose();
  });

  test(
      'pipe observation waits for original send and preserves unknown EOF delivery',
      () async {
    await runtime.connect();
    final business = _Relay()..holdResult = true;
    final control = _Relay();
    final serving = LinkPipeServer(runtime, business, control).serve();
    business.admitted.complete();
    final hello = await business.next();
    business.incoming.add({...hello, 'kind': 'attach'});
    await business.next();
    final originalLease = store.state.lease!;
    business.incoming.add({
      'version': 1,
      'runId': runtime.runId,
      'connectionId': originalLease.frontendConnectionId,
      'kind': 'call',
      'id': 1,
      'tool': 'open_context',
      'arguments': <String, dynamic>{},
    });
    await backend.entered.future;
    backend.response.complete({
      'profileVersion': 3,
      'data': {'contextRef': 'synthetic'},
      'error': null,
      'source': {'kind': 'android', 'deviceRef': target.deviceIdentity},
    });
    await business.sending.future;
    business.incoming.addError(const LocalRelayException());
    await Future<void>.delayed(Duration.zero);
    expect(observations, isEmpty);
    expect(store.state.owner, isNotNull);
    business.releaseSend.complete();
    await business.next();
    await () async {
      while (observations.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
    }()
        .timeout(const Duration(seconds: 2));
    final events =
        observations.map((o) => jsonDecode(o.encode(1)) as Map).toList();
    expect(events.map((e) => e['event']),
        ['output-work-joined', 'runtime-settled']);
    expect(events.first['delivery'], 'unknown');
    expect(events.first['frontendConnectionId'],
        originalLease.frontendConnectionId);
    expect(events.first['pendingWork'], 1);
    expect(events.first['pendingWorkFailed'], isFalse);
    expect(events.last['leaseId'], originalLease.leaseId);
    expect(callRows, hasLength(1));
    expect(callRows.single['r'], runtime.runId);
    expect(callRows.single['c'], originalLease.frontendConnectionId);
    expect(callRows.single['i'], 1);
    expect(callRows.single['l'], originalLease.leaseId);
    expect(callRows.single['g'], originalLease.routeGeneration);
    expect(callRows.single['o'], [
      backend.owner.resourceId,
      backend.owner.processId,
      backend.owner.processStarted,
      backend.owner.slotRef
    ]);
    expect(callRows.single['x'][LinkCallStage.outputSend.index][0],
        LinkCallOutcome.succeeded.index);
    expect(callRows.single['x'][LinkCallStage.deliveryAck.index][0],
        LinkCallOutcome.unknown.index);
    control.admitted.complete();
    final ticket = await control.next();
    control.incoming.add({
      ...ticket,
      'action': 'shutdown',
      'targetRef': null,
      'expectedSelectionRevision': null,
      'expectedRevision': null
    });
    final response = await control.next();
    expect(response['error'], isNull);
    control.incoming.add({...ticket, 'kind': 'received'});
    await serving.timeout(const Duration(seconds: 2));
    await business.dispose();
    await control.dispose();
  });

  for (final action in ['disconnect', 'shutdown', 'select']) {
    for (final phase in [
      'backend',
      'send',
      'ack',
      if (action == 'disconnect') 'prior-disconnect',
      if (action == 'shutdown') 'prior-close',
    ]) {
      test('local control $action withdraws before joining $phase', () async {
        await runtime.connect();
        final business = _Relay()
          ..notifyDisconnect = true
          ..delayEof = true
          ..holdResult = phase == 'send';
        final control = _Relay()..rearmOnDisconnect = true;
        final requestRead = Completer<void>();
        control.onReceive = (message) {
          if (message['action'] == action && !requestRead.isCompleted) {
            requestRead.complete();
          }
        };
        final serving = LinkPipeServer(runtime, business, control).serve();
        business.admitted.complete();
        final hello = await business.next();
        business.incoming.add({...hello, 'kind': 'attach'});
        await business.next();
        final originalLease = store.state.lease!;
        final originalOwner = store.state.owner!.toJson();
        final selectionRevision = store.state.selectionRevision;
        closeEntered = Completer<void>();
        closeReleased = Completer<void>();
        final envelope = {
          'version': 1,
          'runId': runtime.runId,
          'connectionId': originalLease.frontendConnectionId,
        };
        business.incoming.add({
          ...envelope,
          'kind': 'call',
          'id': 1,
          'tool': 'open_context',
          'arguments': <String, dynamic>{},
        });
        await backend.entered.future;
        void releaseResponse() {
          if (!backend.response.isCompleted) {
            backend.response.complete({
              'profileVersion': 3,
              'data': <String, dynamic>{},
              'error': null,
              'source': {'kind': 'android', 'deviceRef': target.deviceIdentity},
            });
          }
        }

        final pendingBackend = phase == 'backend' || phase.startsWith('prior-');
        if (!pendingBackend) releaseResponse();
        if (phase == 'send') await business.sending.future;
        if (phase == 'ack') {
          expect((await business.next())['kind'], 'result');
        }
        final priorClose = phase == 'prior-disconnect'
            ? runtime.disconnect()
            : phase == 'prior-close'
                ? runtime.close()
                : null;
        control.admitted.complete();
        final ticket = await control.next();
        var replied = false;
        final reply = control.next().then((value) {
          replied = true;
          return value;
        });
        control.incoming.add({
          ...ticket,
          'action': action,
          'targetRef': action == 'select' ? 'phone' : null,
          'expectedSelectionRevision':
              action == 'select' ? selectionRevision : null,
          'expectedRevision': null,
        });
        try {
          await requestRead.future;
          await Future<void>.delayed(Duration.zero);
          expect(
              runtime.mayDeliver(business.linkPeerIdentity,
                  originalLease.frontendConnectionId),
              isFalse);
          expect(runtime.inspect()['ready'], isFalse);
          expect(replied, isFalse);
          expect(backend.closes, 0);
          expect(backend.cancelled, isFalse);
          expect(store.state.owner!.toJson(), originalOwner);
          await expectLater(
              runtime.call(business.linkPeerIdentity,
                  originalLease.frontendConnectionId, 2, 'open_context', {}),
              throwsA(isA<LinkException>()));
          final repeated = runtime.disconnect();
          expect(identical(runtime.disconnect(), repeated), isTrue);
          if (pendingBackend) {
            releaseResponse();
            await business.disconnectRequested.future;
            // Disconnect returns before the receiving loop sees EOF. The last
            // delivery journal must still precede backend/store settlement.
            await Future<void>.delayed(Duration.zero);
            expect(business.resultSends, 0);
            expect(backend.closes, 0);
            expect(replied, isFalse);
            expect(observations, isEmpty);
            business.finishDisconnect();
          } else {
            if (phase == 'send') {
              business.releaseSend.complete();
              expect((await business.next())['kind'], 'result');
              expect(backend.closes, 0);
            }
            business.incoming.add({...envelope, 'kind': 'delivered', 'id': 1});
          }
          await closeEntered!.future.timeout(const Duration(seconds: 5));
          expect(replied, isFalse);
          expect(backend.closes, 1);
          expect(backend.cancelled, isFalse);
          expect(store.state.owner!.toJson(), originalOwner);
          expect(store.state.dirtyPhase, LinkDirtyPhase.draining);
          expect(store.state.delivery,
              pendingBackend ? LinkDelivery.unknown : LinkDelivery.delivered);
          if (phase == 'ack') {
            // A new frame after the close snapshot must not create a pending
            // delivery that can write after the store has closed. Its refusal
            // ends the peer while the original resource is still draining.
            final rejected = Completer<void>();
            stageHook = (ordinal, stage, outcome, cause) {
              if (ordinal == 2 &&
                  stage == LinkCallStage.ipcReceive &&
                  outcome == LinkCallOutcome.rejected) {
                rejected.complete();
              }
            };
            business.incoming.add({
              ...envelope,
              'kind': 'call',
              'id': 2,
              'tool': 'open_context',
              'arguments': <String, dynamic>{},
            });
            await rejected.future.timeout(const Duration(seconds: 5));
            expect(store.state.delivery, LinkDelivery.delivered);
          }
          closeReleased!.complete();
          expect((await reply.timeout(const Duration(seconds: 5)))['error'],
              isNull);
          await repeated;
          await priorClose;
          expect(store.state.owner, isNull);
          expect(store.state.lease, isNull);
          expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
          expect(store.state.selectionRevision,
              selectionRevision + (action == 'select' ? 1 : 0));
          expect((await ownership())['lastSettlementState'], 'CLEAN');
          final events = observations
              .map((observation) => jsonDecode(observation.encode(1)) as Map)
              .toList();
          expect(events.map((event) => event['event']),
              ['output-work-joined', 'runtime-settled']);
          expect(events.last['leaseId'], originalLease.leaseId);
        } finally {
          releaseResponse();
          if (!business.releaseSend.isCompleted) {
            business.releaseSend.complete();
          }
          if (!closeReleased!.isCompleted) closeReleased!.complete();
          business.finishDisconnect();
          await reply.timeout(const Duration(seconds: 5));
          control.incoming.add({...ticket, 'kind': 'received'});
          if (action != 'shutdown') {
            final shutdownTicket = await control.next();
            await Future<void>.delayed(const Duration(milliseconds: 110));
            control.incoming.add({
              ...shutdownTicket,
              'action': 'shutdown',
              'targetRef': null,
              'expectedSelectionRevision': null,
              'expectedRevision': null,
            });
            expect((await control.next())['error'], isNull);
            control.incoming.add({...shutdownTicket, 'kind': 'received'});
          }
          await serving.timeout(const Duration(seconds: 5));
          await business.dispose();
          await control.dispose();
        }
      });
    }
  }

  for (final rejection in ['invalid_target', 'stale_revision']) {
    test('local control select $rejection preserves pending output', () async {
      await runtime.connect();
      final business = _Relay();
      final control = _Relay()..rearmOnDisconnect = true;
      final serving = LinkPipeServer(runtime, business, control).serve();
      business.admitted.complete();
      final hello = await business.next();
      business.incoming.add({...hello, 'kind': 'attach'});
      await business.next();
      final lease = store.state.lease!;
      final envelope = {
        'version': 1,
        'runId': runtime.runId,
        'connectionId': lease.frontendConnectionId,
      };
      business.incoming.add({
        ...envelope,
        'kind': 'call',
        'id': 1,
        'tool': 'open_context',
        'arguments': <String, dynamic>{},
      });
      await backend.entered.future;
      control.admitted.complete();
      final ticket = await control.next();
      control.incoming.add({
        ...ticket,
        'action': 'select',
        'targetRef': rejection == 'invalid_target' ? 'other-phone' : 'phone',
        'expectedSelectionRevision': store.state.selectionRevision +
            (rejection == 'stale_revision' ? 1 : 0),
        'expectedRevision': null,
      });
      expect(
          (await control.next().timeout(const Duration(seconds: 5)))['error'],
          rejection);
      expect(
          runtime.mayDeliver(
              business.linkPeerIdentity, lease.frontendConnectionId),
          isTrue);
      expect(backend.closes, 0);
      expect(backend.cancelled, isFalse);
      control.incoming.add({...ticket, 'kind': 'received'});
      final completed = Completer<void>();
      callFinished = completed.complete;
      backend.response.complete({
        'profileVersion': 3,
        'data': <String, dynamic>{},
        'error': null,
        'source': {'kind': 'android', 'deviceRef': target.deviceIdentity},
      });
      expect((await business.next())['kind'], 'result');
      business.incoming.add({...envelope, 'kind': 'delivered', 'id': 1});
      await completed.future;
      final shutdownTicket = await control.next();
      await Future<void>.delayed(const Duration(milliseconds: 110));
      control.incoming.add({
        ...shutdownTicket,
        'action': 'shutdown',
        'targetRef': null,
        'expectedSelectionRevision': null,
        'expectedRevision': null,
      });
      expect((await control.next())['error'], isNull);
      control.incoming.add({...shutdownTicket, 'kind': 'received'});
      await serving.timeout(const Duration(seconds: 5));
      await business.dispose();
      await control.dispose();
    });
  }

  for (final failedClose in [false, true]) {
    test(
        'disconnect joins pending attach and ${failedClose ? 'retains failed cleanup' : 'waits for original cleanup'}',
        () async {
      acquisitionEntered = Completer<void>();
      acquisitionReleased = Completer<void>();
      closeEntered = Completer<void>();
      closeReleased = Completer<void>();
      failClose = failedClose;
      await runtime.connect();
      final attaching = runtime
          .attach('first', 'connection')
          .then<Object?>((_) => null, onError: (Object error) => error);
      await acquisitionEntered!.future;
      final original = store.state.owner!.toJson();
      var disconnected = false;
      final originalDisconnect = runtime.disconnect();
      expect(identical(runtime.disconnect(), originalDisconnect), isTrue);
      final disconnecting = originalDisconnect.then<Object?>((_) {
        disconnected = true;
        return null;
      }, onError: (Object error) {
        disconnected = true;
        return error;
      });
      try {
        await Future<void>.delayed(Duration.zero);
        expect(disconnected, isFalse);
        expect(runtime.inspect()['ready'], isFalse);
        expect(store.state.lease, isNull);
        await expectLater(
            () => runtime.connect(), throwsA(isA<LinkException>()));
        await expectLater(() => runtime.attach('second', 'other'),
            throwsA(isA<LinkException>()));
        acquisitionReleased!.complete();
        expect(await attaching, isA<LinkException>());
        await closeEntered!.future.timeout(const Duration(seconds: 5));
        expect(disconnected, isFalse);
        expect(backend.closes, 1);
        expect(store.state.lease, isNull);
        expect(store.state.dirtyPhase, LinkDirtyPhase.draining);
        closeReleased!.complete();
        final result = await disconnecting;
        expect(starts, 2);
        expect(store.state.ownerGeneration, 'operation');
        expect(runtime.inspect()['ready'], isFalse);
        expect(runtime.inspect()['prepared'], isFalse);
        if (failedClose) {
          expect(result, isA<LinkException>());
          expect(store.state.owner!.toJson(), original);
          expect(store.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
          expect((await ownership())['lastSettlementState'], 'DIRTY');
          await expectLater(runtime.connect(), throwsA(isA<LinkException>()));
        } else {
          expect(result, isNull);
          expect(store.state.owner, isNull);
          expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
          expect((await ownership())['lastSettlementState'], 'CLEAN');
          expect(
              (await ownership())['lastSettlementRef'], original['resourceId']);
          await expectLater(runtime.attach('first', 'new-connection'),
              throwsA(isA<LinkException>()));
        }
      } finally {
        if (!acquisitionReleased!.isCompleted) acquisitionReleased!.complete();
        if (!closeReleased!.isCompleted) closeReleased!.complete();
      }
    });
  }

  test('disconnect during proof joins it without enabling a late attachment',
      () async {
    holdProof = true;
    acquisitionEntered = Completer<void>();
    acquisitionReleased = Completer<void>();
    final connecting = runtime.connect();
    await acquisitionEntered!.future;
    var disconnected = false;
    final disconnecting = runtime.disconnect().then((_) => disconnected = true);
    try {
      await Future<void>.delayed(Duration.zero);
      expect(disconnected, isFalse);
      acquisitionReleased!.complete();
      await connecting;
      await disconnecting;
      expect(starts, 1);
      expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
      expect(runtime.inspect()['prepared'], isFalse);
      await expectLater(
          runtime.attach('first', 'connection'), throwsA(isA<LinkException>()));
    } finally {
      if (!acquisitionReleased!.isCompleted) acquisitionReleased!.complete();
    }
  });

  test('disconnect cannot report clean when pending acquisition fails',
      () async {
    acquisitionEntered = Completer<void>();
    acquisitionReleased = Completer<void>();
    failAcquisition = true;
    await runtime.connect();
    final attaching = runtime
        .attach('first', 'connection')
        .then<Object?>((_) => null, onError: (Object error) => error);
    await acquisitionEntered!.future;
    final original = store.state.owner!.toJson();
    final disconnecting = runtime
        .disconnect()
        .then<Object?>((_) => null, onError: (Object error) => error);
    acquisitionReleased!.complete();
    expect(await attaching, isA<LinkException>());
    expect(await disconnecting, isA<LinkException>());
    expect(store.state.owner!.toJson(), original);
    expect(store.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
    expect((await ownership())['lastSettlementState'], 'DIRTY');
    expect(observations, isEmpty);
    expect(starts, 2);
    await expectLater(runtime.connect(), throwsA(isA<LinkException>()));
  });

  test(
      'selection drains its backend without joining its own exclusive operation',
      () async {
    await runtime.connect();
    await runtime.attach('first', 'connection');
    closeEntered = Completer<void>();
    closeReleased = Completer<void>();
    final revision = store.state.selectionRevision;
    final selecting = runtime.select('phone', revision);
    await closeEntered!.future.timeout(const Duration(seconds: 5));
    final disconnecting = runtime.disconnect();
    try {
      expect(store.state.selectionRevision, revision);
      expect(runtime.inspect()['ready'], isFalse);
    } finally {
      closeReleased!.complete();
    }
    await selecting.timeout(const Duration(seconds: 5));
    await disconnecting;
    expect(backend.closes, 1);
    expect(store.state.selectionRevision, revision + 1);
    expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
    expect((await ownership())['lastSettlementState'], 'CLEAN');
  });

  test('EOF joins original work and output without manufacturing cancellation',
      () async {
    await runtime.connect();
    await runtime.attach('first', 'connection');
    final call = runtime.call('first', 'connection', 1, 'open_context', {});
    await backend.entered.future;
    var closed = false;
    final close = runtime.disconnect().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    expect(backend.cancelled, isFalse);
    backend.response.complete({
      'profileVersion': 3,
      'data': {'contextRef': 'synthetic'},
      'error': null,
      'source': {'kind': 'android', 'deviceRef': target.deviceIdentity}
    });
    await call;
    await close;
    expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
  });

  test(
      'old proof receipt cannot clear a business resource, even when helper exits',
      () async {
    await runtime.connect();
    await runtime.attach('first', 'connection');
    final original = store.state.owner!.toJson();
    wrongReceipt = true;
    await expectLater(runtime.disconnect(), throwsA(isA<LinkException>()));
    expect(store.state.owner!.toJson(), original);
    expect(store.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
    expect((await ownership())['ownershipState'], 'LINK_OWNED');
    expect((await ownership())['lastSettlementState'], 'DIRTY');
  });

  test('failed original settlement keeps dirty custody and blocks replacement',
      () async {
    await runtime.connect();
    await runtime.attach('first', 'connection');
    failClose = true;
    await expectLater(runtime.disconnect(), throwsA(isA<LinkException>()));
    await expectLater(runtime.connect(), throwsA(isA<LinkException>()));
    expect(starts, 2);
    expect(store.state.owner, isNotNull);
    expect((await ownership())['ownerGeneration'], 'operation');
    expect(observations, isEmpty);
  });

  test(
      'local initialization exposes original fingerprint while close still joins the active owner',
      () async {
    final freshSlot = await Directory(p.join(root.path, 'fresh-slot')).create();
    final freshState =
        await Directory(p.join(root.path, 'fresh-state')).create();
    final config = LinkInstallation(
        stateDirectory: freshState.path,
        slotDirectory: freshSlot.path,
        slotRef: 'new-phone',
        connectorInstanceId: 'new-owner',
        operationId: 'new-operation',
        adapterExecutable: p.join(root.path, 'not-started.exe'));
    final initial =
        LinkInitialization(config, processCurrent: (_, __) => false);
    final initialStore = await initial.open(initialize: true);
    final result = Completer<LinkVerifiedTarget>();
    var attempts = 0;
    final local = LinkRuntime(
        installation: config,
        store: initialStore,
        initializationFactory: (
            {required runId, required resourceId, required onFingerprint}) {
          attempts++;
          onFingerprint('a' * 64);
          return result.future;
        });
    await local.initialize();
    expect(local.inspect()['pairingClientFingerprint'], 'a' * 64);
    expect(local.inspect()['busy'], isTrue);
    expect(local.state.ownerGeneration, isNull);
    await expectLater(local.initialize(), throwsA(isA<LinkException>()));
    expect(attempts, 1);
    var ended = false;
    final closing = local.close().then<void>((_) {
      ended = true;
    }, onError: (Object _) {
      ended = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(ended, isFalse);
    result.completeError(const LinkException('initialization_incomplete'));
    await closing;
    expect(
        local.inspect()['initializationFailure'], 'initialization_incomplete');
    expect(local.state.ownerGeneration, isNull);
    await initialStore.close();
  });
}
