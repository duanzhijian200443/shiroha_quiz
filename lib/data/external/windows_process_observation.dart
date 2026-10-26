import 'dart:io';

import '../../application/external/external_credential_association.dart';
import '../../application/external/first_party_development_access.dart';
import 'native/windows_external_native.dart';
import 'windows_local_relay.dart';

/// Same bounded stderr-only observation mechanism for the business child. It
/// receives no request fields, exception strings, paths or credential bytes.
final class WindowsBusinessProcessReport {
  WindowsBusinessProcessReport(this._write);
  static const marker = 'SHIROHA_BUSINESS_V1|';
  final void Function(String) _write;
  FirstPartyBusinessStage stage = FirstPartyBusinessStage.parentAdmission;
  bool _primary = false, _cleanup = false;
  int _records = 0;
  void _emit(String value) {
    if (_records++ >= 32) return;
    try {
      _write('$marker$value');
    } catch (_) {/* Observation never changes the owning operation. */}
  }

  void enter(FirstPartyBusinessStage value) {
    stage = value;
    _emit('S|${value.name}');
  }

  void primary(Object error) {
    if (_primary) return;
    _primary = true;
    _emit('P|${stage.name}|${businessDiagnosticFailureCode(error).name}');
  }

  void cleanup(Object error) {
    if (_cleanup) return;
    _cleanup = true;
    _emit('C|${stage.name}|${businessDiagnosticFailureCode(error).name}');
  }
}

FirstPartyBusinessFailureCode businessDiagnosticFailureCode(Object error) {
  if (error is ExternalNativeException) {
    return switch (error.failure) {
      ExternalNativeFailure.invalidInput =>
        FirstPartyBusinessFailureCode.nativeInvalidInput,
      ExternalNativeFailure.resourceLimit =>
        FirstPartyBusinessFailureCode.nativeResourceLimit,
      ExternalNativeFailure.dataCorrupt =>
        FirstPartyBusinessFailureCode.nativeDataCorrupt,
      ExternalNativeFailure.commitUnknown =>
        FirstPartyBusinessFailureCode.nativeCommitUnknown,
      ExternalNativeFailure.verificationRejected =>
        FirstPartyBusinessFailureCode.nativeVerificationRejected,
      _ => FirstPartyBusinessFailureCode.nativeUnavailable,
    };
  }
  if (error is ExternalCredentialException) {
    return switch (error.failure) {
      ExternalCredentialFailure.unauthorized =>
        FirstPartyBusinessFailureCode.credentialUnauthorized,
      ExternalCredentialFailure.invalidInput =>
        FirstPartyBusinessFailureCode.credentialInvalidInput,
      ExternalCredentialFailure.conflict =>
        FirstPartyBusinessFailureCode.credentialConflict,
      ExternalCredentialFailure.staleRevision =>
        FirstPartyBusinessFailureCode.credentialStaleRevision,
      ExternalCredentialFailure.dataCorrupt =>
        FirstPartyBusinessFailureCode.credentialDataCorrupt,
      ExternalCredentialFailure.temporarilyUnavailable =>
        FirstPartyBusinessFailureCode.credentialUnavailable,
      ExternalCredentialFailure.commitUnknown =>
        FirstPartyBusinessFailureCode.credentialCommitUnknown,
      ExternalCredentialFailure.verificationRejected =>
        FirstPartyBusinessFailureCode.credentialVerificationRejected,
      ExternalCredentialFailure.resourceLimit =>
        FirstPartyBusinessFailureCode.credentialResourceLimit,
    };
  }
  if (error is LocalRelayException)
    return FirstPartyBusinessFailureCode.localAdmission;
  if (error is HandshakeException)
    return FirstPartyBusinessFailureCode.tlsHandshake;
  if (error is TlsException) return FirstPartyBusinessFailureCode.tlsContext;
  if (error is SocketException) {
    return error.osError?.errorCode == 10106
        ? FirstPartyBusinessFailureCode.socketProviderUnavailable
        : FirstPartyBusinessFailureCode.socketUnavailable;
  }
  if (error is FormatException)
    return FirstPartyBusinessFailureCode.invalidBootstrap;
  if (error is StateError)
    return FirstPartyBusinessFailureCode.runtimeUnavailable;
  return FirstPartyBusinessFailureCode.unknown;
}

/// Fixed, public stderr observations only; never a command or authorization.
final class WindowsPairingProcessReport {
  WindowsPairingProcessReport(this._write);
  static const marker = 'SHIROHA_PAIRING_V1|';
  final void Function(String) _write;
  FirstPartyPairingStage stage = FirstPartyPairingStage.admission;
  FirstPartyPairingFailure? primaryFailure, cleanupFailure;
  int _records = 0;
  FirstPartyPairingStage? _lastEmitted;
  void _emit(String value) {
    if (_records++ >= 32) return;
    try {
      _write('$marker$value');
    } catch (_) {/* Observation only. */}
  }

  void enter(FirstPartyPairingStage value) {
    stage = value;
    if (_lastEmitted == value) return;
    _lastEmitted = value;
    _emit('S|${value.name}');
  }

  void primary(FirstPartyPairingFailureCode code) {
    if (primaryFailure != null) return;
    final failure = primaryFailure = FirstPartyPairingFailure(stage, code);
    _emit('P|${failure.stage.name}|${failure.code.name}');
  }

  void cleanup(FirstPartyPairingFailureCode code) {
    if (cleanupFailure != null) return;
    final failure = cleanupFailure =
        FirstPartyPairingFailure(FirstPartyPairingStage.closing, code);
    _emit('C|${failure.stage.name}|${failure.code.name}');
  }
}
