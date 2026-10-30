/// Explicit trusted composition. No external selector or admission provider.
library;

import 'dart:async';
import 'dart:io';

import '../application/external/first_party_development_access.dart';
import '../data/external/discovery_descriptor_codec.dart';
import '../data/external/windows_discovery.dart';
import '../data/external/windows_codex_client.dart';
import '../data/external/windows_tls_transport.dart';
import '../data/external/windows_development_admission.dart';
import '../data/external/windows_process_observation.dart';
import '../mcp/vnext_mcp_entrypoint.dart';
import '../mcp/vnext_mcp_server.dart';
import 'mcp_vnext_windows_acquisition.dart';
import 'mcp_vnext_windows_startup.dart';

/// The client owns this process's exit and pipes. Inside that process the
/// original server closes input admission, then this barrier flushes output.
/// It never waits for its own OS exit or launches/owns a second process.
final class McpVnextWindowsStdioCustody implements McpVnextWindowsProcessOwner {
  McpVnextWindowsStdioCustody(this.output);
  final IOSink output;
  Future<void>? _closing;
  @override
  Future<void> stopAndWait() => _closing ??= output.flush();
}

/// A complete Bridge business assembly, callable only by trusted product code.
/// [requireSecurityAdmission] must enforce a separately approved deployment;
/// it is not authentication and cannot replace P26, P15/P0 or P8/P10 checks.
/// There is deliberately no default admission or independent-trust supplier.
final class McpVnextWindowsBridgeBootstrap implements VnextMcpPort {
  McpVnextWindowsBridgeBootstrap({
    required McpVnextWindowsProtectedAcquirer acquirer,
    required Future<void> Function() requireSecurityAdmission,
    required Future<DiscoveryExpectations> Function() independentTrust,
    required McpVnextWindowsProcessOwner process,
    required WindowsCodexConnectionMode connectionMode,
    WindowsCodexClientSelection? clientSelection,
    WindowsDevelopmentAdmission? appOwnedAdmission,
    Future<void> Function()? settlePairing,
    TlsBridgeIo Function()? createIo,
    bool enableStageApprovalWait = false,
    this.profileVersion = 2,
    WindowsBusinessProcessReport? report,
  }) : _acquirer = acquirer {
    _startup = McpVnextWindowsBridgeStartup(
      profileVersion: profileVersion,
      enableStageApprovalWait: enableStageApprovalWait,
      report: report,
      acquire: () async {
        if (connectionMode == WindowsCodexConnectionMode.appOwnedDevelopment) {
          if (clientSelection != null || appOwnedAdmission == null) {
            throw StateError('App-owned admission unavailable');
          }
          appOwnedAdmission.claimBusiness();
        } else {
          if (clientSelection == null || appOwnedAdmission != null) {
            throw StateError('Codex client unsupported');
          }
          await clientSelection.claim(connectionMode);
        }
        _checkCurrent();
        report?.enter(FirstPartyBusinessStage.securityAdmission);
        await requireSecurityAdmission();
        _checkCurrent();
        report?.enter(FirstPartyBusinessStage.independentTrust);
        final trusted = await independentTrust();
        _checkCurrent();
        // Same-process handoff joins the original controller/Owner/host lock.
        // Across processes native client.lock remains the sole exclusion.
        await settlePairing?.call();
        _checkCurrent();
        report?.enter(FirstPartyBusinessStage.acquire);
        final d = await acquirer.acquireBridgeRuntime(
            trusted: trusted, process: process, createIo: createIo);
        _pending = d;
        try {
          _checkCurrent();
          // Fail before exposing a business port on missing credentials, stale
          // trust or invalid Discovery. Reuse the original P26 verification/CAS.
          report?.enter(FirstPartyBusinessStage.bootstrapDiscovery);
          final descriptor = WindowsDiscoveryReader(d.owner, verifier: (
              {required publicPoint, required digest, required rawSignature}) {
            d.verifyDigest(
                publicPoint: publicPoint,
                digest: digest,
                rawSignature: rawSignature);
            return true;
          }).readAndAdvanceExistingPin(d.trusted);
          appOwnedAdmission?.packet
              .requireCurrentPublication(descriptor.publicationEpoch);
          _pending = null;
          return d;
        } catch (_) {
          // Acquisition already transferred custody to us. Startup has not yet
          // received it. Failed process settlement retains this exact Owner.
          try {
            await d.process.stopAndWait();
            d.owner.close();
            _pending = null;
          } catch (_) {
            d.owner.rejectRuntimeReuse();
            rethrow;
          }
          rethrow;
        }
      },
    );
  }

  late final McpVnextWindowsBridgeStartup _startup;
  final McpVnextWindowsProtectedAcquirer _acquirer;
  final int profileVersion;
  Future<void>? _closing;
  // Strong custody on failed pre-transfer settlement; never a retry source.
  McpVnextWindowsBridgeDependencies? _pending;
  bool _closed = false;
  void _checkCurrent() {
    if (_closed || _pending?.owner.runtimeClaimed == true) {
      throw StateError('Windows bootstrap unavailable');
    }
  }

  Future<void> start() => _startup.start();

  Future<void> serveStdio({Stdin? input}) async {
    try {
      await start();
      await VnextMcpServer(this, profileVersion: profileVersion)
          .serveStdio(input: input);
    } finally {
      await close();
    }
  }

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
          {required Stream<void> cancelled,
          required bool Function() available}) =>
      _startup.call(tool, arguments,
          cancelled: cancelled, available: () => !_closed && available());

  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      await _startup.close();
      await _acquirer.whenAcquisitionSettled;
      if (_pending != null) throw StateError('Windows bootstrap unsettled');
    }();
  }
}

/// Shared executable entry. The formal AOT supplies no admitted composition.
/// Only a different, explicitly admitted product root may pass a bootstrap;
/// CLI/environment/MCP input never resolves one.
Future<void> serveWindowsBridgeStdio(
        {McpVnextWindowsBridgeBootstrap? bootstrap, int profileVersion = 2}) =>
    bootstrap == null
        ? VnextMcpServer(UnavailableVnextApp(profileVersion: profileVersion),
                profileVersion: profileVersion)
            .serveStdio()
        : bootstrap.serveStdio();
