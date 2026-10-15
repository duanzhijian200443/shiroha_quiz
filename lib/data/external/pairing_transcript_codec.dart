import 'dart:convert';
import 'dart:typed_data';

import 'external_bootstrap_bytes.dart';
import 'external_certificate_der.dart';

/// Public, untrusted values only. This is never a P15 challenge or proof.
final class PairingTranscript {
  PairingTranscript({
    required Uint8List nonce,
    required Uint8List requestId,
    required Uint8List profileId,
    required this.installationId,
    required this.generation,
    required Uint8List runtimeInstanceId,
    required Uint8List credentialIdentity,
    required this.expectedRevision,
    required this.expiresAtUtcMs,
  })  : nonce = bootstrapCopy(nonce),
        requestId = bootstrapCopy(requestId),
        profileId = bootstrapCopy(profileId),
        runtimeInstanceId = bootstrapCopy(runtimeInstanceId),
        credentialIdentity = bootstrapCopy(credentialIdentity);

  final Uint8List nonce,
      requestId,
      profileId,
      runtimeInstanceId,
      credentialIdentity;
  final String installationId;
  final BigInt generation, expectedRevision, expiresAtUtcMs;

  @override
  String toString() => 'PairingTranscript(REDACTED)';
}

/// Frozen §9.C.2 bytes. Callers must reconstruct from their own pending state.
/// Signature success says nothing about approval, expiry, chain or liveness.
abstract final class PairingTranscriptCodec {
  static final _domain = ascii.encode('SHIROHA-EXTERNAL-PROOF-V1\x00');
  static const maxBytes = 293;

  static Uint8List encode(PairingTranscript value) {
    bootstrapProfile(value.profileId);
    final out = BootstrapWriter();
    out.fixed(Uint8List.fromList(_domain), 26);
    out.fixed(Uint8List.fromList([1]), 1);
    out.fixed(value.nonce, 32);
    out.fixed(value.requestId, 16);
    out.fixed(value.profileId, 16);
    out.uuid(value.installationId);
    out.u64(value.generation);
    out.fixed(value.runtimeInstanceId, 16);
    out.fixed(value.credentialIdentity, 32);
    out.u64(value.expectedRevision);
    out.u64(value.expiresAtUtcMs);
    return out.finish(maxBytes);
  }

  static PairingTranscript decode(Uint8List bytes) {
    final input = BootstrapReader(bytes, maxBytes);
    input.expect(_domain);
    input.expect([1]);
    final value = PairingTranscript(
      nonce: input.fixed(32),
      requestId: input.fixed(16),
      profileId: input.fixed(16),
      installationId: input.uuid(),
      generation: input.u64(),
      runtimeInstanceId: input.fixed(16),
      credentialIdentity: input.fixed(32),
      expectedRevision: input.u64(),
      expiresAtUtcMs: input.u64(),
    );
    input.done();
    bootstrapProfile(value.profileId);
    return value;
  }

  static Uint8List digest(PairingTranscript value) =>
      bootstrapDigest(encode(value));

  static Uint8List sign(PairingTranscript value,
      {required BootstrapDigestSigner signer}) {
    final signature = bootstrapCopy(signer(digest(value)));
    bootstrapSignature(signature);
    return signature;
  }

  /// Mathematical decision by an explicit caller-owned verifier; no authority.
  static bool verify(PairingTranscript expected,
      {required Uint8List publicPoint,
      required Uint8List rawSignature,
      required BootstrapDigestVerifier verifier}) {
    final point = bootstrapCopy(publicPoint);
    final signature = bootstrapCopy(rawSignature);
    ExternalCertificateDer.inspectPublicPointShape(point);
    bootstrapSignature(signature);
    return verifier(
        publicPoint: point, digest: digest(expected), rawSignature: signature);
  }
}
