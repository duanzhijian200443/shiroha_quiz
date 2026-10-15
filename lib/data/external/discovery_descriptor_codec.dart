import 'dart:convert';
import 'dart:typed_data';

import 'external_bootstrap_bytes.dart';
import 'external_certificate_der.dart';
import 'external_credential_object_codec.dart';

/// Public, untrusted descriptor. Generation is informational, never ordering.
final class DiscoveryDescriptor {
  DiscoveryDescriptor(
      {required Uint8List runtimeInstanceId,
      required this.publicationEpoch,
      required this.generation,
      required this.port,
      required Uint8List serverLeafDigest,
      required this.installationId,
      required this.publishedAtUtcMs,
      required Uint8List rawSignature})
      : runtimeInstanceId = bootstrapCopy(runtimeInstanceId),
        serverLeafDigest = bootstrapCopy(serverLeafDigest),
        rawSignature = bootstrapCopy(rawSignature);
  final Uint8List runtimeInstanceId, serverLeafDigest, rawSignature;
  final BigInt publicationEpoch, generation, publishedAtUtcMs;
  final int port;
  final String installationId;
  @override
  String toString() => 'DiscoveryDescriptor(REDACTED)';
}

/// Caller asserts provenance from an already trusted/verified state. This DTO
/// does not establish that provenance and is never Application trust evidence.
final class DiscoveryExpectations {
  DiscoveryExpectations(
      {required Uint8List trustedAnchorDer,
      required this.installationId,
      required Uint8List serverLeafDigest,
      required this.verifiedEpochHighWater})
      : trustedAnchorDer = bootstrapCopy(trustedAnchorDer),
        serverLeafDigest = bootstrapCopy(serverLeafDigest);
  final Uint8List trustedAnchorDer, serverLeafDigest;
  final String installationId;
  final BigInt verifiedEpochHighWater;
}

abstract final class DiscoveryDescriptorCodec {
  static const loopbackHost = '127.0.0.1';
  static const maxBytes = 277;
  static final _domain = ascii.encode('SHIROHA-EXTERNAL-ENDPOINT-V1\x00');

  static Uint8List unsignedBytes(DiscoveryDescriptor value) {
    if (value.port < 1 ||
        value.port > 65535 ||
        value.publicationEpoch == BigInt.zero) {
      bootstrapInvalid();
    }
    final out = BootstrapWriter();
    out.header('SHREXEPD');
    out.fixed(value.runtimeInstanceId, 16);
    out.u64(value.publicationEpoch);
    out.u64(value.generation);
    out.u16(value.port);
    out.fixed(value.serverLeafDigest, 32);
    out.uuid(value.installationId);
    out.u64(value.publishedAtUtcMs);
    return out.finish(maxBytes - 64);
  }

  static Uint8List digest(DiscoveryDescriptor value) =>
      bootstrapDigest([..._domain, ...unsignedBytes(value)]);

  static Uint8List encode(DiscoveryDescriptor value) {
    bootstrapSignature(value.rawSignature);
    return Uint8List.fromList([...unsignedBytes(value), ...value.rawSignature]);
  }

  static DiscoveryDescriptor decode(Uint8List bytes) {
    final input = BootstrapReader(bytes, maxBytes);
    input.header('SHREXEPD');
    final value = DiscoveryDescriptor(
        runtimeInstanceId: input.fixed(16),
        publicationEpoch: input.u64(),
        generation: input.u64(),
        port: input.u16(),
        serverLeafDigest: input.fixed(32),
        installationId: input.uuid(),
        publishedAtUtcMs: input.u64(),
        rawSignature: input.fixed(64));
    input.done();
    encode(value);
    return value;
  }

  static BigInt nextEpoch(BigInt value) =>
      ExternalCredentialObjectCodec.nextEpoch(value);

  static Uint8List sign(DiscoveryDescriptor value,
      {required BootstrapDigestSigner signer}) {
    final signature = bootstrapCopy(signer(digest(value)));
    bootstrapSignature(signature);
    return signature;
  }

  /// Pure checks on supplied public bytes, never a directory reader/publisher.
  /// Caller owns anchor provenance, certificate chain/current-validity, runtime
  /// liveness and durable high-water commit. No state or permission is produced.
  static void validatePublicObjects(
    DiscoveryDescriptor descriptor, {
    required Uint8List anchorDer,
    required Uint8List installationIdBytes,
    required DiscoveryExpectations expected,
    required BootstrapDigestVerifier verifier,
  }) {
    encode(descriptor);
    bootstrapUuid(expected.installationId);
    bootstrapU64(expected.verifiedEpochHighWater);
    if (expected.serverLeafDigest.length != 32 ||
        installationIdBytes.length != 36 ||
        !bootstrapEqual(anchorDer, expected.trustedAnchorDer) ||
        !bootstrapEqual(
            installationIdBytes, utf8.encode(expected.installationId)) ||
        descriptor.installationId != expected.installationId ||
        !bootstrapEqual(
            descriptor.serverLeafDigest, expected.serverLeafDigest) ||
        descriptor.publicationEpoch < expected.verifiedEpochHighWater) {
      bootstrapInvalid();
    }
    final issuer = ExternalCertificateDer.inspect(expected.trustedAnchorDer,
        role: ExternalCertificateRole.issuer);
    if (!verifier(
        publicPoint: issuer.publicKey,
        digest: digest(descriptor),
        rawSignature: descriptor.rawSignature)) {
      bootstrapInvalid();
    }
  }
}
