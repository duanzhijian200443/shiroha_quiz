/// Inactive G0-L0 source candidate. Every OS operation has an explicit method
/// boundary. Only dormant trusted composition imports it; normal startup does
/// not import or start this library.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../application/external/external_authorization.dart';
import '../../application/capabilities/capability.dart';
import '../../application/external/external_credential_association.dart';
import '../../application/external/external_credential_boundary.dart';
import '../../application/external/first_party_external_credentials.dart';
import '../../application/external/first_party_development_access.dart';
import '../../application/external/first_party_stage_approval.dart';
import '../../application/external/external_invocation_core.dart';
import '../../application/external/external_trust_core.dart';
import '../../application/external/external_trust_coordinator.dart';
import '../../application/external/local_host_dispatch.dart';
import '../../services/backup/sha256.dart';
import 'discovery_descriptor_codec.dart';
import 'external_bootstrap_bytes.dart';
import 'external_certificate_der.dart';
import 'external_credential_object_codec.dart';
import 'ipc_command_projection.dart';
import 'ipc_envelope_codec.dart';
import 'native/windows_external_native.dart';
import 'native/windows_peer_certificate_policy.dart';
import 'windows_credential_initialization.dart';
import 'windows_credential_object_store.dart';
import 'windows_credential_association_store.dart';
import 'windows_discovery.dart';
import 'windows_pairing.dart';
import 'windows_process_observation.dart';

part 'windows_tls_resources.dart';
part 'windows_tls_credentials.dart';
part 'windows_tls_channel.dart';
part 'windows_tls_host.dart';
part 'windows_tls_io.dart';
part 'windows_tls_bridge.dart';

Never _tlsReject() =>
    credentialFail(ExternalCredentialFailure.verificationRejected);
Uint8List _tlsHash(Uint8List der) {
  final hex = sha256Hex(der);
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16)
  ]);
}

String _tlsIdentity(Uint8List der) =>
    _tlsHash(der).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Trusted injected I/O seam, never an authorization or wire surface.
abstract interface class TlsChannel {
  Uint8List get peerDer;

  /// Whether the channel remains open for admission/writes. Peer EOF may make
  /// this false before a caller's final [read]; that read still returns null
  /// to confirm end of input.
  bool get isOpen;
  Future<Uint8List?> read(int maximum);
  Future<void> write(Uint8List response);
  Future<void> close();
}

abstract interface class TlsRawPeer {
  Future<TlsChannel> upgrade(TlsContextPlan plan);
  Future<void> close();
}

abstract interface class TlsCandidateListener {
  String get address;
  int get port;
  bool get shared;
  Stream<TlsRawPeer> get peers;
  Future<void> close();
}

abstract interface class TlsListenerIo {
  Future<TlsCandidateListener> bind(int port);
}

/// Owner/runtime/certificate checks and P26 publication form ONE start sequence.
abstract interface class TlsStartup {
  bool get isCurrent;
  Future<TlsContextPlan> prepare();
  Future<DiscoveryDescriptor> publish(int port);
  void invalidate();
}

/// Legacy v1/v2 composition only. v3 instead uses [IpcTrustedContextBinding]
/// after authenticated P8 admission and strict selector decoding.
typedef TlsTrustedContext = Future<ExternalExecutionContext> Function(
    ExternalSession session);

/// Trusted deterministic deadline seam. Construction never schedules a timer.
typedef TlsSchedule = void Function() Function(
    Duration delay, void Function() expire);
void Function() _tlsSchedule(Duration delay, void Function() expire) {
  final timer = Timer(delay, expire);
  return timer.cancel;
}
