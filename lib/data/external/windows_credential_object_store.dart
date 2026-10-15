import 'dart:typed_data';

import '../../application/external/external_credential_association.dart';
import 'external_credential_object_codec.dart';
import 'native/windows_external_native.dart';

/// Inactive Infrastructure adapter for fixed kind 1/2/4 objects. This supplies
/// persistence only: no issuer, initialization, trust decision or runtime wiring.
/// The caller owns the OS owner and explicitly closes it after draining work.
final class WindowsCredentialObjectStore {
  WindowsCredentialObjectStore(this._owner);
  final ExternalProtectedObjects _owner;

  T _native<T>(T Function() operation) {
    try {
      return operation();
    } on ExternalNativeException catch (e) {
      credentialFail(switch (e.failure) {
        ExternalNativeFailure.invalidInput =>
          ExternalCredentialFailure.invalidInput,
        ExternalNativeFailure.dataCorrupt =>
          ExternalCredentialFailure.dataCorrupt,
        ExternalNativeFailure.resourceLimit =>
          ExternalCredentialFailure.resourceLimit,
        ExternalNativeFailure.commitUnknown =>
          ExternalCredentialFailure.commitUnknown,
        _ => ExternalCredentialFailure.temporarilyUnavailable,
      });
    } catch (_) {
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    }
  }

  ExternalCredentialObject? _decode(
      ExternalCredentialTransaction transaction, int kind) {
    Uint8List? plaintext;
    try {
      final encrypted = transaction.encrypted;
      if (encrypted == null) return null;
      plaintext = _native(() => _owner.unprotectCredential(encrypted));
      final result = ExternalCredentialObjectCodec.decode(plaintext!);
      if (result.kind != kind) {
        _wipe(result);
        credentialFail(ExternalCredentialFailure.dataCorrupt);
      }
      return result;
    } finally {
      plaintext?.fillRange(0, plaintext.length, 0);
    }
  }

  /// Null means Missing only. Returned fields are independent caller-owned
  /// copies; dispose of sensitive bytes after bounded use (GC copies may remain).
  ExternalCredentialObject? read(int kind) {
    final transaction = _native(() => _owner.beginCredential(kind));
    ExternalCredentialObject? snapshot;
    try {
      snapshot = _decode(transaction, kind);
      return snapshot;
    } finally {
      try {
        _native(transaction.abort);
      } catch (_) {
        _wipe(snapshot);
        rethrow;
      }
    }
  }

  /// Replaces the whole fixed object under the held owner transaction. Existing
  /// ciphertext is strictly decoded first: corruption never triggers overwrite,
  /// reset or rekey. No retry follows an uncertain commit.
  void write(ExternalCredentialObject object) {
    final transaction = _native(() => _owner.beginCredential(object.kind));
    Uint8List? plaintext, ciphertext;
    ExternalCredentialObject? previous;
    try {
      previous = _decode(transaction, object.kind);
      plaintext = ExternalCredentialObjectCodec.encode(object);
      ciphertext = _native(() => _owner.protectCredential(plaintext!));
      _native(() => transaction.commit(ciphertext!));
    } finally {
      plaintext?.fillRange(0, plaintext.length, 0);
      ciphertext?.fillRange(0, ciphertext.length, 0);
      _wipe(previous);
      _native(transaction.abort);
    }
  }

  /// Creates only when Missing under one held Owner ticket. The synchronous
  /// factory runs after the existence check; an existing object never invokes
  /// it. Returns false for an existing strictly decoded object, without writing.
  /// Factory output is owned and wiped here. No uncertain commit is retried.
  bool createIfMissing(int kind, ExternalCredentialObject Function() create) {
    final transaction = _native(() => _owner.beginCredential(kind));
    ExternalCredentialObject? previous, created;
    Uint8List? plaintext, ciphertext;
    try {
      previous = _decode(transaction, kind);
      if (previous != null) return false;
      created = create();
      if (created.kind != kind) {
        credentialFail(ExternalCredentialFailure.invalidInput);
      }
      plaintext = ExternalCredentialObjectCodec.encode(created);
      ciphertext = _native(() => _owner.protectCredential(plaintext!));
      _native(() => transaction.commit(ciphertext!));
      return true;
    } finally {
      plaintext?.fillRange(0, plaintext.length, 0);
      ciphertext?.fillRange(0, ciphertext.length, 0);
      _wipe(previous);
      _wipe(created);
      _native(transaction.abort);
    }
  }

  static void _wipe(ExternalCredentialObject? object) {
    final fields = switch (object) {
      ExternalIssuerKeyPair() => [
          object.issuerPkcs8Der,
          object.issuerCertificateDer
        ],
      ExternalServerKeyChain() => [
          object.serverPkcs8Der,
          object.serverLeafDer,
          object.issuerCertificateDer
        ],
      ExternalBridgeClient() => [
          object.clientPkcs8Der,
          object.clientLeafDer,
          object.issuerCertificateDer
        ],
      null => <Uint8List>[],
    };
    for (final field in fields) {
      field.fillRange(0, field.length, 0);
    }
  }

  @override
  String toString() => 'WindowsCredentialObjectStore(REDACTED)';
}
