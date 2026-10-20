import 'external_authorization.dart';
import 'external_credential_boundary.dart';
import 'external_trust_core.dart';

/// Public comparison data for a local request.
///
/// It is neither proof nor a connection token.
final class FirstPartyPairingDisplay {
  const FirstPartyPairingDisplay({this.digest, this.revision});
  final String? digest;
  final int? revision;
}

/// Custody of an existing P15/P27 request, never another PairingState.
abstract interface class FirstPartyPairingRequest {
  Future<FirstPartyPairingDisplay> display();
  Future<void> approve();
  Future<void> complete();
}

/// A local pairing port supplied only by trusted composition.
///
/// UI supplies no credential,
/// request id, verification result, association revision or decoded proof.
abstract interface class FirstPartyPairingPort {
  Future<FirstPartyPairingRequest> request(ExternalProfileReference profile);
  Future<void> close();
}

/// Holds the original P0 Session and its owning channel's revalidation callback.
///
/// The callback must return that SAME Session or `null`, never reauthenticate into
/// a replacement Session carrying old target approvals.
final class FirstPartyCredentialConnection {
  const FirstPartyCredentialConnection(this.session, this.authenticate);
  final ExternalSession session;
  final Future<ExternalSession?> Function() authenticate;
}

/// Explicit inactive composition inputs.
///
/// The opener must use P15 openSession
/// after independent channel authentication, as the Windows channel owner does.
/// Pairing proof alone cannot implement this operation.
final class FirstPartyCredentialServices {
  const FirstPartyCredentialServices({
    required this.boundary,
    required this.pairing,
    required this.openConnection,
    required this.close,
  });
  final ExternalCredentialBoundary boundary;
  final FirstPartyPairingPort pairing;
  final Future<FirstPartyCredentialConnection> Function(
      ExternalProfileReference profile) openConnection;
  final Future<void> Function() close;
}
