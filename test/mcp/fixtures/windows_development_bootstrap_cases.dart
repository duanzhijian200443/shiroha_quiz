import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/first_party_development_access.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_development_app.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/data/external/windows_credential_initialization.dart';
import 'package:shiroha_quiz/data/external/windows_development_bootstrap.dart';
import 'package:shiroha_quiz/data/external/windows_bridge_process.dart';
import 'package:shiroha_quiz/data/external/windows_process_observation.dart';
import 'package:shiroha_quiz/composition/bridge_ui_host.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_development_pairing.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_app_owned_relay.dart';
import '../../data/external/windows_pairing_test.dart' show PairingHarness;
import 'settled_test_directory.dart';
import 'windows_resource_process_cases.dart' show FakeBridgeProcessIo;

void windowsDevelopmentBootstrapCases() {
  test('business socket diagnostics classify provider failure without raw text',
      () {
    expect(
        businessDiagnosticFailureCode(const SocketException('private',
            osError: OSError('private', 10106))),
        FirstPartyBusinessFailureCode.socketProviderUnavailable);
    expect(
        businessDiagnosticFailureCode(const SocketException('private',
            osError: OSError('private', 10061))),
        FirstPartyBusinessFailureCode.socketUnavailable);
  });
  test(
      'business diagnostics preserve first refusal and separate cleanup without private output',
      () {
    final diagnostics = WindowsBridgeProcessDiagnostics();
    final lines = <String>[];
    final report = WindowsBusinessProcessReport((line) {
      lines.add(line);
      for (final byte in utf8.encode('$line\n')) {
        diagnostics.observeStderr([byte]);
      }
    });
    report.enter(FirstPartyBusinessStage.tlsConnect);
    report.primary(const HandshakeException('private certificate/path text'));
    report.enter(FirstPartyBusinessStage.connectionClose);
    report.cleanup(
        const ExternalNativeException(ExternalNativeFailure.commitUnknown));
    report.primary(StateError('later failure'));
    report.enter(FirstPartyBusinessStage.closed);
    final value = diagnostics.observation;
    expect(value.businessPrimary!.stage, FirstPartyBusinessStage.tlsConnect);
    expect(value.businessPrimary!.code,
        FirstPartyBusinessFailureCode.tlsHandshake);
    expect(value.businessCleanup!.code,
        FirstPartyBusinessFailureCode.nativeCommitUnknown);
    expect(value.businessStage, FirstPartyBusinessStage.closed);
    expect(value.exitCode, isNull);
    expect(value.primaryFailure, isNull);
    expect(lines.join(), isNot(contains('private')));
    expect(lines.join(), isNot(contains('later failure')));
    diagnostics.observeStderr(utf8.encode(
        '${WindowsBusinessProcessReport.marker}P|tlsConnect|notKnown\n'));
    expect(
        diagnostics.observation.businessPrimary, same(value.businessPrimary));
    expect(
        () => WindowsBusinessProcessReport((_) => throw StateError('sink'))
            .primary(StateError('source')),
        returnsNormally);
  });
  test(
      'pairing diagnostics accept only bounded fixed observations and retain first failures',
      () {
    final received = WindowsBridgeProcessDiagnostics();
    final emitted = <String>[];
    final report = WindowsPairingProcessReport((line) {
      emitted.add(line);
      final bytes = utf8.encode('$line\r\n');
      for (final byte in bytes) {
        received.observeStderr([byte]);
      }
    });
    report.enter(FirstPartyPairingStage.display);
    report.primary(pairingDiagnosticFailureCode(
        StateError('private body must never cross stderr')));
    report.primary(pairingDiagnosticFailureCode(
        const ExternalCredentialException(
            ExternalCredentialFailure.commitUnknown)));
    report.cleanup(pairingDiagnosticFailureCode(const ExternalNativeException(
        ExternalNativeFailure.temporarilyUnavailable)));
    report.cleanup(FirstPartyPairingFailureCode.unknown);
    report.enter(FirstPartyPairingStage.closed);
    final observation = received.observation;
    expect(observation.reportedStage, FirstPartyPairingStage.closed);
    expect(observation.primaryFailure!.stage, FirstPartyPairingStage.display);
    expect(
        observation.primaryFailure!.code, FirstPartyPairingFailureCode.unknown);
    expect(observation.cleanupFailure!.code,
        FirstPartyPairingFailureCode.unavailable);
    expect(observation.exitCode, isNull);
    expect(
        observation.parts.values
            .every((v) => v == FirstPartyObservedResult.unobserved),
        isTrue);
    expect(emitted.join(), isNot(contains('private body')));
    received.observeStderr(utf8.encode(
        'not-a-record\n${WindowsBridgeProcessDiagnostics.marker}P|display|notKnown\n'));
    expect(
        received.observation.primaryFailure, same(observation.primaryFailure));
    final limited = WindowsBridgeProcessDiagnostics();
    limited.observeStderr(
        List.filled(WindowsBridgeProcessDiagnostics.maxLine + 1, 65));
    limited.observeStderr(
        utf8.encode('${WindowsBridgeProcessDiagnostics.marker}S|closed\n'));
    expect(limited.observation.reportedStage, isNull);
    limited.observeStderr(
        List.filled(WindowsBridgeProcessDiagnostics.maxBytes, 0));
    limited.observeStderr(
        utf8.encode('${WindowsBridgeProcessDiagnostics.marker}S|closed\n'));
    expect(limited.observation.reportedStage, isNull);
    final records = WindowsBridgeProcessDiagnostics();
    for (var i = 0; i < WindowsBridgeProcessDiagnostics.maxRecords; i++) {
      records.observeStderr(utf8
          .encode('${WindowsBridgeProcessDiagnostics.marker}S|admission\n'));
    }
    records.observeStderr(
        utf8.encode('${WindowsBridgeProcessDiagnostics.marker}S|closed\n'));
    expect(records.observation.reportedStage, FirstPartyPairingStage.admission);
    expect(
        () => WindowsPairingProcessReport((_) => throw StateError('observer'))
            .primary(FirstPartyPairingFailureCode.unknown),
        returnsNormally);
  });
  test(
      'original process facts stay separate from reported success and failed drain',
      () async {
    final io = FakeBridgeProcessIo();
    final process = WindowsBridgeProcess(io: io);
    await process.start();
    final closing = expectLater(process.stopAndWait(), throwsStateError);
    io.child.exit.complete(19);
    io.child.drained.completeError(StateError('original stream failure'));
    await closing;
    expect(process.observation.exitCode, 19);
    expect(process.observation.parts[FirstPartyChildPart.exit],
        FirstPartyObservedResult.returned);
    expect(process.observation.parts[FirstPartyChildPart.settlement],
        FirstPartyObservedResult.failed);
    await expectLater(process.stopAndWait(), throwsStateError);
    expect(process.observation.exitCode, 19);
  });
  test('original stdin stdout stderr receipts remain independent', () async {
    final diagnostics = WindowsBridgeProcessDiagnostics();
    final output = Completer<void>();
    final error = Completer<void>();
    final input = Completer<void>();
    final out = diagnostics.track(FirstPartyChildPart.stdout, output.future);
    final err = expectLater(
        diagnostics.track(FirstPartyChildPart.stderr, error.future),
        throwsStateError);
    final entered = diagnostics.track(FirstPartyChildPart.stdin, input.future);
    output.complete();
    error.completeError(StateError('synthetic'));
    await out;
    await err;
    expect(diagnostics.observation.parts[FirstPartyChildPart.stdout],
        FirstPartyObservedResult.returned);
    expect(diagnostics.observation.parts[FirstPartyChildPart.stderr],
        FirstPartyObservedResult.failed);
    expect(diagnostics.observation.parts[FirstPartyChildPart.stdin],
        FirstPartyObservedResult.pending);
    input.complete();
    await entered;
    expect(diagnostics.observation.parts[FirstPartyChildPart.stdin],
        FirstPartyObservedResult.returned);
  });
  for (final failedClose in [false, true]) {
    test(
        'pairing display exception closes once and retains failed close=$failedClose',
        () async {
      final original = StateError('display failed');
      final release = Completer<void>();
      Object? first;
      var closes = 0, reads = 0;
      final monitor = DevelopmentPairingMonitor(
          pinSaved: () {
            reads++;
            throw original;
          },
          isCurrent: () => true,
          closeForBusiness: () async => fail('no successful Pin observation'),
          closeWindow: () {
            closes++;
            return release.future;
          },
          onFailure: (error) => first ??= error);
      final pending = monitor.tick();
      final observed =
          failedClose ? expectLater(pending, throwsStateError) : pending;
      await monitor.tick();
      expect(first, same(original));
      expect(closes, 1);
      expect(reads, 1);
      if (failedClose) {
        release.completeError(StateError('cleanup failed'));
      } else {
        release.complete();
      }
      await observed;
      await monitor.tick();
      expect(closes, 1);
    });
  }
  for (final (stage, error, code) in <(
    FirstPartyInitializationStage,
    Object,
    FirstPartyInitializationFailureCode
  )>[
    (
      FirstPartyInitializationStage.load,
      const ExternalNativeException(ExternalNativeFailure.libraryUnavailable),
      FirstPartyInitializationFailureCode.nativeLibraryUnavailable
    ),
    (
      FirstPartyInitializationStage.acquire,
      const ExternalNativeException(
          ExternalNativeFailure.temporarilyUnavailable),
      FirstPartyInitializationFailureCode.nativeTemporarilyUnavailable
    ),
    (
      FirstPartyInitializationStage.p25,
      const ExternalCredentialException(
          ExternalCredentialFailure.commitUnknown),
      FirstPartyInitializationFailureCode.credentialCommitUnknown
    ),
    (
      FirstPartyInitializationStage.postAdmission,
      StateError('no longer current'),
      FirstPartyInitializationFailureCode.unknown
    ),
    (
      FirstPartyInitializationStage.close,
      const ExternalNativeException(
          ExternalNativeFailure.temporarilyUnavailable),
      FirstPartyInitializationFailureCode.nativeTemporarilyUnavailable
    ),
  ]) {
    test('initialization diagnosis preserves ${stage.name} and original close',
        () {
      final operation = DevelopmentCredentialInitialization();
      final visited = <FirstPartyInitializationStage>[];
      var acquisitionUnsettled = false, ownerHeld = false;
      void visit(FirstPartyInitializationStage current) {
        visited.add(current);
        if (current == stage) throw error;
      }

      expect(
          () => operation.run(
              load: () => visit(FirstPartyInitializationStage.load),
              acquire: () {
                acquisitionUnsettled = true;
                visit(FirstPartyInitializationStage.acquire);
                ownerHeld = true;
                acquisitionUnsettled = false;
              },
              initializeP25: () {
                visit(FirstPartyInitializationStage.p25);
                return ExternalInitializationState.initialized;
              },
              postAdmission: () =>
                  visit(FirstPartyInitializationStage.postAdmission),
              close: () {
                expect(operation.observation.closeResult,
                    FirstPartyInitializationCloseResult.pending);
                visit(FirstPartyInitializationStage.close);
                ownerHeld = false;
              }),
          throwsA(same(error)));
      final observation = operation.observation;
      final acquired = stage.index >= FirstPartyInitializationStage.p25.index;
      expect(observation.ownerReturned, acquired);
      expect(
          acquisitionUnsettled, stage == FirstPartyInitializationStage.acquire);
      expect(ownerHeld, stage == FirstPartyInitializationStage.close);
      expect(
          visited
              .where((value) => value == FirstPartyInitializationStage.close),
          hasLength(acquired ? 1 : 0));
      expect(
          observation.closeResult,
          !acquired
              ? FirstPartyInitializationCloseResult.notAttempted
              : stage == FirstPartyInitializationStage.close
                  ? FirstPartyInitializationCloseResult.failed
                  : FirstPartyInitializationCloseResult.returned);
      final failure = stage == FirstPartyInitializationStage.close
          ? observation.cleanupFailure
          : observation.primaryFailure;
      expect(failure!.stage, stage);
      expect(failure.code, code);
      expect(
          stage == FirstPartyInitializationStage.close
              ? observation.primaryFailure
              : observation.cleanupFailure,
          isNull);
    });
  }

  test(
      'initialization diagnosis retains primary when original close also fails',
      () {
    final operation = DevelopmentCredentialInitialization();
    const primary =
        ExternalCredentialException(ExternalCredentialFailure.commitUnknown);
    const cleanup =
        ExternalNativeException(ExternalNativeFailure.temporarilyUnavailable);
    var closes = 0;
    expect(
        () => operation.run(
            load: () {},
            acquire: () {},
            initializeP25: () => throw primary,
            postAdmission: () => fail('post-admission must not run'),
            close: () {
              closes++;
              throw cleanup;
            }),
        throwsA(same(cleanup)));
    final observation = operation.observation;
    expect(closes, 1);
    expect(
        observation.primaryFailure!.stage, FirstPartyInitializationStage.p25);
    expect(observation.primaryFailure!.code,
        FirstPartyInitializationFailureCode.credentialCommitUnknown);
    expect(
        observation.cleanupFailure!.stage, FirstPartyInitializationStage.close);
    expect(observation.cleanupFailure!.code,
        FirstPartyInitializationFailureCode.nativeTemporarilyUnavailable);
    expect(observation.closeResult, FirstPartyInitializationCloseResult.failed);
  });

  for (final result in ExternalInitializationState.values) {
    test(
        'initialization diagnosis observes P25 ${result.name} without recovery',
        () {
      final operation = DevelopmentCredentialInitialization();
      var admitted = false, closes = 0;
      void run() => operation.run(
          load: () {},
          acquire: () {},
          initializeP25: () => result,
          postAdmission: () => admitted = true,
          close: () => closes++);
      if (result == ExternalInitializationState.incomplete) {
        expect(run, throwsStateError);
        expect(operation.observation.primaryFailure!.code,
            FirstPartyInitializationFailureCode.incompleteCredentials);
      } else {
        run();
        expect(operation.observation.primaryFailure, isNull);
      }
      expect(admitted, result != ExternalInitializationState.incomplete);
      expect(closes, 1);
      expect(operation.observation.ownerReturned, isTrue);
      expect(operation.observation.closeResult,
          FirstPartyInitializationCloseResult.returned);
      expect(operation.observation.cleanupFailure, isNull);
    });
  }

  final now = DateTime.utc(2026, 10, 26);
  WindowsDevelopmentBootstrap packet() => WindowsDevelopmentBootstrap(
      pairingUi: false,
      expiresAtUtcMs:
          now.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
      issuerDer: [1, 2, 3],
      installationId: '12345678-1234-4234-8234-123456789abc',
      serverLeafDigest: List.filled(32, 7),
      epoch: BigInt.one);

  test('development preface preserves a shared large MCP tail and split prefix',
      () async {
    final input = StreamController<List<int>>();
    final owner = WindowsBootstrapInput(input.stream, isCurrent: () => true);
    final bytes = packet().encode(now);
    final tail = List<int>.generate(150000, (i) => i % 256);
    input.add(bytes.sublist(0, 7));
    input.add([...bytes.sublist(7), ...tail]);
    final accepted = await owner.packet;
    accepted.requireCurrent(now, expectedPairingUi: false);
    final received = <int>[];
    final settled =
        owner.remainingStdin.listen(received.addAll).asFuture<void>();
    await input.close();
    await settled;
    await owner.close();
    expect(received, tail);
  });

  test('development preface requires integer version and closes original input',
      () async {
    final original = packet().encode(now);
    final value = jsonDecode(utf8.decode(original.sublist(12))) as List;
    value[0] = 1.0;
    final body = utf8.encode(jsonEncode(value));
    final changed = Uint8List(12 + body.length)..setRange(0, 8, original);
    ByteData.sublistView(changed).setUint32(8, body.length, Endian.little);
    changed.setRange(12, changed.length, body);
    var cancelled = false;
    final input = StreamController<List<int>>(onCancel: () => cancelled = true);
    final owner = WindowsBootstrapInput(input.stream, isCurrent: () => true);
    final rejected = expectLater(owner.packet, throwsStateError);
    input.add(changed);
    await rejected;
    await owner.close();
    expect(cancelled, isTrue);
    await input.close();
  });

  test('development preface rejects wrong scope expired grant and parent loss',
      () async {
    expect(() => packet().requireCurrent(now, expectedPairingUi: true),
        throwsStateError);
    expect(
        () => packet().requireCurrent(now.add(const Duration(minutes: 30)),
            expectedPairingUi: false),
        throwsStateError);
    final input = StreamController<List<int>>();
    final owner = WindowsBootstrapInput(input.stream, isCurrent: () => false);
    final rejected = expectLater(owner.packet, throwsStateError);
    input.add(packet().encode(now));
    await rejected;
    await owner.close();
    await input.close();
  });

  test(
      'App-owned admission refusal creates no child and later explicit grant can dispatch',
      () async {
    var dispatches = 0;
    Future<Map<String, Object?>> dispatch(
        WindowsDevelopmentBootstrap? value) async {
      dispatches++;
      expect(value, isNotNull);
      return {'admitted': true};
    }

    expect(
        (await dispatchWithAppOwnedBootstrap(
            requireBootstrap: true,
            snapshot: null,
            dispatch: dispatch))['error'],
        'unavailable');
    expect(
        (await dispatchWithAppOwnedBootstrap(
            requireBootstrap: true,
            snapshot: () => throw StateError('missing Pin'),
            dispatch: dispatch))['error'],
        'unavailable');
    expect(dispatches, 0);
    expect(
        (await dispatchWithAppOwnedBootstrap(
            requireBootstrap: true,
            snapshot: packet,
            dispatch: dispatch))['admitted'],
        isTrue);
    expect(dispatches, 1);
  });

  test('pairing preface EOF with live parent joins original P27 host close',
      () async {
    final h = PairingHarness();
    await h.open();
    final root = await Directory('.dart_tool').createTemp('pairing-eof-');
    final release = Completer<void>();
    var resourceCloses = 0, settled = false;
    final host = await BridgeUiHost.open(BridgeUiHostDependencies(
        pairing: h.bridge,
        instanceRoot: root.path,
        closeResources: () async {
          resourceCloses++;
          await release.future;
          await h.close();
        }));
    final input = StreamController<List<int>>();
    final owner = WindowsBootstrapInput(input.stream, isCurrent: () => true);
    input.add(packet().encode(now));
    await owner.packet;
    final closing =
        owner.watchControlLifetime(host.close).then((_) => settled = true);
    await input.close();
    await pumpEventQueue();
    expect(owner.isOpen, isFalse);
    expect(resourceCloses, 1);
    expect(settled, isFalse);
    release.complete();
    await closing;
    await owner.close();
    expect(settled, isTrue);
    expect(host.isClosed, isTrue);
    await deleteSettledTestDirectory(root, settled: closing);
  });

  for (final operation in [
    FirstPartyPairingStage.beginEnrollment,
    FirstPartyPairingStage.importTrust,
    FirstPartyPairingStage.confirmInitial,
    FirstPartyPairingStage.importCompletion,
    FirstPartyPairingStage.confirmCompletion,
    FirstPartyPairingStage.display,
  ]) {
    test(
        'original Bridge port observes ${operation.name} failure before UI withdrawal',
        () async {
      final h = PairingHarness();
      await h.open();
      final root =
          await Directory('.dart_tool').createTemp('pairing-observation-');
      final observations = <(FirstPartyPairingStage, Object?, bool)>[];
      final host = await BridgeUiHost.open(BridgeUiHostDependencies(
          pairing: h.bridge,
          instanceRoot: root.path,
          closeResources: h.close,
          onObservation: (stage, error, cleanup) {
            observations.add((stage, error, cleanup));
            // An observer failure must not replace the original port result.
            if (error == null) throw StateError('observation only');
          }));
      addTearDown(() async {
        final closing = host.close();
        await closing;
        await deleteSettledTestDirectory(root, settled: closing);
      });
      Future<void> invoke() async {
        switch (operation) {
          case FirstPartyPairingStage.beginEnrollment:
            host.port.beginEnrollment(
                displayLabel: List.filled(65, 'a').join(),
                clientBuild: 'offline');
          case FirstPartyPairingStage.importTrust:
            await host.port.importTrust('invalid public input');
          case FirstPartyPairingStage.confirmInitial:
            host.port.confirmInitial('unconfirmed');
          case FirstPartyPairingStage.importCompletion:
            await host.port.importCompletion('invalid public input');
          case FirstPartyPairingStage.confirmCompletion:
            host.port.confirmCompletion('unconfirmed', 1);
          case FirstPartyPairingStage.display:
            h.current = false;
            host.port.display();
          default:
            fail('not an operation');
        }
      }

      await expectLater(invoke(), throwsA(anything));
      final first = observations.firstWhere((event) => event.$2 != null);
      expect(first.$1, operation);
      expect(first.$3, isFalse);
      await host.close();
      expect(observations.last.$1,
          FirstPartyPairingStage.closedWithoutPinObservation);
      expect(observations.where((event) => event.$3), isEmpty);
      expect(host.isClosed, isTrue);
    });
  }

  testWidgets(
      'pairing failure surface cancels repeated normal exit after failed custody',
      (tester) async {
    final close = Completer<void>();
    await tester.pumpWidget(buildDevelopmentPairingFailure(() => close.future));
    var finished = false;
    final first = tester.binding.handleRequestAppExit().then((value) {
      finished = true;
      return value;
    });
    await tester.pump();
    expect(finished, isFalse);
    close.completeError(StateError('unsettled owner'));
    await tester.pump();
    expect(await first, AppExitResponse.cancel);
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
  });
  testWidgets(
      'clean pairing refusal allows normal exit after original settlement',
      (tester) async {
    final close = Completer<void>();
    await tester.pumpWidget(buildDevelopmentPairingFailure(() => close.future));
    var finished = false;
    final exit = tester.binding.handleRequestAppExit().then((value) {
      finished = true;
      return value;
    });
    await tester.pump();
    expect(finished, isFalse);
    close.complete();
    await tester.pump();
    expect(await exit, AppExitResponse.exit);
  });
}
