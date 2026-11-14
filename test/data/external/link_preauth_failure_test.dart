import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/link/link_adapter_process.dart';
import 'package:shiroha_quiz/data/external/link/link_failure_settlement.dart';
import 'package:shiroha_quiz/data/external/link/link_initialization.dart';
import 'package:shiroha_quiz/data/external/link/link_installation.dart';
import 'package:shiroha_quiz/data/external/link/link_runtime.dart';
import 'package:shiroha_quiz/data/external/link/link_state_store.dart';
import 'package:shiroha_quiz/data/external/link/link_values.dart';
import '../../../tool/link/control.dart' as control;

const target = LinkVerifiedTarget(
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'installation',
    'profile');

class _Fixture {
  late Directory root;
  late LinkInstallation config;
  late LinkStateStore store;
  late LinkRuntime runtime;
  late LinkFailureSettlement evidence;
  int starts = 0;
  Future<Process> Function(String, String)? launch;
  bool Function(int, String) identity =
      (pid, start) => pid == 42 && start == '123456';

  Future<void> open({bool native = false}) async {
    final parent = await Directory(p.absolute(
            'build', native ? 'link-preauth-native' : 'link-preauth-tests'))
        .create(recursive: true);
    root = await parent.createTemp('case-');
    final slot = await Directory(p.join(root.path, 'slot')).create();
    final state = await Directory(p.join(root.path, 'state')).create();
    config = LinkInstallation(
        stateDirectory: state.path,
        slotDirectory: slot.path,
        slotRef: 'phone',
        connectorInstanceId: 'connector',
        operationId: 'operation',
        adapterExecutable: p.join(root.path, 'adapter.exe'));
    evidence = LinkFailureSettlement(config);
    final init = LinkInitialization(config, processCurrent: (_, __) => false);
    store = await init.open(initialize: true);
    const pairing = LinkOwnerReference(
        runId: 'pair-run',
        resourceId: 'pair-resource',
        processId: 100,
        processStarted: '123456',
        slotRef: 'phone');
    await write('device.dpapi', 'synthetic-only');
    await write('link-settlement.json', {
      'formatVersion': 2,
      'operationId': 'operation',
      'receiptRef': pairing.resourceId,
      ...pairing.toJson(),
      'owner': 'connector',
      'mode': 'pairing',
      'target': target.toJson(),
      'targetClose': true,
      'tlsShutdown': true,
      'keyRetired': true,
    });
    await write('initialization-joined.json', {
      'formatVersion': 1,
      'operationId': 'operation',
      'ownerInstanceId': 'connector',
      ...pairing.toJson(),
      'adapterReceiptRef': pairing.resourceId,
      'target': target.toJson(),
      'processExitCode': 0,
      'stdinClosed': true,
      'stdoutDrained': true,
      'stderrDrained': true,
    });
    await write('adapter-origin.json', {
      'formatVersion': 1,
      'slotRef': 'phone',
      'origin': 'independent_adapter_pairing',
      'operationId': 'operation',
      'target': target.toJson(),
      'credentialSlotRef': 'device.dpapi',
      'resourceGeneration': pairing.resourceId,
      'settlementRef': pairing.resourceId,
    });
    await init.complete(store, target);
    runtime = LinkRuntime(
        installation: config,
        store: store,
        backendFactory: ({
          required proof,
          required runId,
          required resourceId,
          candidateAddress,
          routeOnly = false,
          required acquired,
        }) {
          starts++;
          return LinkAdapterProcess.start(config,
              proof: proof,
              runId: runId,
              resourceId: resourceId,
              acquired: acquired,
              processIdentityMatches: (pid, start) => identity(pid, start),
              startProcess: launch == null
                  ? null
                  : (_, __, {required runInShell, required workingDirectory}) =>
                      launch!(runId, resourceId));
        });
  }

  Future<void> write(String name, Object value) =>
      File(p.join(config.slotDirectory, name))
          .writeAsString(value is String ? value : jsonEncode(value))
          .then((_) {});
  Future<Map<String, dynamic>> read(String name) =>
      evidence.slots.readJson(name);
  Map<String, Object?> receipt(LinkOwnerReference owner) => {
        'formatVersion': 1,
        'kind': 'preauth-failure',
        'operationId': 'operation',
        'owner': 'connector',
        'ownerGeneration': 'operation',
        ...owner.toJson(),
        'receiptRef': owner.resourceId,
        'mode': 'enable-proof',
        'stage': 'tls',
        'resources': 'released',
        'tlsEstablished': false,
        'peerObserved': false,
        'socketClosed': true,
        'tlsClosed': true,
        'keyRetired': true,
        'pendingClear': true,
        'target': target.toJson(),
      };
  Future<void> dispose() async {
    await store.close();
    await root.delete(recursive: true);
  }
}

class _Input implements StreamConsumer<List<int>> {
  final released = Completer<void>();
  bool held = false, failed = false;
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();
  @override
  Future<void> close() async {
    if (held) await released.future;
    if (failed) {
      throw const FileSystemException('fixture-input');
    }
  }
}

class _Process implements Process {
  _Process() {
    stdin = IOSink(input);
  }
  final input = _Input();
  final output = StreamController<List<int>>(),
      events = StreamController<List<int>>();
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
  void emit(Map<String, Object?> value) =>
      events.add(utf8.encode('SHIROHA_LINK_EVENT ${jsonEncode(value)}\n'));
  Future<LinkOwnerReference> settle(
      _Fixture fixture, String run, String resource,
      {int code = 80,
      bool event = true,
      Map<String, Object?> edits = const {}}) async {
    final owner = LinkOwnerReference(
        runId: run,
        resourceId: resource,
        processId: pid,
        processStarted: '123456',
        slotRef: 'phone');
    emit({'type': 'owner', ...owner.toJson()});
    await fixture.write(fixture.evidence.receiptName(resource),
        {...fixture.receipt(owner), ...edits});
    if (event) {
      emit({
        'type': 'preauth-failure-settled',
        'runId': run,
        'resourceId': resource,
        'version': 1
      });
    }
    exited.complete(code);
    unawaited(output.close());
    unawaited(events.close());
    return owner;
  }
}

// Query creation FILETIME from the original, still-blocked fixture process.
// No PID disappearance or injected success boolean supplies this evidence.
String _creation(int pid) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final open = kernel.lookupFunction<IntPtr Function(Uint32, Int32, Uint32),
      int Function(int, int, int)>('OpenProcess');
  final close = kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  final heap = kernel
      .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap')();
  final alloc = kernel.lookupFunction<
      Pointer<Uint64> Function(IntPtr, Uint32, IntPtr),
      Pointer<Uint64> Function(int, int, int)>('HeapAlloc');
  final free = kernel.lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<Uint64>),
      int Function(int, int, Pointer<Uint64>)>('HeapFree');
  final times = kernel.lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>,
          Pointer<Uint64>),
      int Function(int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>,
          Pointer<Uint64>)>('GetProcessTimes');
  final process = open(0x1000, 0, pid);
  if (process == 0) throw StateError('fixture-identity-unavailable');
  final buffer = alloc(heap, 0, 32);
  try {
    if (buffer == nullptr ||
        times(process, buffer, buffer + 1, buffer + 2, buffer + 3) == 0) {
      throw StateError('fixture-identity-unavailable');
    }
    return buffer.value.toString();
  } finally {
    if (buffer != nullptr) free(heap, 0, buffer);
    close(process);
  }
}

void main() {
  test('local recovery control frame carries revision without routing fields',
      () {
    final hello = <String, Object?>{
      'version': 1,
      'ticket': 'ticket',
      'runId': 'run'
    };
    final request =
        control.linkControlRequest(hello, ['recover-preauth', '37']);
    linkFields(request, {
      'version',
      'ticket',
      'runId',
      'action',
      'targetRef',
      'expectedSelectionRevision',
      'expectedRevision'
    });
    expect(request['action'], 'recover-preauth');
    expect(request['expectedRevision'], 37);
    final refresh =
        control.linkControlRequest(hello, ['refresh-address', '192.168.1.2']);
    expect(refresh['candidateAddress'], '192.168.1.2');
    expect(refresh['expectedRevision'], isNull);
  });
  late _Fixture fixture;
  setUp(() async {
    fixture = _Fixture();
    await fixture.open();
  });
  tearDown(() => fixture.dispose());

  Future<void> failedProof(
      {Map<String, Object?> edits = const {},
      int code = 80,
      bool event = true,
      bool identity = true}) async {
    fixture.identity = (_, __) => identity;
    fixture.launch = (run, resource) async {
      final process = _Process();
      unawaited(process.settle(fixture, run, resource,
          edits: edits, code: code, event: event));
      return process;
    };
    await expectLater(fixture.runtime.connect(), throwsA(anything));
    expect(fixture.store.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
  }

  test('complete pre-TLS failure requires explicit recovery and fresh connect',
      () async {
    final pairing = await fixture.read('link-settlement.json');
    final provenance = await fixture.read('adapter-origin.json');
    await failedProof();
    final owner = fixture.store.state.owner!;
    final revision = fixture.store.state.revision;
    expect(owner.processStarted, '123456');
    expect(fixture.runtime.inspect()['prepared'], isFalse);
    await expectLater(fixture.runtime.connect(), throwsA(isA<LinkException>()));
    expect(fixture.starts, 1);
    await fixture.runtime.recoverPreauth(revision);
    expect(fixture.store.state.dirtyPhase, LinkDirtyPhase.clean);
    expect(fixture.store.state.owner, isNull);
    expect(fixture.store.state.ownerGeneration, 'operation');
    expect(fixture.runtime.inspect()['prepared'], isFalse);
    await expectLater(fixture.runtime.attach('peer', 'connection'),
        throwsA(isA<LinkException>()));
    await expectLater(fixture.runtime.recoverPreauth(revision),
        throwsA(isA<LinkException>()));
    expect(await fixture.read('link-settlement.json'), pairing);
    expect(await fixture.read('adapter-origin.json'), provenance);
    await expectLater(
        fixture.runtime.connect(), throwsA(isA<LinkPreauthFailure>()));
    expect(fixture.starts, 2);
    expect(fixture.store.state.owner!.resourceId, isNot(owner.resourceId));
  });

  test('preflight before Process.start has original no-acquisition evidence',
      () async {
    fixture.launch = null;
    await expectLater(
        fixture.runtime.connect(), throwsA(isA<LinkPreauthFailure>()));
    expect(fixture.store.state.owner!.processId, 0);
    await fixture.runtime.recoverPreauth(fixture.store.state.revision);
    expect(fixture.store.state.dirtyPhase, LinkDirtyPhase.clean);
  });
  test('v2 recovery preserves custody generation and sealed-source references',
      () async {
    final original = await fixture.read('slot-ownership.json');
    await fixture.write('slot-ownership.json', {
      ...original,
      'formatVersion': 2,
      'initializationSource': 'registered_pairing',
      'registration': {
        'registrarInstanceId': 'registrar',
        'operationId': 'registration-operation',
        'generation': 'registration-generation',
        'runId': 'registration-run',
        'resourceId': 'registration-resource'
      },
      'sourceDigest': 'c' * 64,
      'adoption': {
        'connectorInstanceId': 'connector',
        'operationId': 'operation'
      },
    });
    final before = await fixture.read('slot-ownership.json');
    final credential =
        await File(p.join(fixture.config.slotDirectory, 'device.dpapi'))
            .readAsBytes();
    await failedProof();
    await fixture.runtime.recoverPreauth(fixture.store.state.revision);
    final after = await fixture.read('slot-ownership.json');
    for (final key in [
      'formatVersion',
      'ownerInstanceId',
      'ownerGeneration',
      'verifiedInstallationBinding',
      'registration',
      'sourceDigest',
      'adoption'
    ]) {
      expect(after[key], before[key], reason: key);
    }
    expect(
        await File(p.join(fixture.config.slotDirectory, 'device.dpapi'))
            .readAsBytes(),
        credential);
    expect(fixture.runtime.inspect()['prepared'], isFalse);
  });

  for (final entry in <String, Map<String, Object?>>{
    'socket close unknown': {'socketClosed': false},
    'TLS close unknown': {'tlsClosed': false},
    'key retirement unknown': {'keyRetired': false},
    'TLS established': {'tlsEstablished': true},
    'peer certificate observed': {'peerObserved': true},
    'proof entered': {'stage': 'proof'},
    'offer entered': {'stage': 'offer'},
    'unknown classification': {'resources': 'unknown'},
    'old run': {'runId': 'old'},
    'old resource': {'resourceId': 'old'},
    'wrong PID': {'processId': 43},
    'PID reused': {'processStarted': '123457'},
    'wrong owner': {'owner': 'other'},
    'wrong generation': {'ownerGeneration': 'other'},
    'wrong slot': {'slotRef': 'other'},
    'wrong version': {'formatVersion': 2},
    'extension field': {'unexpected': true},
  }.entries) {
    test('${entry.key} cannot authorize clean', () async {
      await failedProof(edits: entry.value);
      await expectLater(
          fixture.runtime.recoverPreauth(fixture.store.state.revision),
          throwsA(anything));
      expect(fixture.store.state.owner, isNotNull);
      expect((await fixture.read('slot-ownership.json'))['lastSettlementState'],
          'DIRTY');
    });
  }
  for (final code in [0, 1, 78, 79]) {
    test('exit $code cannot substitute reserved failure exit 80', () async {
      await failedProof(code: code);
      await expectLater(
          fixture.runtime.recoverPreauth(fixture.store.state.revision),
          throwsA(anything));
    });
  }
  test('failure receipt without its original event is insufficient', () async {
    await failedProof(event: false);
    await expectLater(
        fixture.runtime.recoverPreauth(fixture.store.state.revision),
        throwsA(anything));
  });
  test('unverified creation identity is insufficient', () async {
    await failedProof(identity: false);
    await expectLater(
        fixture.runtime.recoverPreauth(fixture.store.state.revision),
        throwsA(anything));
  });
  for (final name in [
    'native-client-key.pending',
    'device.pending',
    'link-settlement.pending',
    'adapter-origin.pending',
    'missing',
    'corrupt',
    'join-missing',
    'join-pending',
    'receipt-pending'
  ]) {
    test('$name prevents recovery and retains original state', () async {
      await failedProof();
      final owner = fixture.store.state.owner!;
      final before = fixture.store.state.toJson();
      if (name == 'missing') {
        await fixture.evidence.slots
            .file(fixture.evidence.receiptName(owner.resourceId))
            .delete();
      } else if (name == 'corrupt') {
        await fixture.write(
            fixture.evidence.receiptName(owner.resourceId), '{');
      } else if (name == 'join-missing') {
        await fixture.evidence.slots
            .file(fixture.evidence.joinName(owner.resourceId))
            .delete();
      } else {
        final file = name == 'join-pending'
            ? '${fixture.evidence.joinName(owner.resourceId)}.pending'
            : name == 'receipt-pending'
                ? '${fixture.evidence.receiptName(owner.resourceId)}.pending'
                : name;
        await fixture.write(file, '{');
      }
      await expectLater(
          fixture.runtime.recoverPreauth(fixture.store.state.revision),
          throwsA(anything));
      expect(fixture.store.state.toJson(), before);
      await expectLater(fixture.runtime.connect(), throwsA(anything));
      expect(fixture.starts, 1);
    });
  }
  test('stale recovery revision and custody resource conflict leave DIRTY',
      () async {
    await failedProof();
    await expectLater(
        fixture.runtime.recoverPreauth(fixture.store.state.revision - 1),
        throwsA(anything));
    final custody = await fixture.read('slot-ownership.json');
    custody['resourceGeneration'] = 'other';
    await fixture.write('slot-ownership.json', custody);
    await expectLater(
        fixture.runtime.recoverPreauth(fixture.store.state.revision),
        throwsA(anything));
    expect(fixture.store.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
  });
  test(
      'recovery intent publication interruption preserves both DIRTY snapshots',
      () async {
    await failedProof();
    final before = fixture.store.state.toJson();
    final custody = await fixture.read('slot-ownership.json');
    final resource = fixture.store.state.owner!.resourceId;
    await Directory(p.join(fixture.config.slotDirectory,
            'link-preauth-$resource-recovery.json'))
        .create();
    await expectLater(
        fixture.runtime.recoverPreauth(fixture.store.state.revision),
        throwsA(anything));
    expect(fixture.store.state.toJson(), before);
    expect(await fixture.read('slot-ownership.json'), custody);
    expect(
        await fixture.evidence.slots
            .file('link-preauth-$resource-recovery.json.pending')
            .exists(),
        isTrue);
  });
  test('failed state CAS preserves original DIRTY custody and full evidence',
      () async {
    await failedProof();
    final before = fixture.store.state.toJson();
    final custody = await fixture.read('slot-ownership.json');
    await File(p.join(fixture.config.stateDirectory, 'link-state-v2.pending'))
        .writeAsString('{');
    await expectLater(
        fixture.runtime.recoverPreauth(fixture.store.state.revision),
        throwsA(anything));
    expect(fixture.store.state.toJson(), before);
    expect(await fixture.read('slot-ownership.json'), custody);
    expect(
        await fixture.evidence
            .requireComplete(fixture.store.state.owner!, target),
        fixture.store.state.owner!.resourceId);
    await expectLater(fixture.runtime.connect(), throwsA(anything));
    expect(fixture.starts, 1);
  });
  test('explicit restart recovery finishes only its exact recorded state CAS',
      () async {
    await failedProof();
    final before = fixture.store.state;
    final custody = await fixture.evidence.slots
        .locked(() => fixture.evidence.slots.readLocked());
    final after = before.change({
      'owner': null,
      'lease': null,
      'dirtyPhase': 'clean',
      'settlement': 'clean',
      'diagnostic': 'none'
    });
    final afterSlot = custody!.change({
      'lastSettlementState': 'CLEAN',
      'lastSettlementRef': before.owner!.resourceId
    });
    await fixture
        .write('link-preauth-${before.owner!.resourceId}-recovery.json', {
      'formatVersion': 1,
      'kind': 'preauth-recovery',
      'beforeState': before.toJson(),
      'afterState': after.toJson(),
      'beforeSlot': custody.value,
      'afterSlot': afterSlot.value,
    });
    await fixture.store.replace(after, expectedRevision: before.revision);
    await fixture.store.close();
    fixture.store = await LinkInitialization(fixture.config,
        processCurrent: (_, __) => false).open(initialize: false);
    fixture.runtime =
        LinkRuntime(installation: fixture.config, store: fixture.store);
    await expectLater(fixture.runtime.connect(), throwsA(anything));
    await fixture.runtime.recoverPreauth(fixture.store.state.revision);
    expect((await fixture.read('slot-ownership.json'))['lastSettlementState'],
        'CLEAN');
    expect(fixture.runtime.inspect()['prepared'], isFalse);
    final revision = fixture.store.state.revision;
    await fixture.runtime.recoverPreauth(revision);
    expect(fixture.store.state.revision, revision);
  });
  test('ProcessException after launch invocation cannot prove no acquisition',
      () async {
    fixture.launch = (_, __) async =>
        throw const ProcessException('fixture', [], 'creation uncertain');
    await expectLater(fixture.runtime.connect(), throwsA(anything));
    await expectLater(
        fixture.runtime.recoverPreauth(fixture.store.state.revision),
        throwsA(anything));
    expect(fixture.store.state.owner, isNotNull);
  });
  test('uncertain creation exception cannot fabricate not-started evidence',
      () async {
    fixture.launch =
        (_, __) async => throw StateError('fixture-unknown-launch');
    await expectLater(fixture.runtime.connect(), throwsA(anything));
    await expectLater(
        fixture.runtime.recoverPreauth(fixture.store.state.revision),
        throwsA(anything));
    expect(fixture.store.state.owner, isNotNull);
  });
  test('original stdin failure cannot publish supervisor join', () async {
    fixture.launch = (run, resource) async {
      final process = _Process();
      process.input.failed = true;
      unawaited(process.settle(fixture, run, resource));
      return process;
    };
    await expectLater(fixture.runtime.connect(), throwsA(anything));
    await expectLater(
        fixture.runtime.recoverPreauth(fixture.store.state.revision),
        throwsA(anything));
    expect(fixture.store.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
  });
  test('original stdin/stdout/stderr joins cannot be inferred from exit',
      () async {
    final process = _Process();
    process.input.held = true;
    fixture.launch = (run, resource) async {
      final owner = LinkOwnerReference(
          runId: run,
          resourceId: resource,
          processId: 42,
          processStarted: '123456',
          slotRef: 'phone');
      process.emit({'type': 'owner', ...owner.toJson()});
      await fixture.write(
          fixture.evidence.receiptName(resource), fixture.receipt(owner));
      process.emit({
        'type': 'preauth-failure-settled',
        'runId': run,
        'resourceId': resource,
        'version': 1
      });
      process.exited.complete(80);
      return process;
    };
    var finished = false;
    final pending = fixture.runtime.connect().then((_) {
      finished = true;
    }, onError: (Object _) {
      finished = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(finished, isFalse);
    process.input.released.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(finished, isFalse);
    await process.output.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(finished, isFalse);
    await process.events.close();
    await pending;
    await fixture.runtime.recoverPreauth(fixture.store.state.revision);
    expect(fixture.store.state.dirtyPhase, LinkDirtyPhase.clean);
  });

  group('Windows original resources and supervisor', () {
    for (final scenario in [
      'not-acquired',
      'tcp-failure',
      'tls-deadline',
      'pending',
      'publish-interrupted',
      'tls-close-failed',
      'cng-delete-failed',
      'socket-close-failed'
    ]) {
      test(scenario, () async {
        await fixture.dispose();
        fixture = _Fixture();
        await fixture.open(native: true);
        final exe = p.absolute(
            'tool/android_device_adapter/bin/Debug/net10.0/AndroidDeviceAdapter.exe');
        expect(File(exe).existsSync(), isTrue,
            reason: 'Build the current adapter before native acceptance');
        fixture.launch = (run, resource) async {
          final process = await Process.start(exe, [
            '--preauth-native-fixture',
            fixture.config.slotDirectory,
            scenario,
            run,
            resource
          ]);
          final creation = _creation(process.pid);
          fixture.identity =
              (pid, start) => pid == process.pid && start == creation;
          return process;
        };
        await expectLater(fixture.runtime.connect(), throwsA(anything));
        expect(fixture.store.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
        if (scenario == 'pending' ||
            scenario == 'publish-interrupted' ||
            scenario == 'tls-close-failed' ||
            scenario == 'cng-delete-failed' ||
            scenario == 'socket-close-failed') {
          if (scenario.endsWith('-failed')) {
            final observed = await fixture.read('fixture-result.json');
            expect(observed['KeyStarted'], isTrue);
            expect(observed['SocketStarted'], isTrue);
            expect(observed['TlsStarted'], isTrue);
            expect(observed['CleanupFailed'], isTrue);
            expect(observed['KeyRetired'], scenario != 'cng-delete-failed');
            if (scenario == 'tls-close-failed') {
              expect(observed['TlsClosed'], isFalse);
            }
            if (scenario == 'socket-close-failed') {
              expect(observed['SocketClosed'], isFalse);
            }
          }
          await expectLater(
              fixture.runtime.recoverPreauth(fixture.store.state.revision),
              throwsA(anything));
        } else {
          final owner = fixture.store.state.owner!;
          expect(owner.processId, greaterThan(0));
          final result =
              File(p.join(fixture.config.slotDirectory, 'fixture-result.json'));
          expect(
              await fixture.evidence.slots
                  .file(fixture.evidence.receiptName(owner.resourceId))
                  .exists(),
              isTrue,
              reason: await result.exists()
                  ? await result.readAsString()
                  : 'native fixture omitted receipt');
          final receipt = await fixture.evidence.receipt(owner);
          expect(receipt['resources'],
              scenario == 'not-acquired' ? 'not-acquired' : 'released');
          expect(
              await fixture.evidence.slots
                  .file('native-client-key.pending')
                  .exists(),
              isFalse);
          await fixture.runtime.recoverPreauth(fixture.store.state.revision);
          expect(fixture.store.state.dirtyPhase, LinkDirtyPhase.clean);
          expect(fixture.runtime.inspect()['prepared'], isFalse);
        }
      });
    }
  },
      skip: !Platform.isWindows ||
          !const bool.fromEnvironment('LINK_PREAUTH_NATIVE'));
}
