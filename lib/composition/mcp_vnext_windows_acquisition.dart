/// Dormant trusted native acquisition. No ordinary startup consumer.
library;

import 'dart:async';
import 'dart:typed_data';

import '../application/external/external_trust_core.dart';
import '../application/external/local_host_dispatch.dart';

import '../data/external/native/windows_external_crypto.dart';
import '../data/external/native/windows_external_native.dart';
import '../data/external/native/windows_peer_certificate_policy.dart';
import '../data/external/windows_bridge_process.dart';
import '../data/external/discovery_descriptor_codec.dart';
import '../data/external/windows_credential_association_store.dart';
import '../data/external/windows_credential_initialization.dart';
import '../data/external/windows_exchange_file_store.dart';
import '../data/external/windows_pairing.dart';
import '../data/external/windows_tls_transport.dart';
import 'mcp_vnext_windows_startup.dart';

/// Trusted primitive injection only; the default uses the existing native crypto.
final class McpVnextWindowsCredentialPrimitives {
  const McpVnextWindowsCredentialPrimitives({
    required this.generateKey,
    required this.signDigest,
    required this.verifyDigest,
    this.nativePolicy,
  });
  final ExternalP256KeyPair Function() generateKey;
  final CredentialDigestSigner signDigest;
  final CredentialDigestVerifier verifyDigest;
  final void Function(Uint8List, TlsPeerRole)? nativePolicy;
}

/// The sole newly acquired App Owner and its original P20/P25/P24/P27 adapters.
/// The assembly callback must only construct the existing startup dependency
/// bundle; it must not start a Host or transfer these resources elsewhere.
final class McpVnextWindowsAppResources {
  McpVnextWindowsAppResources._(this.owner, this.credentials, this.associations,
      this.exchange, this.verification, this.primitives, this.nativePolicy);
  final ExternalProtectedObjects owner;
  final WindowsCredentialInitialization credentials;
  final WindowsCredentialAssociationStore associations;
  final WindowsExchangeFileStore exchange;
  final WindowsPairingVerification verification;
  final McpVnextWindowsCredentialPrimitives primitives;
  final void Function(Uint8List, TlsPeerRole) nativePolicy;
}

/// One-shot ownership transfer, not an admission grant. Construction captures
/// callbacks only. The native loader still selects only resolvedExecutable's
/// fixed DLL; acquisition still uses the original native exclusive locks.
/// No credential initialization, recovery, rotation or application Writer exists.
final class McpVnextWindowsProtectedAcquirer {
  McpVnextWindowsProtectedAcquirer({
    required this.utcNow,
    required this.monotonicNow,
    required this.compositionIsCurrent,
    required this.randomBytes,
    WindowsExternalNative Function()? openNative,
    McpVnextWindowsCredentialPrimitives? primitives,
  })  : _openNative = openNative ?? WindowsExternalNative.open,
        _primitives = primitives;

  final DateTime Function() utcNow;
  final Duration Function() monotonicNow;
  final bool Function() compositionIsCurrent;
  final Uint8List Function(int) randomBytes;
  final WindowsExternalNative Function() _openNative;
  final McpVnextWindowsCredentialPrimitives? _primitives;
  bool _used = false;
  // Retain original ownership on uncertain cleanup; never expose a retry API.
  ExternalProtectedObjects? _owner;
  WindowsCredentialAssociationStore? _associations;
  WindowsExternalNative? _native;

  McpVnextWindowsCredentialPrimitives _primitivesFor(
      WindowsExternalNative native) {
    if (_primitives case final supplied?) return supplied;
    final crypto = native.crypto;
    return McpVnextWindowsCredentialPrimitives(
        generateKey: crypto.generateKey,
        signDigest: crypto.signDigest,
        verifyDigest: crypto.verifyDigest);
  }

  /// Complete explicit App dependency assembly. Real acquisition/listening is
  /// still separately admitted; defaults never load saved App configuration.
  /// The only public input is independently delivered P27 Submission identity.
  Future<McpVnextWindowsAppDependencies> acquireAppRuntime({
    required ExternalClock clock,
    required LocalHostReadinessPort readiness,
    required int port,
    Future<Uint8List> Function()? submissionId,
    WindowsBridgeProcess? process,
    TlsListenerIo? listener,
  }) {
    final child = process ?? WindowsBridgeProcess();
    return acquireApp(
        process: child,
        assemble: (r) => McpVnextWindowsAppDependencies(
              owner: r.owner,
              credentials: r.credentials,
              associations: r.associations,
              exchange: r.exchange,
              pairingVerification: r.verification,
              signDigest: r.primitives.signDigest,
              verifyDigest: r.primitives.verifyDigest,
              nativePolicy: r.nativePolicy,
              clock: clock,
              utcNow: utcNow,
              monotonicNow: monotonicNow,
              randomBytes: randomBytes,
              compositionIsCurrent: compositionIsCurrent,
              readiness: readiness,
              listener: listener ?? const DartLoopbackTlsIo(),
              port: port,
              pairing: (owner) => WindowsAppPublicPairingHandoff(
                  owner: owner, submissionId: submissionId),
              process: child,
            ));
  }

  /// Same original Bridge Owner/P26/Pin path, with concrete existing TLS I/O
  /// and Native peer policy. Trust inputs and process custody remain mandatory.
  Future<McpVnextWindowsBridgeDependencies> acquireBridgeRuntime({
    required DiscoveryExpectations trusted,
    required McpVnextWindowsProcessOwner process,
    TlsBridgeIo Function()? createIo,
  }) =>
      acquireBridge(
          process: process,
          assemble: (owner) {
            final native = _native!;
            final primitives = _primitivesFor(native);
            return McpVnextWindowsBridgeDependencies(
              owner: owner,
              trusted: trusted,
              createIo: createIo ?? () => const DartLoopbackBridgeIo(),
              signDigest: primitives.signDigest,
              verifyDigest: primitives.verifyDigest,
              nativePolicy:
                  primitives.nativePolicy ?? native.peerCertificatePolicy.check,
              utcNow: utcNow,
              monotonicNow: monotonicNow,
              compositionIsCurrent: compositionIsCurrent,
              process: process,
            );
          });

  void _admit() {
    if (_used) throw _unavailable();
    _used = true;
  }

  Future<McpVnextWindowsAppDependencies> acquireApp({
    required FutureOr<McpVnextWindowsAppDependencies> Function(
            McpVnextWindowsAppResources)
        assemble,
    required McpVnextWindowsProcessOwner process,
    Future<void> Function()? closeLocalConnections,
  }) async {
    _admit();
    try {
      if (!compositionIsCurrent()) throw _unavailable();
      final native = _native = _openNative();
      final owner = _owner = native.acquireAppObjects();
      final primitives = _primitivesFor(native);
      final associations = _associations = WindowsCredentialAssociationStore(
          owner,
          nowUtcMs: () => utcNow().millisecondsSinceEpoch);
      final credentials = WindowsCredentialInitialization.withPrimitives(
          owner: owner,
          generateKey: primitives.generateKey,
          signDigest: primitives.signDigest,
          verifyDigest: primitives.verifyDigest,
          utcNow: utcNow,
          randomBytes: randomBytes);
      // Existing-only P25 validation before handing anything to composition.
      credentials.validatedPublicMaterial();
      final exchange = WindowsExchangeFileStore(owner);
      final verification = WindowsPairingVerification.withPrimitives(
          verifyDigest: primitives.verifyDigest,
          utcNow: utcNow,
          monotonicNow: monotonicNow,
          compositionIsCurrent: compositionIsCurrent);
      final d = await assemble(McpVnextWindowsAppResources._(
          owner,
          credentials,
          associations,
          exchange,
          verification,
          primitives,
          primitives.nativePolicy ?? native.peerCertificatePolicy.check));
      if (!identical(d.owner, owner) ||
          !identical(d.credentials, credentials) ||
          !identical(d.associations, associations) ||
          !identical(d.exchange, exchange) ||
          !identical(d.pairingVerification, verification) ||
          !identical(d.process, process) ||
          d.closeLocalConnections != closeLocalConnections ||
          owner.runtimeClaimed ||
          !compositionIsCurrent()) {
        throw _unavailable();
      }
      // From here, startup/Host alone closes the original Store/Owner.
      _owner = null;
      _associations = null;
      return d;
    } catch (_) {
      await _abort(process, closeLocalConnections ?? () async {});
      throw _unavailable();
    }
  }

  Future<McpVnextWindowsBridgeDependencies> acquireBridge({
    required FutureOr<McpVnextWindowsBridgeDependencies> Function(
            ExternalProtectedObjects)
        assemble,
    required McpVnextWindowsProcessOwner process,
  }) async {
    _admit();
    try {
      if (!compositionIsCurrent()) throw _unavailable();
      final native = _native = _openNative();
      final owner = _owner = native.acquireBridgeObjects();
      final d = await assemble(owner);
      if (!identical(d.owner, owner) ||
          !identical(d.process, process) ||
          owner.runtimeClaimed ||
          !compositionIsCurrent()) {
        throw _unavailable();
      }
      // Existing P26/Bridge alone verifies independent trust, kind 4 and peer.
      // Acquiring an Owner must not enroll or manufacture an initial pin.
      _owner = null;
      return d;
    } catch (_) {
      await _abort(process, () async {});
      throw _unavailable();
    }
  }

  Future<void> _abort(McpVnextWindowsProcessOwner process,
      Future<void> Function() closeLocalConnections) async {
    try {
      // All original work settles even if another closer fails. Unknown process
      // or local-channel close retains the SAME Store/Owner and native lock.
      await Future.wait([
        Future<void>.sync(closeLocalConnections),
        Future<void>.sync(process.stopAndWait),
      ]);
      if (_owner?.runtimeClaimed == true) throw _unavailable();
      await _associations?.close();
      _owner?.close();
      _associations = null;
      _owner = null;
    } catch (_) {
      _owner?.rejectRuntimeReuse();
      throw _unavailable();
    }
  }

  static StateError _unavailable() =>
      StateError('Windows acquisition unavailable');
}
