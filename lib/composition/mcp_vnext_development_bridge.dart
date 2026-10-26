import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../application/external/first_party_development_access.dart';
import '../data/external/discovery_descriptor_codec.dart';
import '../data/external/windows_codex_client.dart';
import '../data/external/windows_development_admission.dart';
import '../data/external/windows_development_bootstrap.dart';
import '../data/external/windows_local_relay.dart';
import '../data/external/windows_process_observation.dart';
import 'mcp_vnext_windows_acquisition.dart';
import 'mcp_vnext_windows_bootstrap.dart';

DiscoveryExpectations developmentDiscoveryExpectations(
        WindowsDevelopmentBootstrap packet) =>
    DiscoveryExpectations(
        trustedAnchorDer: packet.issuerDer,
        installationId: packet.installationId,
        serverLeafDigest: packet.serverLeafDigest,
        // This root has no independent historical Bridge-pin observation. The
        // original Reader still enforces/advances its persisted Pin; Bootstrap
        // separately binds the result to the exact current App publication.
        verifiedEpochHighWater: BigInt.zero);

/// Fixed formal Bridge entry. A Direct/Hosted caller has no accepted App parent
/// and retains normal seven-tool refusal, without consuming any startup bytes.
Future<void> serveDevelopmentWindowsBridge() async {
  final report = WindowsBusinessProcessReport(stderr.writeln);
  unawaited(stderr.done.then((_) {}, onError: (Object _, StackTrace __) {}));
  report.enter(FirstPartyBusinessStage.parentAdmission);
  WindowsDevelopmentAdmission admission;
  try {
    admission = await WindowsDevelopmentAdmission.receive(pairingUi: false);
  } on LocalRelayException catch (failure) {
    report.primary(failure);
    if (failure.unsettled) rethrow;
    await serveWindowsBridgeStdio();
    return;
  } catch (error) {
    report.primary(error);
    rethrow;
  }
  final clock = Stopwatch()..start();
  final random = Random.secure();
  final packet = admission.packet;
  final bootstrap = McpVnextWindowsBridgeBootstrap(
      acquirer: McpVnextWindowsProtectedAcquirer(
          utcNow: () => DateTime.now().toUtc(),
          monotonicNow: () => clock.elapsed,
          compositionIsCurrent: () => admission.isCurrent,
          randomBytes: (count) => Uint8List.fromList(
              List<int>.generate(count, (_) => random.nextInt(256)))),
      requireSecurityAdmission: () async => admission.requireCurrent(),
      independentTrust: () async {
        admission.requireCurrent();
        return developmentDiscoveryExpectations(packet);
      },
      process: McpVnextWindowsStdioCustody(stdout),
      connectionMode: WindowsCodexConnectionMode.appOwnedDevelopment,
      appOwnedAdmission: admission,
      report: report,
      enableStageApprovalWait: true);
  final monitor = Timer.periodic(const Duration(milliseconds: 50), (_) {
    if (!admission.isCurrent) {
      unawaited(bootstrap
          .close()
          .then((_) {}, onError: (Object _, StackTrace __) {}));
      unawaited(admission
          .close()
          .then((_) {}, onError: (Object _, StackTrace __) {}));
    }
  });
  try {
    await bootstrap.serveStdio(input: admission.input.remainingStdin);
  } catch (error) {
    report.primary(error);
    rethrow;
  } finally {
    monitor.cancel();
    report.enter(FirstPartyBusinessStage.closing);
    try {
      await bootstrap.close();
      await admission.close();
      report.enter(FirstPartyBusinessStage.closed);
    } catch (error) {
      report.cleanup(error);
      rethrow;
    }
  }
}
