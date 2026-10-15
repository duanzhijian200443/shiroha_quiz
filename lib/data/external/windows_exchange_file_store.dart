import 'dart:typed_data';

import 'exchange_message_codec.dart';
import 'native/windows_external_native.dart';

enum ExternalExchangeFailure {
  invalidInput,
  dataCorrupt,
  temporarilyUnavailable,
  commitUnknown
}

final class ExternalExchangeException implements Exception {
  const ExternalExchangeException(this.failure);
  final ExternalExchangeFailure failure;
  @override
  String toString() => 'ExternalExchangeException(${failure.name})';
}

/// Inactive Exchange-only Data adapter. Reading yields untrusted DTOs; no
/// approval, possession, polling or production composition occurs. E0 exposes
/// explicit controlled consumption without deciding its business timing.
/// The caller owns and closes the supplied App/Bridge protected-object owner.
final class WindowsExchangeFileStore {
  WindowsExchangeFileStore(this._owner);
  final ExternalProtectedObjects _owner;

  T _native<T>(T Function() operation) {
    try {
      return operation();
    } on ExternalNativeException catch (e) {
      throw ExternalExchangeException(switch (e.failure) {
        ExternalNativeFailure.invalidInput =>
          ExternalExchangeFailure.invalidInput,
        ExternalNativeFailure.dataCorrupt =>
          ExternalExchangeFailure.dataCorrupt,
        _ => ExternalExchangeFailure.temporarilyUnavailable,
      });
    } catch (_) {
      throw const ExternalExchangeException(
          ExternalExchangeFailure.temporarilyUnavailable);
    }
  }

  static int _kind(ExchangeMessage value) => switch (value) {
        EnrollmentSubmission() => 1,
        PairingChallengeMessage() => 2,
        PossessionProofMessage() => 3,
      };

  /// P22 produces the exact name and strictly validates every encoded field.
  /// Role checks occur again at FFI and Native boundaries. No overwrite/retry.
  ExternalExchangeReceipt create(ExchangeMessage value) {
    late final Uint8List bytes;
    try {
      bytes = ExchangeMessageCodec.encode(
          ExchangeMessageCodec.fileName(value), value);
    } on FormatException {
      throw const ExternalExchangeException(
          ExternalExchangeFailure.invalidInput);
    }
    return _native(
        () => _owner.createExchange(_kind(value), value.submissionId, bytes));
  }

  EnrollmentSubmission? readSubmission(Uint8List id) =>
      _read(1, id) as EnrollmentSubmission?;
  PairingChallengeMessage? readChallenge(Uint8List id) =>
      _read(2, id) as PairingChallengeMessage?;
  PossessionProofMessage? readProof(Uint8List id) =>
      _read(3, id) as PossessionProofMessage?;

  ExchangeFileRead<EnrollmentSubmission>? readSubmissionForConsumption(
          Uint8List id) =>
      _controlledRead<EnrollmentSubmission>(1, id);
  ExchangeFileRead<PairingChallengeMessage>? readChallengeForConsumption(
          Uint8List id) =>
      _controlledRead<PairingChallengeMessage>(2, id);
  ExchangeFileRead<PossessionProofMessage>? readProofForConsumption(
          Uint8List id) =>
      _controlledRead<PossessionProofMessage>(3, id);

  ExchangeFileRead<T>? _controlledRead<T extends ExchangeMessage>(
      int kind, Uint8List id) {
    if (id.length != 16) {
      throw const ExternalExchangeException(
          ExternalExchangeFailure.invalidInput);
    }
    final snapshot = Uint8List.fromList(id);
    final hex = snapshot.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final name = switch (kind) {
      1 => 'submission-$hex.pub',
      2 => 'pairing-$hex.chal',
      _ => 'proof-$hex.bin',
    };
    final read = _native(() => _owner.beginExchangeRead(kind, snapshot));
    if (read == null) return null;
    try {
      // Decode THIS read's original bytes; never reconstruct a payload from DTOs.
      final message = ExchangeMessageCodec.decode(name, read.bytes) as T;
      return ExchangeFileRead<T>._(message, read);
    } catch (_) {
      _native(read.release); // Never deletion, including P22 rejection.
      throw const ExternalExchangeException(
          ExternalExchangeFailure.dataCorrupt);
    }
  }

  ExchangeMessage? _read(int kind, Uint8List id) {
    if (id.length != 16) {
      throw const ExternalExchangeException(
          ExternalExchangeFailure.invalidInput);
    }
    final snapshot = Uint8List.fromList(id);
    final hex = snapshot.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final name = switch (kind) {
      1 => 'submission-$hex.pub',
      2 => 'pairing-$hex.chal',
      _ => 'proof-$hex.bin',
    };
    final bytes = _native(() => _owner.readExchange(kind, snapshot));
    if (bytes == null) return null;
    try {
      return ExchangeMessageCodec.decode(name, bytes);
    } on FormatException {
      throw const ExternalExchangeException(
          ExternalExchangeFailure.dataCorrupt);
    }
  }

  @override
  String toString() => 'WindowsExchangeFileStore(REDACTED)';
}

/// Strictly decoded public DTO plus its exact original bytes and one-use native
/// capability. This supplies no proof, approval, trust or Pairing state.
final class ExchangeFileRead<T extends ExchangeMessage> {
  ExchangeFileRead._(this.message, this._read);
  final T message;
  final ExternalExchangeRead _read;
  Uint8List get bytes => _read.bytes;
  void consume() => _settle(_read.consume);
  void release() => _settle(_read.release);
  void _settle(void Function() operation) {
    try {
      operation();
    } on ExternalNativeException catch (e) {
      throw ExternalExchangeException(switch (e.failure) {
        ExternalNativeFailure.invalidInput =>
          ExternalExchangeFailure.invalidInput,
        ExternalNativeFailure.commitUnknown =>
          ExternalExchangeFailure.commitUnknown,
        ExternalNativeFailure.dataCorrupt =>
          ExternalExchangeFailure.dataCorrupt,
        _ => ExternalExchangeFailure.temporarilyUnavailable,
      });
    }
  }

  @override
  String toString() => 'ExchangeFileRead(REDACTED)';
}
