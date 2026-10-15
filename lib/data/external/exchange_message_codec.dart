import 'dart:typed_data';

import 'external_bootstrap_bytes.dart';
import 'external_certificate_der.dart';
import 'pairing_transcript_codec.dart';

/// Decoding these public messages never proves enrollment, approval or trust.
sealed class ExchangeMessage {
  ExchangeMessage(Uint8List submissionId)
      : submissionId = bootstrapCopy(submissionId);
  final Uint8List submissionId;
  @override
  String toString() => 'ExchangeMessage(REDACTED)';
}

final class EnrollmentSubmission extends ExchangeMessage {
  EnrollmentSubmission(
      {required Uint8List submissionId,
      required Uint8List publicPoint,
      required this.displayLabel,
      required this.clientBuild})
      : publicPoint = bootstrapCopy(publicPoint),
        super(submissionId);
  final Uint8List publicPoint;
  final String displayLabel, clientBuild;
}

final class PairingChallengeMessage extends ExchangeMessage {
  PairingChallengeMessage(
      {required Uint8List submissionId,
      required this.transcript,
      required this.publicationEpoch,
      required Uint8List clientLeafDer})
      : clientLeafDer = bootstrapCopy(clientLeafDer),
        super(submissionId);
  final PairingTranscript transcript;
  final BigInt publicationEpoch;
  final Uint8List clientLeafDer;
}

final class PossessionProofMessage extends ExchangeMessage {
  PossessionProofMessage(
      {required Uint8List submissionId,
      required Uint8List requestId,
      required Uint8List rawSignature})
      : requestId = bootstrapCopy(requestId),
        rawSignature = bootstrapCopy(rawSignature),
        super(submissionId);
  final Uint8List requestId, rawSignature;
}

/// File *payloads and basenames* only. No paths or file operations are accepted.
abstract final class ExchangeMessageCodec {
  static const maxSubmissionBytes = 1024,
      maxChallengeBytes = 4096,
      maxProofBytes = 256,
      maxClientLeafBytes = 2048;

  static String fileName(ExchangeMessage value) {
    if (value.submissionId.length != 16) bootstrapInvalid();
    final id = value.submissionId
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return switch (value) {
      EnrollmentSubmission() => 'submission-$id.pub',
      PairingChallengeMessage() => 'pairing-$id.chal',
      PossessionProofMessage() => 'proof-$id.bin',
    };
  }

  static void _name(String name, ExchangeMessage value) {
    if (name != fileName(value)) bootstrapInvalid();
  }

  static Uint8List encode(String name, ExchangeMessage value) {
    _name(name, value);
    final out = BootstrapWriter();
    switch (value) {
      case EnrollmentSubmission():
        ExternalCertificateDer.inspectPublicPointShape(value.publicPoint);
        out.header('SHREXSUB');
        out.fixed(value.submissionId, 16);
        out.fixed(value.publicPoint, 65);
        out.text(value.displayLabel, 64);
        out.text(value.clientBuild, 32);
        return out.finish(maxSubmissionBytes);
      case PairingChallengeMessage():
        final t = value.transcript;
        PairingTranscriptCodec.encode(t);
        _leaf(value.clientLeafDer, t.credentialIdentity);
        out.header('SHREXCHA');
        out.fixed(value.submissionId, 16);
        out.fixed(t.requestId, 16);
        out.fixed(t.nonce, 32);
        out.fixed(t.profileId, 16);
        out.uuid(t.installationId);
        out.u64(t.generation);
        out.fixed(t.runtimeInstanceId, 16);
        out.u64(value.publicationEpoch);
        out.fixed(t.credentialIdentity, 32);
        out.u64(t.expectedRevision);
        out.u64(t.expiresAtUtcMs);
        out.field(value.clientLeafDer, maxClientLeafBytes);
        return out.finish(maxChallengeBytes);
      case PossessionProofMessage():
        bootstrapSignature(value.rawSignature);
        out.header('SHREXPRF');
        out.fixed(value.submissionId, 16);
        out.fixed(value.requestId, 16);
        out.fixed(value.rawSignature, 64);
        return out.finish(maxProofBytes);
    }
  }

  static ExchangeMessage decode(String name, Uint8List bytes) {
    // Only exact lowercase basenames, never path traversal, case folding or trim.
    final match = RegExp(
            r'^(submission-([0-9a-f]{32})\.pub|pairing-([0-9a-f]{32})\.chal|proof-([0-9a-f]{32})\.bin)$')
        .firstMatch(name);
    if (match == null || match.end != name.length) bootstrapInvalid();
    final submission = name.startsWith('submission-');
    final challenge = name.startsWith('pairing-');
    final input = BootstrapReader(
        bytes,
        submission
            ? maxSubmissionBytes
            : challenge
                ? maxChallengeBytes
                : maxProofBytes);
    input.header(submission
        ? 'SHREXSUB'
        : challenge
            ? 'SHREXCHA'
            : 'SHREXPRF');
    final id = input.fixed(16);
    final ExchangeMessage value;
    if (submission) {
      value = EnrollmentSubmission(
          submissionId: id,
          publicPoint: input.fixed(65),
          displayLabel: input.text(64),
          clientBuild: input.text(32));
    } else if (challenge) {
      final request = input.fixed(16),
          nonce = input.fixed(32),
          profile = input.fixed(16);
      final installation = input.uuid();
      final generation = input.u64();
      final runtime = input.fixed(16);
      final epoch = input.u64();
      value = PairingChallengeMessage(
          submissionId: id,
          transcript: PairingTranscript(
              requestId: request,
              nonce: nonce,
              profileId: profile,
              installationId: installation,
              generation: generation,
              runtimeInstanceId: runtime,
              credentialIdentity: input.fixed(32),
              expectedRevision: input.u64(),
              expiresAtUtcMs: input.u64()),
          publicationEpoch: epoch,
          clientLeafDer: input.field(maxClientLeafBytes));
    } else {
      value = PossessionProofMessage(
          submissionId: id,
          requestId: input.fixed(16),
          rawSignature: input.fixed(64));
    }
    input.done();
    // Same strict validation for both directions, including name/id correlation.
    encode(name, value);
    return value;
  }

  static void _leaf(Uint8List bytes, Uint8List identity) {
    if (bytes.isEmpty || bytes.length > maxClientLeafBytes) bootstrapInvalid();
    ExternalCertificateDer.inspect(bytes, role: ExternalCertificateRole.client);
    if (!bootstrapEqual(bootstrapDigest(bytes), identity)) bootstrapInvalid();
  }
}
