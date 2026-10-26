/// First-party development operations only. No Capability/MCP registration.
enum FirstPartyDevelopmentPhase {
  unavailable,
  inactive,
  starting,
  active,
  closed,
  failed
}

enum FirstPartyInitializationStage { load, acquire, p25, postAdmission, close }

enum FirstPartyChildPart { stdin, stdout, stderr, exit, settlement }

enum FirstPartyObservedResult { unobserved, pending, returned, failed }

/// Observations of the original business process, never authentication evidence.
enum FirstPartyBusinessStage {
  parentAdmission,
  securityAdmission,
  independentTrust,
  acquire,
  bootstrapDiscovery,
  ready,
  credentialRead,
  credentialValidation,
  discovery,
  tlsConnect,
  peerPolicy,
  peerCertificate,
  peerBinding,
  connected,
  request,
  response,
  connectionClose,
  closing,
  closed,
}

enum FirstPartyBusinessFailureCode {
  localAdmission,
  nativeUnavailable,
  nativeInvalidInput,
  nativeResourceLimit,
  nativeDataCorrupt,
  nativeCommitUnknown,
  nativeVerificationRejected,
  credentialUnauthorized,
  credentialInvalidInput,
  credentialConflict,
  credentialStaleRevision,
  credentialDataCorrupt,
  credentialUnavailable,
  credentialCommitUnknown,
  credentialVerificationRejected,
  credentialResourceLimit,
  tlsHandshake,
  tlsContext,
  socketUnavailable,
  socketProviderUnavailable,
  invalidBootstrap,
  runtimeUnavailable,
  unknown,
}

final class FirstPartyBusinessFailure {
  const FirstPartyBusinessFailure(this.stage, this.code);
  final FirstPartyBusinessStage stage;
  final FirstPartyBusinessFailureCode code;
}

enum FirstPartyPairingStage {
  admission,
  acquire,
  credentialRead,
  enrollment,
  uiOpen,
  display,
  proofConnect,
  proofWait,
  pinObserved,
  closing,
  closed,
  beginEnrollment,
  importTrust,
  confirmInitial,
  importCompletion,
  confirmCompletion,
  closedWithoutPinObservation
}

enum FirstPartyPairingFailureCode {
  unavailable,
  invalidInput,
  corrupt,
  conflict,
  verificationRejected,
  commitUnknown,
  resourceLimit,
  unknown
}

final class FirstPartyPairingFailure {
  const FirstPartyPairingFailure(this.stage, this.code);
  final FirstPartyPairingStage stage;
  final FirstPartyPairingFailureCode code;
}

/// Process facts and child-reported observations are separate, never authority.
final class FirstPartyChildObservation {
  FirstPartyChildObservation({
    required Map<FirstPartyChildPart, FirstPartyObservedResult> parts,
    this.exitCode,
    this.reportedStage,
    this.primaryFailure,
    this.cleanupFailure,
    this.businessStage,
    this.businessPrimary,
    this.businessCleanup,
  }) : parts = Map.unmodifiable(parts);
  final Map<FirstPartyChildPart, FirstPartyObservedResult> parts;
  final int? exitCode;
  final FirstPartyPairingStage? reportedStage;
  final FirstPartyPairingFailure? primaryFailure, cleanupFailure;
  final FirstPartyBusinessStage? businessStage;
  final FirstPartyBusinessFailure? businessPrimary, businessCleanup;
}

enum FirstPartyDevelopmentStopCause {
  user,
  appClose,
  expired,
  relayLost,
  appInvalidated
}

final class FirstPartyDevelopmentStopObservation {
  const FirstPartyDevelopmentStopObservation(this.cause, this.result,
      [this.failure]);
  final FirstPartyDevelopmentStopCause cause;
  final FirstPartyObservedResult result;
  final FirstPartyInitializationFailureCode? failure;
}

/// Closed diagnostic categories only; never exception text or credential data.
enum FirstPartyInitializationFailureCode {
  nativeUnsupportedPlatform,
  nativeLibraryUnavailable,
  nativeAbiMismatch,
  nativeInvalidInput,
  nativeResourceLimit,
  nativeTemporarilyUnavailable,
  nativeDataCorrupt,
  nativeInvalidNativeResult,
  nativeCommitUnknown,
  nativeVerificationRejected,
  credentialUnauthorized,
  credentialInvalidInput,
  credentialConflict,
  credentialStaleRevision,
  credentialDataCorrupt,
  credentialTemporarilyUnavailable,
  credentialCommitUnknown,
  credentialVerificationRejected,
  credentialResourceLimit,
  incompleteCredentials,
  unknown,
}

enum FirstPartyInitializationCloseResult {
  notAttempted,
  pending,
  returned,
  failed
}

final class FirstPartyInitializationFailure {
  const FirstPartyInitializationFailure(this.stage, this.code);
  final FirstPartyInitializationStage stage;
  final FirstPartyInitializationFailureCode code;
}

/// An observation of one original operation, not admission or rollback evidence.
final class FirstPartyInitializationObservation {
  const FirstPartyInitializationObservation({
    required this.stage,
    required this.ownerReturned,
    required this.closeResult,
    this.primaryFailure,
    this.cleanupFailure,
  });
  final FirstPartyInitializationStage stage;
  final bool ownerReturned;
  final FirstPartyInitializationCloseResult closeResult;
  final FirstPartyInitializationFailure? primaryFailure, cleanupFailure;
}

final class FirstPartyDevelopmentStatus {
  const FirstPartyDevelopmentStatus({
    required this.phase,
    this.issuerMissing,
    this.serverMissing,
    this.bridgePinMissing,
    this.pairingWindowOpen = false,
    this.initialization,
    this.pairingChild,
    this.businessChild,
    this.stopObservation,
  });
  final FirstPartyDevelopmentPhase phase;
  // Non-authorizing fixed-object metadata, never credential validation.
  final bool? issuerMissing, serverMissing, bridgePinMissing;
  final bool pairingWindowOpen;
  final FirstPartyInitializationObservation? initialization;
  final FirstPartyChildObservation? pairingChild;
  final FirstPartyChildObservation? businessChild;
  final FirstPartyDevelopmentStopObservation? stopObservation;
}

abstract interface class FirstPartyDevelopmentAccess {
  Future<FirstPartyDevelopmentStatus> status();
  Future<void> initializeCredentials();
  Future<void> start();
  Future<void> openPairingWindow();
  Future<void> waitPairingWindowClosed();
  Future<void> stop();
}
