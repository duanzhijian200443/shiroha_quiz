/// Dormant trusted composition only. No normal App or standalone consumer.
library;

import 'dart:async';
import 'dart:typed_data';

import '../application/external/external_credential_boundary.dart';
import '../application/external/external_trust_core.dart';
import '../application/external/first_party_external_credentials.dart';
import '../application/external/local_host_dispatch.dart';
import '../data/external/discovery_descriptor_codec.dart';
import '../data/external/native/windows_external_native.dart';
import '../data/external/native/windows_peer_certificate_policy.dart';
import '../data/external/windows_credential_association_store.dart';
import '../data/external/windows_credential_initialization.dart';
import '../data/external/windows_bridge_process.dart';
import '../data/external/windows_discovery.dart';
import '../data/external/windows_exchange_file_store.dart';
import '../data/external/windows_pairing.dart';
import '../data/external/windows_tls_transport.dart';
import '../mcp/vnext_mcp_server.dart';
import 'mcp_vnext_app_integration.dart';
import 'mcp_vnext_windows_bridge.dart';
import 'mcp_vnext_windows_transport.dart';

export '../data/external/windows_bridge_process.dart'
    show McpVnextWindowsProcessOwner;

typedef McpVnextWindowsLocalConnection = ({
  TlsChannel channel,
  TlsContextPlan plan,
});

/// One transferred, already acquired App Owner and its original protected stores.
/// Acquisition/launch/protected access require separate existing admission; an
/// acquire callback is not an admission grant. It must settle partial acquisition
/// itself if it throws before returning this bundle. No request/JSON/env inputs.
final class McpVnextWindowsAppDependencies {
  const McpVnextWindowsAppDependencies({
    required this.owner,
    required this.credentials,
    required this.associations,
    required this.exchange,
    required this.pairingVerification,
    required this.signDigest,
    required this.verifyDigest,
    required this.nativePolicy,
    required this.clock,
    required this.utcNow,
    required this.monotonicNow,
    required this.randomBytes,
    required this.compositionIsCurrent,
    required this.readiness,
    required this.listener,
    required this.port,
    required this.pairing,
    required this.openLocalConnection,
    required this.closeLocalConnections,
    required this.process,
  });
  final ExternalProtectedObjects owner;
  final WindowsCredentialInitialization credentials;
  final WindowsCredentialAssociationStore associations;
  final WindowsExchangeFileStore exchange;
  final WindowsPairingVerification pairingVerification;
  final CredentialDigestSigner signDigest;
  final CredentialDigestVerifier verifyDigest;
  final void Function(Uint8List, TlsPeerRole) nativePolicy;
  final ExternalClock clock;
  final DateTime Function() utcNow;
  final Duration Function() monotonicNow;
  final Uint8List Function(int) randomBytes;
  final bool Function() compositionIsCurrent;
  final LocalHostReadinessPort readiness;
  final TlsListenerIo listener;
  final int port;
  final FirstPartyPairingPort Function(WindowsAppPairing) pairing;
  final Future<McpVnextWindowsLocalConnection> Function() openLocalConnection;

  /// Close ALL original raw/connecting/authentication channels and plans. This
  /// callback must also interrupt pending opens and await their real settlement.
  final Future<void> Function() closeLocalConnections;
  final McpVnextWindowsProcessOwner process;
}

/// Minimal wiring over the App's original P0/P15/P8 graph and owned TLS Host.
/// Construction captures callbacks only. Explicit start has no default acquirer;
/// real acquisition, process launch and listener use remain independently gated.
final class McpVnextWindowsAppStartup {
  McpVnextWindowsAppStartup({
    required this.integration,
    required Future<McpVnextWindowsAppDependencies> Function() acquire,
    this.enableStageApprovalWait = false,
  }) : _acquire = acquire;

  final McpVnextAppIntegration integration;
  final Future<McpVnextWindowsAppDependencies> Function() _acquire;
  final bool enableStageApprovalWait;
  McpVnextWindowsAppDependencies? _dependencies;
  // A rejected borrowed bundle remains with its original owner; never close it.
  McpVnextWindowsAppDependencies? _rejectedDependencies;
  WindowsChannelVerification? _channels;
  WindowsAppPairing? _pairing;
  WindowsTlsHost? _host;
  Future<VnextMcpPort>? _starting;
  Future<void>? _closing, _settling, _auxiliaryClosing;
  bool _stopped = false;
  bool _attaching = false;
  int _localPending = 0;
  Completer<void>? _localIdle;

  /// Read-only lifecycle observation; never an identity/approval capability.
  WindowsTlsHost? get host => _host;
  bool get _current =>
      !_stopped &&
      integration.controls.isCurrent &&
      _processCurrent(_dependencies?.process) &&
      _dependencies?.compositionIsCurrent() == true;

  Future<VnextMcpPort> start() {
    if (_starting != null || _stopped) {
      throw StateError('Windows MCP startup unavailable');
    }
    return _starting = _start();
  }

  Future<VnextMcpPort> _start() async {
    try {
      if (integration.hasAttachment) {
        throw StateError('Windows MCP startup unavailable');
      }
      final d = await _acquire();
      if (d.owner.runtimeClaimed ||
          !d.owner.isAppOwner ||
          !d.credentials.usesOwner(d.owner) ||
          !d.associations.usesOwner(d.owner) ||
          !d.exchange.usesOwner(d.owner)) {
        _rejectedDependencies = d;
        throw StateError('Windows MCP startup unavailable');
      }
      _dependencies = d;
      _observeProcess(d.process, close);
      if (!_current) {
        throw StateError('Windows MCP startup unavailable');
      }
      // Existing-only validation: never initialize, repair, rekey or recover.
      final material = d.credentials.validatedPublicMaterial();
      if (integration.hasAttachment) {
        throw StateError('Windows MCP startup unavailable');
      }
      _attaching = true;
      final result = await integration.attachCredentials(
        associations: d.associations,
        verification: (management) => _channels = WindowsChannelVerification(
          pairing: d.pairingVerification,
          associations: d.associations,
          management: management,
          nativePolicy: d.nativePolicy,
          verifyDigest: d.verifyDigest,
          utcNow: d.utcNow,
          monotonicNow: d.monotonicNow,
          compositionIsCurrent: () => _current,
        ),
        clock: d.clock,
        installationId: material.installationId,
        readiness: d.readiness,
        monotonicNow: d.monotonicNow,
        enableStageApprovalWait: enableStageApprovalWait,
        services: (boundary) {
          _channels!.attach(boundary);
          final pairing = _pairing = WindowsAppPairing.withPrimitives(
            exchange: d.exchange,
            credentials: d.credentials,
            boundary: boundary,
            associations: d.associations,
            verification: d.pairingVerification,
            utcNow: d.utcNow,
            monotonicNow: d.monotonicNow,
            compositionIsCurrent: () => _current,
            randomBytes: d.randomBytes,
          );
          return FirstPartyCredentialServices(
            boundary: boundary,
            pairing: d.pairing(pairing),
            openConnection: (_) => _authenticateLocal(),
            close: _closeAuxiliary,
          );
        },
        transport: (coordinator, binding) {
          final startup = P26TlsStartup(
            owner: d.owner,
            credentials: d.credentials,
            publisher: WindowsDiscoveryPublisher(
                owner: d.owner, credentials: d.credentials),
            runtimeInstanceId: _pairing!.runtimeInstanceId,
            generation:
                BigInt.from(binding.stages.runtimeAdmission.trust.generation),
            signDigest: d.signDigest,
            verifyDigest: d.verifyDigest,
            utcNow: d.utcNow,
            compositionIsCurrent: () => _current,
          );
          final host = _host = WindowsTlsHost.owned(
            owner: d.owner,
            pairing: _pairing!,
            associations: d.associations,
            boundary: binding.stages.runtimeAdmission.trust.credentials
                as ExternalCredentialBoundary,
            coordinator: coordinator,
            startup: startup,
            verification: _channels!,
            io: d.listener,
            port: d.port,
            binding: binding,
            enableStageApprovalWait: enableStageApprovalWait,
            monotonicNow: d.monotonicNow,
            closeLocalConnections: _closeAuxiliary,
          );
          return McpVnextWindowsTransport(binding: binding, transport: host);
        },
      );
      if (!_current) throw StateError('Windows MCP startup unavailable');
      return result;
    } catch (_) {
      _stopped = true;
      await _settle();
      throw StateError('Windows MCP startup unavailable');
    }
  }

  Future<FirstPartyCredentialConnection> _authenticateLocal() async {
    if (!_current || _auxiliaryClosing != null) {
      throw StateError('Windows MCP authentication unavailable');
    }
    if (_localPending++ == 0) _localIdle = Completer<void>();
    try {
      final connection = await _dependencies!.openLocalConnection();
      if (!_current || _auxiliaryClosing != null) {
        throw StateError('Windows MCP authentication unavailable');
      }
      return (await _channels!
              .authenticate(connection.channel, connection.plan))
          .firstPartyConnection;
    } finally {
      if (--_localPending == 0) _localIdle!.complete();
    }
  }

  Future<void> _closeAuxiliary() => _auxiliaryClosing ??= () async {
        final d = _dependencies;
        if (d == null) return;
        _channels?.close();
        // Invoke cancellation before waiting for an open/authentication operation.
        // Future.wait joins every original operation even when another one fails.
        await Future.wait([
          Future<void>.sync(d.closeLocalConnections),
          if (_localPending != 0) _localIdle!.future,
          Future<void>.sync(d.process.stopAndWait),
        ]);
      }();

  Future<void> _settle() => _settling ??= () async {
        if (_rejectedDependencies != null) return;
        final d = _dependencies;
        try {
          await Future.wait([
            if (_attaching) integration.close(),
            if (_host != null) _host!.shutdown(),
            if (_pairing != null) _pairing!.close(),
            _closeAuxiliary(),
          ]);
          // Once transferred, the SAME Host is the sole Store/Owner closer.
          if (_host == null && d != null) {
            if (d.associations.usesOwner(d.owner)) await d.associations.close();
            d.owner.close();
          }
        } catch (_) {
          // A pre-Host failure must not let another Runtime adopt the retained
          // Owner while local/process cleanup remains unknown.
          d?.owner.rejectRuntimeReuse();
          rethrow;
        }
      }();

  /// Close admission now, then join pending acquisition/start and real drain.
  /// Failure is latched; uncertain Owners are retained, never retried/released.
  Future<void> close() {
    _stopped = true;
    return _closing ??= () async {
      await Future.wait([
        if (_attaching) integration.close(),
        () async {
          try {
            await _starting;
          } catch (_) {/* Startup already joined its original cleanup. */}
          await _settle();
        }(),
      ]);
    }();
  }
}

/// One transferred Bridge credential/Discovery Owner. No App business objects.
final class McpVnextWindowsBridgeDependencies {
  const McpVnextWindowsBridgeDependencies({
    required this.owner,
    required this.trusted,
    required this.createIo,
    required this.signDigest,
    required this.verifyDigest,
    required this.nativePolicy,
    required this.utcNow,
    required this.monotonicNow,
    required this.compositionIsCurrent,
    required this.process,
  });
  final ExternalProtectedObjects owner;
  final DiscoveryExpectations trusted;
  final TlsBridgeIo Function() createIo;
  final CredentialDigestSigner signDigest;
  final CredentialDigestVerifier verifyDigest;
  final void Function(Uint8List, TlsPeerRole) nativePolicy;
  final DateTime Function() utcNow;
  final Duration Function() monotonicNow;
  final bool Function() compositionIsCurrent;
  final McpVnextWindowsProcessOwner process;
}

/// Dormant process custody over the original single-connection-per-call Bridge.
/// Trusted acquisition must settle its own partial failure before throwing.
/// Neither construction nor start connects; each call reuses P26/P25 validation.
final class McpVnextWindowsBridgeStartup implements VnextMcpPort {
  McpVnextWindowsBridgeStartup({
    required Future<McpVnextWindowsBridgeDependencies> Function() acquire,
    this.enableStageApprovalWait = false,
  }) : _acquire = acquire;
  final Future<McpVnextWindowsBridgeDependencies> Function() _acquire;
  final bool enableStageApprovalWait;
  McpVnextWindowsBridgeDependencies? _dependencies;
  bool _rejectedDependencies = false;
  McpVnextWindowsBridge? _bridge;
  Future<void>? _starting, _closing, _settling;
  bool _stopped = false;

  Future<void> start() {
    if (_starting != null || _stopped) {
      throw StateError('Windows MCP startup unavailable');
    }
    return _starting = _start();
  }

  Future<void> _start() async {
    try {
      final d = await _acquire();
      if (d.owner.runtimeClaimed || !d.owner.isBridgeOwner) {
        _rejectedDependencies = true;
        throw StateError('Windows MCP startup unavailable');
      }
      _dependencies = d;
      d.owner.claimBridgeRuntime();
      _observeProcess(d.process, close);
      if (_stopped ||
          !_processCurrent(d.process) ||
          !d.compositionIsCurrent()) {
        throw StateError('Windows MCP startup unavailable');
      }
      _bridge = McpVnextWindowsBridge(
        enableStageApprovalWait: enableStageApprovalWait,
        createConnection: () => WindowsTlsBridge(
          io: d.createIo(),
          reader: WindowsDiscoveryReader(d.owner, verifier: (
              {required publicPoint, required digest, required rawSignature}) {
            d.verifyDigest(
                publicPoint: publicPoint,
                digest: digest,
                rawSignature: rawSignature);
            return true;
          }),
          trusted: d.trusted,
          owner: d.owner,
          signDigest: d.signDigest,
          verifyDigest: d.verifyDigest,
          nativePolicy: d.nativePolicy,
          utcNow: d.utcNow,
          monotonicNow: d.monotonicNow,
          compositionIsCurrent: () =>
              !_stopped &&
              _processCurrent(d.process) &&
              d.compositionIsCurrent(),
          enableStageApprovalWait: enableStageApprovalWait,
        ),
      );
    } catch (_) {
      _stopped = true;
      await _settle();
      throw StateError('Windows MCP startup unavailable');
    }
  }

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    final bridge = _bridge;
    if (_stopped || bridge == null) return vnextFailure('unavailable');
    return bridge.call(tool, arguments,
        cancelled: cancelled, available: () => !_stopped && available());
  }

  Future<void> _settle() => _settling ??= () async {
        if (_rejectedDependencies) return;
        await Future.wait([
          if (_bridge != null) _bridge!.close(),
          if (_dependencies != null)
            Future<void>.sync(_dependencies!.process.stopAndWait),
        ]);
        _dependencies?.owner.close();
      }();

  @override
  Future<void> close() {
    _stopped = true;
    return _closing ??= () async {
      try {
        await _starting;
      } catch (_) {/* Failed startup already settled. */}
      await _settle();
    }();
  }
}

bool _processCurrent(McpVnextWindowsProcessOwner? process) =>
    process is! McpVnextWindowsObservedProcessOwner || process.isCurrent;

void _observeProcess(
    McpVnextWindowsProcessOwner process, Future<void> Function() close) {
  if (process is McpVnextWindowsObservedProcessOwner) {
    // Notification initiates the SAME latched shutdown. stopAndWait still owns
    // settlement; awaiting close from inside that settlement would deadlock.
    unawaited(process.exited.then((_) => close()).catchError((Object _) {
      // The original close Future retains failure for the owning DB barrier.
    }));
  }
}
