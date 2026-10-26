import 'external_authorization.dart';
import 'external_credential_boundary.dart';
import 'external_credential_association.dart';
import 'external_trust_core.dart';
import 'first_party_development_access.dart';

/// Only Application-owned failure enums cross this diagnostic boundary.
final class FirstPartyApplicationFailure {
  const FirstPartyApplicationFailure._(this.credential, this.authorization);
  factory FirstPartyApplicationFailure.from(Object error) => switch (error) {
        ExternalCredentialException(:final failure) =>
          FirstPartyApplicationFailure._(failure, null),
        ExternalAuthException(:final failure) =>
          FirstPartyApplicationFailure._(null, failure),
        _ => const FirstPartyApplicationFailure._(null, null),
      };
  final ExternalCredentialFailure? credential;
  final ExternalAuthFailure? authorization;
  String get code => credential != null
      ? 'credential.${credential!.name}'
      : authorization != null
          ? 'authorization.${authorization!.name}'
          : 'unknown';
}

enum FirstPartyAppPairingPhase {
  request,
  approve,
  complete,
  exportTrust,
  exportCompletion,
  display
}

final class FirstPartyAppPairingFailure {
  const FirstPartyAppPairingFailure(this.phase, this.failure);
  final FirstPartyAppPairingPhase phase;
  final FirstPartyApplicationFailure failure;
}

/// Historical observation only; its first failure survives later UI invalidation.
final class FirstPartyPairingObservation {
  const FirstPartyPairingObservation(
      this.phase, this.result, this.firstFailure);
  final FirstPartyAppPairingPhase phase;
  final FirstPartyObservedResult result;
  final FirstPartyAppPairingFailure? firstFailure;
}

/// Installed only by the App-owned development root over its original Owner.
/// Reads confer no identity or business authority; revoke delegates to P15/Host.
abstract interface class FirstPartyAssociationRecoveryPort {
  bool get isCurrent;
  String get installationId;
  Future<ExternalCredentialAssociationSnapshot> read(
      ExternalProfileReference reference);
  Future<void> revoke(ExternalProfileReference reference, int expectedRevision);
}

final class FirstPartyAssociationRevocationObservation {
  const FirstPartyAssociationRevocationObservation({
    this.revoke = FirstPartyObservedResult.unobserved,
    this.close = FirstPartyObservedResult.unobserved,
    this.failure,
    this.closeFailure,
  });
  final FirstPartyObservedResult revoke, close;
  final FirstPartyApplicationFailure? failure, closeFailure;
}

/// Public comparison data for a local request.
///
/// It is neither proof nor a connection token.
final class FirstPartyPairingDisplay {
  const FirstPartyPairingDisplay(
      {this.digest, this.revision, this.submissionId});
  final String? digest, submissionId;
  final int? revision;
}

/// Custody of an existing P15/P27 request, never another PairingState.
abstract interface class FirstPartyPairingRequest {
  Future<FirstPartyPairingDisplay> display();
  Future<void> approve();
  Future<void> complete();
}

/// A local pairing port supplied only by trusted composition.
abstract interface class FirstPartyPairingPort {
  Future<FirstPartyPairingRequest> request(ExternalProfileReference profile);
  Future<void> close();
}

abstract interface class FirstPartyPublicPairingPort
    implements FirstPartyPairingPort {
  Future<FirstPartyPairingRequest> requestSubmission(
      ExternalProfileReference profile, String submissionId);
  Future<String> exportPublicTrust();
  Future<String> exportPublicCompletion();
}

final class FirstPartyBridgePairingDisplay {
  const FirstPartyBridgePairingDisplay({
    this.submissionId,
    this.initialDigest,
    this.completionDigest,
    this.revision,
    this.proofPublished = false,
    this.closed = false,
    this.pinSaved = false,
  });
  final String? submissionId, initialDigest, completionDigest;
  final int? revision;
  final bool proofPublished, closed, pinSaved;
}

/// Supplied to the independent Bridge local surface, never to App or MCP.
abstract interface class FirstPartyBridgePairingPort {
  FirstPartyBridgePairingDisplay display();
  void beginEnrollment(
      {required String displayLabel, required String clientBuild});
  Future<void> importTrust(String publicData);
  void confirmInitial(String comparedDigest);
  Future<void> importCompletion(String publicData);
  void confirmCompletion(String comparedDigest, int comparedRevision);
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

/// Safe local comparison projection; never a proof or business connection.
final class FirstPartyExistingCredentialDisplay {
  const FirstPartyExistingCredentialDisplay(
      {required this.profileId,
      required this.remainingSeconds,
      this.credentialIdentity,
      this.installationId,
      this.revision,
      this.settling = false});
  final String profileId;
  final int remainingSeconds;
  final String? credentialIdentity, installationId;
  final int? revision;
  final bool settling;
}

abstract interface class FirstPartyExistingCredentialPort {
  void begin(ExternalProfileReference profile);
  FirstPartyExistingCredentialDisplay? display();
  Future<void> confirm(FirstPartyExistingCredentialDisplay displayed);
  Future<void> cancel();
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
    this.cancelPendingConnection,
    this.existingCredential,
    this.associationRecovery,
    required this.close,
  });
  final ExternalCredentialBoundary boundary;
  final FirstPartyPairingPort pairing;
  final Future<FirstPartyCredentialConnection> Function(
      ExternalProfileReference profile) openConnection;

  /// Rejects only the pending local acquisition, not the owning Host or channel.
  /// The original open Future must still settle before controls release custody.
  final void Function()? cancelPendingConnection;
  final FirstPartyExistingCredentialPort? existingCredential;
  final FirstPartyAssociationRecoveryPort? associationRecovery;
  final Future<void> Function() close;
}
