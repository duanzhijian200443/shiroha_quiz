import 'dart:convert';
import 'dart:typed_data';

import '../../application/external/external_credential_association.dart';
import 'discovery_descriptor_codec.dart';
import 'external_bootstrap_bytes.dart';
import 'external_credential_object_codec.dart';
import 'native/windows_external_native.dart';
import 'windows_credential_initialization.dart';
import 'windows_credential_object_store.dart';

/// Inactive App-only publisher. Explicitly injected offline runtime values do
/// not establish a listener. One call is one publication; no automatic retry.
final class WindowsDiscoveryPublisher {
  WindowsDiscoveryPublisher(
      {required ExternalProtectedObjects owner,
      required WindowsCredentialInitialization credentials})
      : _owner = owner,
        _credentials = credentials {
    if (!credentials.usesOwner(owner)) {
      credentialFail(ExternalCredentialFailure.invalidInput);
    }
  }
  final ExternalProtectedObjects _owner;
  final WindowsCredentialInitialization _credentials;
  bool _busy = false, _unknown = false;

  DiscoveryDescriptor publish(
      {required Uint8List runtimeInstanceId,
      required BigInt generation,
      required int port,
      required BigInt publishedAtUtcMs}) {
    if (_busy || _unknown) {
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    }
    _busy = true;
    try {
      _owner.ensureOpen();
      final descriptor = _credentials.prepareDiscoveryDescriptor(
          runtimeInstanceId: runtimeInstanceId,
          generation: generation,
          port: port,
          publishedAtUtcMs: publishedAtUtcMs);
      // Fresh persisted validation immediately before any file publication.
      final current = _credentials.validatePublication(descriptor);
      _owner.publishDiscovery(2, current.issuerCertificateDer);
      _owner.publishDiscovery(
          3, Uint8List.fromList(utf8.encode(current.installationId)));
      _owner.publishDiscovery(1, DiscoveryDescriptorCodec.encode(descriptor));
      return descriptor;
    } on ExternalNativeException catch (e) {
      if (e.failure == ExternalNativeFailure.commitUnknown) _unknown = true;
      _nativeFailure(e);
    } on ExternalCredentialException catch (e) {
      if (e.failure == ExternalCredentialFailure.commitUnknown) _unknown = true;
      rethrow;
    } finally {
      _busy = false;
    }
  }

  @override
  String toString() => 'WindowsDiscoveryPublisher(REDACTED)';
}

/// Inactive Reader. Caller supplies previously established trust and independent
/// Server Leaf digest evidence. A result is public data, never authorization.
final class WindowsDiscoveryReader {
  WindowsDiscoveryReader(this._owner,
      {required BootstrapDigestVerifier verifier})
      : _verify = verifier;
  final ExternalProtectedObjects _owner;
  final BootstrapDigestVerifier _verify;
  bool _busy = false;

  DiscoveryDescriptor read(DiscoveryExpectations expected) =>
      _operation(() => _read(expected));

  /// Uses an existing kind 4 only after comparing it to independently trusted
  /// inputs. Full-snapshot CAS preserves keys, leaf, anchor and installation.
  DiscoveryDescriptor readAndAdvanceExistingPin(
          DiscoveryExpectations trusted) =>
      _operation(() {
        bootstrapU64(trusted.verifiedEpochHighWater);
        final store = WindowsCredentialObjectStore(_owner);
        final pin = store.read(4) as ExternalBridgeClient?;
        if (pin == null) credentialFail(ExternalCredentialFailure.unauthorized);
        try {
          if (!bootstrapEqual(
                  pin.issuerCertificateDer, trusted.trustedAnchorDer) ||
              pin.pinnedInstallationId != trusted.installationId ||
              pin.pinnedDiscoveryEpochHighWater <
                  trusted.verifiedEpochHighWater) {
            credentialFail(ExternalCredentialFailure.verificationRejected);
          }
          final expected = DiscoveryExpectations(
              trustedAnchorDer: trusted.trustedAnchorDer,
              installationId: trusted.installationId,
              serverLeafDigest: trusted.serverLeafDigest,
              verifiedEpochHighWater: pin.pinnedDiscoveryEpochHighWater);
          final descriptor = _read(expected);
          store.advanceDiscoveryHighWater(pin, descriptor.publicationEpoch);
          return descriptor;
        } finally {
          pin.clientPkcs8Der.fillRange(0, pin.clientPkcs8Der.length, 0);
          pin.clientLeafDer.fillRange(0, pin.clientLeafDer.length, 0);
          pin.issuerCertificateDer
              .fillRange(0, pin.issuerCertificateDer.length, 0);
        }
      });

  DiscoveryDescriptor _read(DiscoveryExpectations expected) {
    final endpoint = _owner.readDiscovery(1),
        anchor = _owner.readDiscovery(2),
        installation = _owner.readDiscovery(3);
    if (endpoint == null || anchor == null || installation == null) {
      credentialFail(ExternalCredentialFailure.verificationRejected);
    }
    final descriptor = DiscoveryDescriptorCodec.decode(endpoint);
    DiscoveryDescriptorCodec.validatePublicObjects(descriptor,
        anchorDer: anchor,
        installationIdBytes: installation,
        expected: expected,
        verifier: _verify);
    return descriptor;
  }

  T _operation<T>(T Function() operation) {
    if (_busy) credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    _busy = true;
    try {
      return operation();
    } on ExternalCredentialException {
      rethrow;
    } on ExternalNativeException catch (e) {
      _nativeFailure(e);
    } on FormatException {
      credentialFail(ExternalCredentialFailure.verificationRejected);
    } catch (_) {
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    } finally {
      _busy = false;
    }
  }

  @override
  String toString() => 'WindowsDiscoveryReader(REDACTED)';
}

Never _nativeFailure(ExternalNativeException e) =>
    credentialFail(switch (e.failure) {
      ExternalNativeFailure.commitUnknown =>
        ExternalCredentialFailure.commitUnknown,
      ExternalNativeFailure.dataCorrupt =>
        ExternalCredentialFailure.dataCorrupt,
      ExternalNativeFailure.resourceLimit =>
        ExternalCredentialFailure.resourceLimit,
      ExternalNativeFailure.invalidInput =>
        ExternalCredentialFailure.invalidInput,
      ExternalNativeFailure.verificationRejected =>
        ExternalCredentialFailure.verificationRejected,
      _ => ExternalCredentialFailure.temporarilyUnavailable,
    });
