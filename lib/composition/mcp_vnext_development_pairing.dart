import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitType, AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/app_data_paths.dart';
import '../application/external/first_party_development_access.dart';
import '../application/external/external_credential_association.dart';
import '../data/external/native/windows_external_native.dart';
import '../data/external/external_credential_object_codec.dart';
import '../data/external/windows_credential_object_store.dart';
import '../data/external/windows_development_admission.dart';
import '../data/external/windows_exchange_file_store.dart';
import '../data/external/windows_pairing.dart';
import '../data/external/windows_tls_transport.dart';
import '../data/external/windows_discovery.dart';
import '../data/external/windows_process_observation.dart';
import 'mcp_vnext_development_bridge.dart';
import 'bridge_ui_host.dart';

/// Closed local error projection. The process observer imports no Native API.
FirstPartyPairingFailureCode pairingDiagnosticFailureCode(Object error) {
  if (error is ExternalNativeException) {
    return switch (error.failure) {
      ExternalNativeFailure.invalidInput =>
        FirstPartyPairingFailureCode.invalidInput,
      ExternalNativeFailure.dataCorrupt => FirstPartyPairingFailureCode.corrupt,
      ExternalNativeFailure.commitUnknown =>
        FirstPartyPairingFailureCode.commitUnknown,
      ExternalNativeFailure.verificationRejected =>
        FirstPartyPairingFailureCode.verificationRejected,
      ExternalNativeFailure.resourceLimit =>
        FirstPartyPairingFailureCode.resourceLimit,
      _ => FirstPartyPairingFailureCode.unavailable,
    };
  }
  if (error is ExternalCredentialException) {
    return switch (error.failure) {
      ExternalCredentialFailure.invalidInput =>
        FirstPartyPairingFailureCode.invalidInput,
      ExternalCredentialFailure.dataCorrupt =>
        FirstPartyPairingFailureCode.corrupt,
      ExternalCredentialFailure.commitUnknown =>
        FirstPartyPairingFailureCode.commitUnknown,
      ExternalCredentialFailure.verificationRejected =>
        FirstPartyPairingFailureCode.verificationRejected,
      ExternalCredentialFailure.resourceLimit =>
        FirstPartyPairingFailureCode.resourceLimit,
      ExternalCredentialFailure.conflict ||
      ExternalCredentialFailure.staleRevision =>
        FirstPartyPairingFailureCode.conflict,
      _ => FirstPartyPairingFailureCode.unavailable,
    };
  }
  if (error is ExternalExchangeException) {
    return switch (error.failure) {
      ExternalExchangeFailure.invalidInput =>
        FirstPartyPairingFailureCode.invalidInput,
      ExternalExchangeFailure.dataCorrupt =>
        FirstPartyPairingFailureCode.corrupt,
      ExternalExchangeFailure.temporarilyUnavailable =>
        FirstPartyPairingFailureCode.unavailable,
      ExternalExchangeFailure.commitUnknown =>
        FirstPartyPairingFailureCode.commitUnknown,
    };
  }
  return FirstPartyPairingFailureCode.unknown;
}

/// The timer owns observation only. Any thrown display/expiry/completion check
/// enters the same original close barrier exactly once; it never retries P27.
final class DevelopmentPairingMonitor {
  DevelopmentPairingMonitor(
      {required this.pinSaved,
      required this.isCurrent,
      required this.closeForBusiness,
      required this.closeWindow,
      required this.onFailure});
  final bool Function() pinSaved, isCurrent;
  final Future<void> Function() closeForBusiness, closeWindow;
  final void Function(Object) onFailure;
  bool _busy = false, _finished = false;
  Future<void> tick() async {
    if (_busy || _finished) return;
    _busy = true;
    try {
      final saved = pinSaved();
      if (!saved && isCurrent()) return;
      _finished = true;
      if (saved) await closeForBusiness();
    } catch (error) {
      _finished = true;
      try {
        onFailure(error);
      } catch (_) {/* Observation only. */}
    } finally {
      _busy = false;
    }
    await closeWindow();
  }
}

/// The normal Flutter executable's fixed independent Bridge UI root. It never
/// enters App database/provider/logger/relay/Host composition. The flag selects
/// this surface only; the native original-parent check and preface admit work.
Future<void> runDevelopmentBridgePairing() async {
  WidgetsFlutterBinding.ensureInitialized();
  final report = WindowsPairingProcessReport(stderr.writeln);
  unawaited(stderr.done.then((_) {}, onError: (Object _, StackTrace __) {}));
  report.enter(FirstPartyPairingStage.admission);
  WindowsDevelopmentAdmission? admission;
  ExternalProtectedObjects? owner;
  BridgeUiHost? host;
  FirstPartyPairingStage? hostTerminal;
  WindowsTlsBridge? proof;
  Timer? monitor;
  bool closing = false;
  bool acquiring = false;
  Future<void>? settlement;
  Future<void> settle() => settlement ??= () async {
        monitor?.cancel();
        report.enter(FirstPartyPairingStage.closing);
        try {
          await proof?.close();
          if (host != null) {
            await host.close();
          } else {
            if (acquiring) throw StateError('Bridge acquisition unsettled');
            owner?.close();
            await admission?.close();
          }
          report.enter(host == null
              ? FirstPartyPairingStage.closed
              : hostTerminal ??
                  FirstPartyPairingStage.closedWithoutPinObservation);
        } catch (error) {
          report.cleanup(pairingDiagnosticFailureCode(error));
          rethrow;
        }
      }();
  Future<void> closeWindow() async {
    if (closing) return;
    closing = true;
    try {
      await settle();
      await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
    } catch (error) {
      report.cleanup(pairingDiagnosticFailureCode(error));
      runApp(_PairingFailureSurface(close: settle));
    }
  }

  try {
    if (!kDebugMode || !Platform.isWindows) {
      throw StateError('Development pairing unavailable');
    }
    final admitted =
        admission = await WindowsDevelopmentAdmission.receive(pairingUi: true);
    admitted.requireCurrent();
    final native = WindowsExternalNative.open();
    report.enter(FirstPartyPairingStage.acquire);
    acquiring = true;
    final acquired = owner = native.acquireBridgeObjects();
    acquiring = false;
    final store = WindowsCredentialObjectStore(acquired);
    report.enter(FirstPartyPairingStage.credentialRead);
    final existing = store.read(4);
    if (existing != null) {
      if (existing is! ExternalBridgeClient) {
        throw StateError('Existing Bridge credential unavailable');
      }
      existing.clientPkcs8Der.fillRange(0, existing.clientPkcs8Der.length, 0);
      // Original kind 4, P26 and mTLS only. There is no enrollment or P9 request.
      final crypto = native.crypto;
      final connection = proof = WindowsTlsBridge(
          report: WindowsBusinessProcessReport(stderr.writeln),
          io: const DartLoopbackBridgeIo(),
          reader: WindowsDiscoveryReader(acquired, verifier: (
              {required publicPoint, required digest, required rawSignature}) {
            crypto.verifyDigest(
                publicPoint: publicPoint,
                digest: digest,
                rawSignature: rawSignature);
            return true;
          }),
          trusted: developmentDiscoveryExpectations(admitted.packet),
          requirePublication: admitted.packet.requireCurrentPublication,
          owner: acquired,
          signDigest: crypto.signDigest,
          verifyDigest: crypto.verifyDigest,
          nativePolicy: native.peerCertificatePolicy.check,
          utcNow: () => DateTime.now().toUtc(),
          compositionIsCurrent: () => admitted.isCurrent);
      runApp(_PairingFailureSurface(
          close: settle,
          message: '正在验证已保存的 Bridge 身份。请回到 App 核对本次身份并确认。'
              '本窗口不发送业务请求，也不会重新配对或保存凭据。'));
      unawaited(admitted.input
          .watchControlLifetime(closeWindow)
          .then((_) {}, onError: (Object _, StackTrace __) {}));
      monitor = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!admitted.isCurrent && !closing) unawaited(closeWindow());
      });
      report.enter(FirstPartyPairingStage.proofConnect);
      await connection.connect();
      report.enter(FirstPartyPairingStage.proofWait);
      await connection.waitForProofClosure();
      await closeWindow();
      return;
    }
    final elapsed = Stopwatch()..start();
    report.enter(FirstPartyPairingStage.enrollment);
    final pairing = WindowsBridgePairing(
        exchange: WindowsExchangeFileStore(acquired),
        store: store,
        crypto: native.crypto,
        utcNow: () => DateTime.now().toUtc(),
        monotonicNow: () => elapsed.elapsed,
        compositionIsCurrent: () => admitted.isCurrent);
    final paths = AppDataPaths.fromApplicationSupportDirectory(
        await getApplicationSupportDirectory(),
        environment: AppDataEnvironment.development);
    final uiRoot = Directory(p.join(paths.runtimeRoot, 'bridge-pairing-ui'));
    await uiRoot.create(recursive: true);
    admitted.requireCurrent();
    final opened = host = await BridgeUiHost.open(BridgeUiHostDependencies(
        pairing: pairing,
        instanceRoot: uiRoot.path,
        onObservation: (stage, error, cleanup) {
          if (error == null) {
            if (stage == FirstPartyPairingStage.closed ||
                stage == FirstPartyPairingStage.closedWithoutPinObservation) {
              hostTerminal = stage;
            }
            report.enter(stage);
          } else if (cleanup) {
            report.cleanup(pairingDiagnosticFailureCode(error));
          } else {
            report.enter(stage);
            report.primary(pairingDiagnosticFailureCode(error));
          }
        },
        closeResources: () async {
          pairing.close();
          acquired.close();
          await admitted.close();
        }));
    report.enter(FirstPartyPairingStage.uiOpen);
    runApp(opened.build());
    unawaited(admitted.input.watchControlLifetime(closeWindow).then((_) {},
        onError: (Object _, StackTrace __) {
      // Input failure closes the SAME original host; cleanup failure stays latched.
    }));
    final observation = DevelopmentPairingMonitor(
        pinSaved: () {
          if (report.stage != FirstPartyPairingStage.display) {
            report.enter(FirstPartyPairingStage.display);
          }
          return opened.port.display().pinSaved;
        },
        isCurrent: () => admitted.isCurrent,
        closeForBusiness: () async {
          report.enter(FirstPartyPairingStage.pinObserved);
          await opened.closeForBusiness();
        },
        closeWindow: closeWindow,
        onFailure: (error) =>
            report.primary(pairingDiagnosticFailureCode(error)));
    monitor = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!closing) {
        unawaited(observation.tick().then((_) {},
            onError: (Object error, StackTrace _) {
          report.cleanup(pairingDiagnosticFailureCode(error));
          runApp(_PairingFailureSurface(close: settle));
        }));
      }
    });
  } catch (error) {
    report.primary(pairingDiagnosticFailureCode(error));
    monitor?.cancel();
    var cleanRefusal = false;
    try {
      await settle();
      cleanRefusal = true;
    } catch (_) {/* Same failed future remains the exit barrier. */}
    runApp(_PairingFailureSurface(close: settle));
    if (cleanRefusal) {
      // Parent EOF can arrive before a window/Owner exists. A clean refusal
      // must leave by the normal Flutter exit path instead of making that live
      // parent wait for a user to close an otherwise idle error window.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(closeWindow());
      });
    }
  }
}

Widget buildDevelopmentPairingFailure(Future<void> Function() close) =>
    _PairingFailureSurface(close: close);

final class _PairingFailureSurface extends StatefulWidget {
  const _PairingFailureSurface(
      {required this.close,
      this.message = 'Bridge 配对不可用。现有、损坏或未确认的凭据不会被替换。'
          '若原资源关闭未确认，窗口将保留并拒绝正常退出。'});
  final Future<void> Function() close;
  final String message;
  @override
  State<_PairingFailureSurface> createState() => _PairingFailureSurfaceState();
}

final class _PairingFailureSurfaceState extends State<_PairingFailureSurface> {
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: () async {
      try {
        await widget.close();
        return AppExitResponse.exit;
      } catch (_) {
        return AppExitResponse.cancel;
      }
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      MaterialApp(home: Scaffold(body: Center(child: Text(widget.message))));
}
