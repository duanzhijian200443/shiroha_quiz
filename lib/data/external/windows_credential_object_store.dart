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

  /// Kind 1 CAS and increment run under the same retained App ticket. Validation
  /// is synchronous inside that ticket; competing/reentrant store work rejects.
  BigInt advancePublicationEpoch(ExternalIssuerKeyPair expected,
          void Function(ExternalIssuerKeyPair) validate) =>
      _conditional(1, (current) {
        if (current is! ExternalIssuerKeyPair ||
            !_equal(current.encode(), expected.encode())) {
          credentialFail(ExternalCredentialFailure.conflict);
        }
        validate(current);
        return ExternalIssuerKeyPair(
            installationId: current.installationId,
            publicationEpoch: ExternalCredentialObjectCodec.nextEpoch(
                current.publicationEpoch),
            issuerPkcs8Der: Uint8List.fromList(current.issuerPkcs8Der),
            issuerCertificateDer:
                Uint8List.fromList(current.issuerCertificateDer));
      });

  /// Only an already trusted kind 4 snapshot may be updated. All other fields
  /// must still match exactly. No creation, initial pin, rollback or retry.
  BigInt advanceDiscoveryHighWater(
          ExternalBridgeClient expected, BigInt epoch) =>
      _conditional(4, (current) {
        if (current is! ExternalBridgeClient ||
            !_equal(current.encode(), expected.encode()) ||
            epoch < current.pinnedDiscoveryEpochHighWater ||
            epoch > ExternalCredentialObjectCodec.maxEpoch) {
          credentialFail(ExternalCredentialFailure.conflict);
        }
        if (epoch == current.pinnedDiscoveryEpochHighWater) return null;
        return ExternalBridgeClient(
            clientPkcs8Der: Uint8List.fromList(current.clientPkcs8Der),
            clientLeafDer: Uint8List.fromList(current.clientLeafDer),
            issuerCertificateDer:
                Uint8List.fromList(current.issuerCertificateDer),
            pinnedInstallationId: current.pinnedInstallationId,
            pinnedDiscoveryEpochHighWater: epoch);
      });

  BigInt _conditional(int kind,
      ExternalCredentialObject? Function(ExternalCredentialObject?) update) {
    final transaction = _native(() => _owner.beginCredential(kind));
    ExternalCredentialObject? current, next;
    Uint8List? plain, encrypted;
    try {
      current = _decode(transaction, kind);
      next = update(current);
      final result = switch (next ?? current) {
        ExternalIssuerKeyPair(:final publicationEpoch) => publicationEpoch,
        ExternalBridgeClient(:final pinnedDiscoveryEpochHighWater) =>
          pinnedDiscoveryEpochHighWater,
        _ => throw StateError('invalid conditional kind'),
      };
      if (next != null) {
        plain = next.encode();
        encrypted = _native(() => _owner.protectCredential(plain!));
        _native(() => transaction.commit(encrypted!));
      }
      return result;
    } finally {
      plain?.fillRange(0, plain.length, 0);
      encrypted?.fillRange(0, encrypted.length, 0);
      _wipe(current);
      _wipe(next);
      _native(transaction.abort);
    }
  }

  static bool _equal(Uint8List a, Uint8List b) {
    try {
      if (a.length != b.length) return false;
      var diff = 0;
      for (var i = 0; i < a.length; i++) {
        diff |= a[i] ^ b[i];
      }
      return diff == 0;
    } finally {
      a.fillRange(0, a.length, 0);
      b.fillRange(0, b.length, 0);
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
