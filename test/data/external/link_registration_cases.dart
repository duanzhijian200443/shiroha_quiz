import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/link/link_adapter_process.dart';
import 'package:shiroha_quiz/data/external/link/link_initialization.dart';
import 'package:shiroha_quiz/data/external/link/link_installation.dart';
import 'package:shiroha_quiz/data/external/link/link_registration.dart';
import 'package:shiroha_quiz/data/external/link/link_state_store.dart';
import 'package:shiroha_quiz/data/external/link/link_values.dart';
import 'package:shiroha_quiz/data/external/link/slot_ownership_store.dart';

void registrationCases() {
  group('portable V3 custody refusal without credential or producer authority',
      () {
    late Directory root, slot;
    late LinkInstallation config;
    late LinkRegistration registrar;
    final identity = <String, dynamic>{
      'registrarInstanceId': 'registrar',
      'operationId': 'registration',
      'generation': 'generation',
      'runId': 'run',
      'resourceId': 'resource'
    };
    setUp(() async {
      final base = await Directory('build/link-registration-tests')
          .absolute
          .create(recursive: true);
      root = await base.createTemp('portable-');
      slot = await Directory(p.join(root.path, 'slot')).create();
      config = LinkInstallation(
          stateDirectory: slot.path,
          slotDirectory: slot.path,
          slotRef: 'slot',
          connectorInstanceId: 'registrar',
          operationId: 'registration',
          adapterExecutable: p.join(root.path, 'unused'));
      registrar = LinkRegistration(config, processCurrent: (_, __) => false);
    });
    test(
        'trusted preparation records independent registrar with no verified identity or Link state',
        () async {
      final prepared = await registrar.prepare(identity);
      expect(prepared.value['ownershipState'], 'REGISTERING');
      expect(prepared.value['ownerKind'], 'independent_registrar');
      expect(prepared.value['verifiedInstallationBinding'], isNull);
      expect(prepared.value['sourceDigest'], isNull);
      expect(prepared.value['adoption'], isNull);
      expect(
          await File(p.join(slot.path, 'link-state-v2.json')).exists(), false);
      expect((await registrar.prepare(identity)).value, prepared.value);
    });
    test(
        'unknown version, claimed placeholder and altered registrar identity reject',
        () async {
      final prepared = await registrar.prepare(identity);
      for (final replacement in <Map<String, Object?>>[
        {'formatVersion': 99},
        {'ownershipState': 'LINK_OWNED'},
        {'ownerKind': 'independent_link'},
        {'ownerInstanceId': 'other'},
        {'operationId': 'other'},
        {'ownerGeneration': 'other'},
        {'resourceGeneration': 'other'},
        {'sourceDigest': 'a' * 64},
        {'lastSettlementState': 'CLEAN'}
      ]) {
        expect(() => SlotOwnershipRecord({...prepared.value, ...replacement}),
            throwsA(isA<Exception>()));
      }
    });
    test('preparation and ciphertext alone cannot seal or be adopted',
        () async {
      final prepared = await registrar.prepare(identity);
      await File(p.join(slot.path, 'device.dpapi'))
          .writeAsString('synthetic-no-secret');
      await expectLater(registrar.seal(), throwsA(isA<Exception>()));
      await expectLater(registrar.adopt(), throwsA(isA<Exception>()));
      final actual =
          await registrar.slots.locked(() => registrar.slots.readLocked());
      expect(actual!.value, prepared.value);
    });
    test('different operation and occupied slot preserve first custody',
        () async {
      final prepared = await registrar.prepare(identity);
      await expectLater(
          registrar.prepare({...identity, 'operationId': 'different'}),
          throwsA(isA<Exception>()));
      expect((await registrar.prepare(identity)).value, prepared.value);
    });
  });
  group('V3 original registrar producer and one-time adoption', () {
    late Directory suite, root, slot, state;
    late String producer;
    late LinkInstallation registrar, link;
    late LinkRegistration registration;
    final identity = <String, dynamic>{
      'registrarInstanceId': 'registrar',
      'operationId': 'registration-operation',
      'generation': 'registration-generation',
      'runId': 'registration-run',
      'resourceId': 'registration-resource'
    };
    setUpAll(() async {
      final base = Directory('build/link-registration-tests').absolute;
      await base.create(recursive: true);
      suite = await base.createTemp('registration-tests-');
      final feed = await Directory(p.join(suite.path, 'feed')).create();
      final output = p.join(suite.path, 'dotnet');
      final build = await Process.run('dotnet', [
        'build',
        'test/data/external/fixtures/registration_producer/RegistrationProducer.csproj',
        '--artifacts-path',
        output,
        '--source',
        feed.path,
        '-m:1',
        '-p:UseSharedCompilation=false',
        '--nologo'
      ]);
      await File(p.join(suite.path, 'build.log'))
          .writeAsString('${build.stdout}\n${build.stderr}');
      expect(build.exitCode, 0,
          reason: 'Offline original-producer fixture compilation');
      producer = p.join(output, 'bin', 'RegistrationProducer', 'debug',
          'RegistrationProducer.dll');
    });
    setUp(() async {
      root = await suite.createTemp('case-');
      slot = await Directory(p.join(root.path, 'slot')).create();
      state = await Directory(p.join(root.path, 'state')).create();
      registrar = LinkInstallation(
          stateDirectory: slot.path,
          slotDirectory: slot.path,
          slotRef: 'synthetic-slot',
          connectorInstanceId: 'registrar',
          operationId: 'registration-operation',
          adapterExecutable: producer);
      link = LinkInstallation(
          stateDirectory: state.path,
          slotDirectory: slot.path,
          slotRef: 'synthetic-slot',
          connectorInstanceId: 'adopting-link',
          operationId: 'adoption-operation',
          adapterExecutable: producer);
      registration =
          LinkRegistration(registrar, processCurrent: (_, __) => false);
    });
    // Retain disposable artifacts in build for interruption/diff diagnosis.
    Future<Map<String, dynamic>> read(String name,
            {bool local = false}) async =>
        jsonDecode(await File(p.join(local ? state.path : slot.path, name))
            .readAsString()) as Map<String, dynamic>;
    Future<void> write(String name, Map<String, dynamic> value,
            {bool local = false}) async =>
        File(p.join(local ? state.path : slot.path, name))
            .writeAsString(jsonEncode(value));
    Future<LinkInitializationSupervision> supervise({bool inspect = false}) =>
        LinkAdapterProcess.superviseInitialization(inspect ? link : registrar,
            runId: inspect ? 'inspection-run' : identity['runId'] as String,
            resourceId: inspect
                ? 'inspection-resource'
                : identity['resourceId'] as String,
            action: inspect ? '--link-inspect-registration' : '--register-pair',
            startProcess: (_, args,
                    {required runInShell, required workingDirectory}) =>
                Process.start(
                    'dotnet',
                    [
                      producer,
                      slot.path,
                      if (inspect) ...[args[1], args[2]]
                    ],
                    runInShell: false));
    Future<void> seal() =>
        registration.run(PairingRegistration(registrar, identity),
            requireCurrent: () {}, producer: supervise);
    LinkInitialization initializer() =>
        LinkInitialization(link, processCurrent: (_, __) => false);
    Future<void> adopt() async {
      final store = await initializer().open(
          initialize: true,
          registrationInspector: () => supervise(inspect: true));
      expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
      await store.close();
    }

    final refuses = throwsA(isA<Exception>());

    test('Windows receipt publisher replaces proof and business atomically',
        () async {
      final result = await Process.run(
          'dotnet', [producer, '--settlement-publication', slot.path]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('PASS: six publications'));
      expect(result.stdout, contains('publication_refused hresult=0x'));
    });

    test(
        'real producer and original process join seal without Link state; adoption is single owner',
        () async {
      await seal();
      expect((await read('slot-ownership.json'))['ownershipState'], 'SEALED');
      expect(await state.list().isEmpty, true);
      expect(
          await File(p.join(slot.path, 'link-state-v2.json')).exists(), false);
      final original =
          await File(p.join(slot.path, 'registration-receipt.json'))
              .readAsBytes();
      await write(
          'link-settlement.json', {'mode': 'business', 'resourceId': 'later'});
      await adopt();
      expect(
          await File(p.join(slot.path, 'registration-receipt.json'))
              .readAsBytes(),
          original);
      final before = await read('slot-ownership.json');
      await adopt();
      expect(await read('slot-ownership.json'), before);
      await expectLater(
          registration.run(PairingRegistration(registrar, identity),
              requireCurrent: () {}, producer: supervise),
          refuses);
      final other = LinkInstallation(
          stateDirectory: state.path,
          slotDirectory: slot.path,
          slotRef: link.slotRef,
          connectorInstanceId: 'other-link',
          operationId: 'other-operation',
          adapterExecutable: producer);
      await expectLater(
          LinkRegistration(other, processCurrent: (_, __) => false).adopt(),
          refuses);
    });

    test(
        'gone PID without original join remains REGISTERING; no helper re-pair',
        () async {
      await registration.prepare(identity);
      await supervise();
      await expectLater(registration.seal(), refuses);
      var called = false;
      await expectLater(
          registration.run(PairingRegistration(registrar, identity),
              requireCurrent: () {}, producer: () async {
            called = true;
            return supervise();
          }),
          refuses);
      expect(called, false);
      expect(
          (await read('slot-ownership.json'))['ownershipState'], 'REGISTERING');
    });

    test(
        'source drift, changed credentials and truncated/unknown source reject without ownership writes',
        () async {
      await seal();
      final before = await read('slot-ownership.json');
      for (final name in [
        'device.dpapi',
        'registration-receipt.json',
        'registration-origin.json',
        'registration-joined.json',
        'registration-source.json'
      ]) {
        final file = File(p.join(slot.path, name));
        final bytes = await file.readAsBytes();
        await file.writeAsString('{"formatVersion":99');
        await expectLater(adopt(), refuses);
        expect(await read('slot-ownership.json'), before);
        await file.writeAsBytes(bytes);
      }
      final manifest = await read('registration-source.json');
      await write(
          'registration-source.json', {...manifest, 'formatVersion': 99});
      await expectLater(adopt(), refuses);
    });

    test(
        'original owner/op/run/resource/PID/start/association binding mismatch rejects seal',
        () async {
      await registration.prepare(identity);
      final result = await supervise();
      await registration.publishJoin(result);
      final receipt = await read('registration-receipt.json');
      for (final field in [
        'owner',
        'operationId',
        'runId',
        'resourceId',
        'processId',
        'processStarted'
      ]) {
        await write('registration-receipt.json',
            {...receipt, field: field == 'processId' ? 999 : 'wrong'});
        await expectLater(registration.seal(), refuses);
      }
      await write('registration-receipt.json', receipt);
      final origin = await read('registration-origin.json');
      await write(
          'registration-origin.json', {...origin, 'associationRevision': 0});
      await expectLater(registration.seal(), refuses);
      await write('registration-origin.json', origin);
      await registration.seal();
    });

    test(
        'inspection source changed before CAS refuses; live original inspection refuses',
        () async {
      await seal();
      final adopter = LinkRegistration(link, processCurrent: (_, __) => false);
      await expectLater(adopter.adopt(inspect: () async {
        final result = await supervise(inspect: true);
        await File(p.join(slot.path, 'device.dpapi'))
            .writeAsString('changed-after-inspection');
        return result;
      }), refuses);
      expect((await read('slot-ownership.json'))['ownershipState'], 'SEALED');
      await File(p.join(slot.path, 'device.dpapi'))
          .writeAsString('synthetic-ciphertext-no-secret');
      final live = LinkRegistration(link, processCurrent: (_, __) => true);
      await expectLater(
          live.adopt(inspect: () => supervise(inspect: true)), refuses);
      expect((await read('slot-ownership.json'))['ownershipState'], 'SEALED');
    });

    test(
        'v2 owned plus missing Link state refuses, preserving later dirty custody',
        () async {
      await seal();
      await adopt();
      final custody = await read('slot-ownership.json');
      await write('slot-ownership.json', {
        ...custody,
        'resourceGeneration': 'later-business',
        'lastSettlementState': 'DIRTY'
      });
      final stateFile = File(p.join(state.path, 'link-state-v2.json'));
      await stateFile
          .rename(p.join(state.path, 'retained-original-state.json'));
      await expectLater(adopt(), refuses);
      expect(
          (await read('slot-ownership.json'))['lastSettlementState'], 'DIRTY');
      expect(await stateFile.exists(), false);
    });

    test('each original evidence pending resumes only complete original bytes',
        () async {
      await registration.prepare(identity);
      final result = await supervise();
      await registration.publishJoin(result);
      await File(p.join(slot.path, 'registration-joined.json'))
          .rename(p.join(slot.path, 'registration-joined.json.pending'));
      await registration.seal();
      final custody = await read('slot-ownership.json');
      await write('slot-ownership.json', {
        ...custody,
        'ownershipState': 'REGISTERING',
        'sourceDigest': null,
        'verifiedInstallationBinding': null,
        'adapterCredentialSlotRef': null,
        'lastSettlementRef': null,
        'lastSettlementState': 'UNKNOWN',
        'revision': 0
      });
      await File(p.join(slot.path, 'registration-source.json'))
          .rename(p.join(slot.path, 'registration-source.json.pending'));
      await registration.seal();
      expect((await read('slot-ownership.json'))['ownershipState'], 'SEALED');
    });

    test(
        'ADOPT_PENDING with no Link state resumes same operation and refuses second owner',
        () async {
      await seal();
      final adopter = LinkRegistration(link, processCurrent: (_, __) => false);
      await adopter.adopt(inspect: () => supervise(inspect: true));
      expect((await read('slot-ownership.json'))['ownershipState'],
          'ADOPT_PENDING');
      expect(await state.list().isEmpty, true);
      final pending = await read('slot-ownership.json');
      await write('slot-ownership.pending', pending);
      await write('slot-ownership.json', {
        ...pending,
        'ownershipState': 'SEALED',
        'ownerKind': 'independent_registrar',
        'ownerInstanceId': 'registrar',
        'operationId': 'registration-operation',
        'ownerGeneration': 'registration-generation',
        'adoption': null,
        'revision': pending['revision'] - 1
      });
      await adopt();
      expect((await read('slot-ownership.json'))['ownerInstanceId'],
          'adopting-link');
    });

    test('slot concurrent writer and legacy entries refuse registration',
        () async {
      final gate = Completer<void>(), entered = Completer<void>();
      final held = registration.slots.locked(() async {
        entered.complete();
        await gate.future;
      });
      await entered.future;
      await expectLater(registration.prepare(identity), refuses);
      gate.complete();
      await held;
      await File(p.join(slot.path, 'host-handoff.pending'))
          .writeAsString('retained');
      await expectLater(registration.prepare(identity), refuses);
      expect(
          await File(p.join(slot.path, 'slot-ownership.json')).exists(), false);
    });

    for (final boundary in [
      'adopt-pending',
      'adopt-final',
      'initializing-pending',
      'initializing-final',
      'owned-pending',
      'owned-final',
      'clean-pending',
      'clean-final'
    ]) {
      test('same operation resumes publication boundary $boundary', () async {
        await seal();
        final sealed = await read('slot-ownership.json');
        await LinkRegistration(link, processCurrent: (_, __) => false)
            .adopt(inspect: () => supervise(inspect: true));
        final adopting = await read('slot-ownership.json');
        final initialStore = await LinkStateStore.open(state,
            initialState: LinkState(
                connectorInstanceId: link.connectorInstanceId,
                initializationOperationId: link.operationId,
                targetRef: link.slotRef,
                dirtyPhase: LinkDirtyPhase.initializing,
                diagnostic: 'initialization_pending',
                settlement: LinkSettlement.unknown));
        await initialStore.close();
        final initializing = await read('link-state-v2.json', local: true);
        await adopt();
        final owned = await read('slot-ownership.json');
        final clean = await read('link-state-v2.json', local: true);
        // Reconstruct only this freshly generated synthetic publication boundary.
        final stateFile = File(p.join(state.path, 'link-state-v2.json'));
        await stateFile.rename(p.join(state.path, 'retained-clean.json'));
        await write(
            'slot-ownership.json',
            boundary == 'adopt-pending'
                ? sealed
                : [
                    'adopt-final',
                    'initializing-pending',
                    'initializing-final',
                    'owned-pending'
                  ].contains(boundary)
                    ? adopting
                    : owned);
        if (boundary == 'adopt-pending') {
          await write('slot-ownership.pending', adopting);
        }
        if (boundary == 'owned-pending') {
          await write('slot-ownership.pending', owned);
        }
        if (boundary == 'initializing-pending') {
          await write('link-state-v2.pending', initializing, local: true);
        }
        if ([
          'initializing-final',
          'owned-pending',
          'owned-final',
          'clean-pending'
        ].contains(boundary)) {
          await write('link-state-v2.json', initializing, local: true);
        }
        if (boundary == 'clean-pending') {
          await write('link-state-v2.pending', clean, local: true);
        }
        if (boundary == 'clean-final') {
          await write('link-state-v2.json', clean, local: true);
        }
        await adopt();
        expect(await read('slot-ownership.json'), owned);
        expect(await read('link-state-v2.json', local: true), clean);
      });
    }

    test(
        'clean state pending with absent previous state cannot reconstruct an owned state',
        () async {
      await seal();
      await adopt();
      await File(p.join(state.path, 'link-state-v2.json'))
          .rename(p.join(state.path, 'link-state-v2.pending'));
      final bytes =
          await File(p.join(state.path, 'link-state-v2.pending')).readAsBytes();
      await expectLater(adopt(), refuses);
      expect(
          await File(p.join(state.path, 'link-state-v2.pending')).readAsBytes(),
          bytes);
    });

    test('competing adoption inspector cannot change the first reserved owner',
        () async {
      await seal();
      final entered = Completer<void>(), release = Completer<void>();
      final first = LinkRegistration(link, processCurrent: (_, __) => false)
          .adopt(inspect: () async {
        entered.complete();
        await release.future;
        return supervise(inspect: true);
      });
      await entered.future;
      await LinkRegistration(link, processCurrent: (_, __) => false)
          .adopt(inspect: () => supervise(inspect: true));
      release.complete();
      await expectLater(first, refuses);
      expect((await read('slot-ownership.json'))['ownershipState'],
          'ADOPT_PENDING');
    });
    test(
        'complete inspection join pending resumes; malformed join cannot publish',
        () async {
      await seal();
      final sealed = await read('slot-ownership.json');
      final adopter = LinkRegistration(link, processCurrent: (_, __) => false);
      await adopter.adopt(inspect: () => supervise(inspect: true));
      await write('slot-ownership.json', sealed);
      final joined = await read('registration-adoption-joined.json');
      final original =
          File(p.join(slot.path, 'registration-adoption-joined.json'));
      await original.rename(
          p.join(slot.path, 'registration-adoption-joined.json.pending'));
      await write('registration-adoption-joined.json.pending',
          {...joined, 'stderrDrained': false});
      await expectLater(adopter.adopt(), refuses);
      expect(await original.exists(), false);
      await write('registration-adoption-joined.json.pending', joined);
      await adopter.adopt();
      expect((await read('slot-ownership.json'))['ownershipState'],
          'ADOPT_PENDING');
      expect(await read('registration-adoption-joined.json'), joined);
    });
  },
      skip: !Platform.isWindows
          ? 'Explicit Windows/.NET 10 producer integration; standing portable CI does not supply this toolchain.'
          : false);
}
