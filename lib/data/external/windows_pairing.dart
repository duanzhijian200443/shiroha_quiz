import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../application/external/external_authorization.dart';
import '../../application/external/external_credential_association.dart';
import '../../application/external/external_credential_boundary.dart';
import '../../application/external/first_party_external_credentials.dart';
import 'exchange_message_codec.dart';
import 'external_bootstrap_bytes.dart';
import 'external_certificate_der.dart';
import 'external_credential_object_codec.dart';
import 'native/windows_external_crypto.dart';
import 'pairing_transcript_codec.dart';
import 'windows_credential_initialization.dart';
import 'native/windows_external_native.dart';
import 'windows_credential_object_store.dart';
import 'windows_exchange_file_store.dart';

/// Explicit local display data. Neither this export nor its digest is authority.
final class PairingTrustDisplay {
  PairingTrustDisplay._(Uint8List issuer, Uint8List server, this.digest)
      : issuerDer = bootstrapCopy(issuer),
        serverLeafDigest = bootstrapCopy(server);
  final Uint8List issuerDer, serverLeafDigest;
  final String digest;
  @override
  String toString() => 'PairingTrustDisplay(REDACTED)';
}

final class PairingCompletionDisplay {
  PairingCompletionDisplay._(this.revision, this.digest);
  final int revision;
  final String digest;
  @override
  String toString() => 'PairingCompletionDisplay(REDACTED)';
}

/// An inactive first-party adapter over the same P27 owner.
///
/// Construction starts no
/// Windows operations. Trusted composition supplies the Submission ID and a
/// public-material export sink for independent Bridge comparison.
final class WindowsFirstPartyPairing implements FirstPartyPairingPort {
  const WindowsFirstPartyPairing({
    required this.owner,
    required this.submissionId,
    required this.exportPublicTrust,
  });
  final WindowsAppPairing owner;
  final Future<Uint8List> Function() submissionId;

  /// The local public-material export without comparison or Pin authority.
  final Future<void> Function(PairingTrustDisplay) exportPublicTrust;

  @override
  Future<FirstPartyPairingRequest> request(
      ExternalProfileReference profile) async {
    final request = await owner.createChallenge(profile, await submissionId());
    await exportPublicTrust(await owner.initialDisplay(request));
    // Export may await local IO/user work; recheck before releasing custody.
    await owner.initialDisplay(request);
    return _FirstPartyWindowsRequest(owner, request);
  }

  @override
  Future<void> close() => owner.close();
}

final class _FirstPartyWindowsRequest implements FirstPartyPairingRequest {
  _FirstPartyWindowsRequest(this.owner, this.request);
  final WindowsAppPairing owner;
  final AppPairingRequest request;
  bool _completed = false;

  @override
  Future<FirstPartyPairingDisplay> display() async {
    if (_completed) {
      final display = await owner.completionDisplay(request);
      return FirstPartyPairingDisplay(
          digest: display.digest, revision: display.revision);
    }
    final display = await owner.initialDisplay(request);
    return FirstPartyPairingDisplay(digest: display.digest);
  }

  @override
  Future<void> approve() => owner.approve(request);

  @override
  Future<void> complete() async {
    await owner.complete(request);
    await owner.completionDisplay(request);
    _completed = true;
  }
}

/// Connects one inactive App request and Bridge Enrollment's public handoff.
///
/// Trusted composition supplies the existing owners. Only the original
/// Submission ID, exported public trust bytes and freshly queried completion
/// display cross this adapter. Both Bridge confirmations remain user actions.
/// This in-process binding supplies no Windows process or authenticated channel.
final class WindowsPairingHandoff implements FirstPartyPairingPort {
  WindowsPairingHandoff({
    required WindowsAppPairing appOwner,
    required WindowsBridgePairing bridgeOwner,
  }) {
    bridge = WindowsBridgeOnboarding(
        owner: bridgeOwner,
        readAppPublicTrust: readAppPublicTrust,
        readAppCompletion: readAppCompletion);
    _app = WindowsFirstPartyPairing(
        owner: appOwner,
        submissionId: () async {
          _check();
          return bootstrapCopy(_submission!);
        },
        exportPublicTrust: (display) async {
          _check();
          _public = BridgeAppPublicMaterial(
              issuerDer: display.issuerDer,
              serverLeafDigest: display.serverLeafDigest);
        });
  }

  /// The original Bridge controls with two separate manual confirmations.
  late final WindowsBridgeOnboarding bridge;
  late final WindowsFirstPartyPairing _app;
  Uint8List? _submission;
  BridgeAppPublicMaterial? _public;
  FirstPartyPairingRequest? _request;
  bool _requested = false, _closed = false;
  int _pending = 0;
  Completer<void>? _idle;
  Future<void>? _closing;

  @override
  Future<FirstPartyPairingRequest> request(ExternalProfileReference profile) =>
      _run(() async {
        if (_requested) _reject();
        _requested = true;
        _submission = bootstrapCopy(bridge._liveEnrollment().submissionId);
        _request = await _app.request(profile);
        _check();
        return _HandoffRequest(this);
      });

  /// Reads copied public export bytes for this exact live Submission.
  ///
  /// Reading revalidates the original App display; it never confirms trust.
  Future<BridgeAppPublicMaterial> readAppPublicTrust(Uint8List submissionId) =>
      _run(() async {
        _match(submissionId);
        final request = _request, material = _public;
        if (request == null || material == null) _reject();
        await request.display();
        _match(submissionId);
        return BridgeAppPublicMaterial(
            issuerDer: material.issuerDer,
            serverLeafDigest: material.serverLeafDigest);
      });

  /// Queries P27/P15's actual confirmed completion without caching a Revision.
  Future<FirstPartyPairingDisplay> readAppCompletion(Uint8List submissionId) =>
      _run(() async {
        _match(submissionId);
        final request = _request;
        if (request == null) _reject();
        final display = await request.display();
        _match(submissionId);
        if (display.revision == null || display.digest == null) _reject();
        return display;
      });

  void _check() {
    if (_closed) _reject();
    // Acknowledged Pin storage ends Bridge custody, not the App's pairing or
    // later independent Authentication. App projections still query P15.
    if (bridge._saved) return;
    final enrollment = bridge._liveEnrollment();
    if (_submission != null &&
        !bootstrapEqual(_submission!, enrollment.submissionId)) {
      _reject();
    }
  }

  void _match(Uint8List id) {
    _check();
    bridge._liveEnrollment();
    if (_submission == null || !bootstrapEqual(id, _submission!)) _reject();
  }

  Future<T> _run<T>(Future<T> Function() work) async {
    bool tracked = false;
    try {
      _check();
      if (_pending >= ExternalCredentialBoundary.maxPending) _reject();
      if (_pending++ == 0) _idle = Completer<void>();
      tracked = true;
      final result = await work();
      _check();
      return result;
    } catch (error) {
      _invalidate();
      if (error is ExternalCredentialException ||
          error is ExternalExchangeException) {
        rethrow;
      }
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    } finally {
      if (tracked && --_pending == 0) {
        _idle!.complete();
        _idle = null;
      }
    }
  }

  void _invalidate() {
    _closed = true;
    _request = null;
    _public = null;
    _submission = null;
    // Synchronous withdrawal avoids waiting on the Bridge reader that may be
    // calling us. Explicit close below drains both existing owners and readers.
    bridge._invalidate();
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      _invalidate();
    } finally {
      await Future.wait([
        bridge.close(),
        _app.close(),
        _idle?.future ?? Future<void>.value(),
      ]);
    }
  }

  @override
  String toString() => 'WindowsPairingHandoff(REDACTED)';
}

final class _HandoffRequest implements FirstPartyPairingRequest {
  _HandoffRequest(this.owner);
  final WindowsPairingHandoff owner;

  @override
  Future<FirstPartyPairingDisplay> display() =>
      owner._run(() => owner._request!.display());
  @override
  Future<void> approve() => owner._run(() => owner._request!.approve());
  @override
  Future<void> complete() => owner._run(() => owner._request!.complete());
}

/// Local opaque workflow handle; P0 alone owns PairingState.
final class AppPairingRequest {
  AppPairingRequest._(this._owner, this._registration, this._challenge,
      this._issuer, this._serverDigest, this._initialDigest);
  final WindowsAppPairing _owner;
  final ExternalCredentialRegistration _registration;
  final PairingChallengeMessage _challenge;
  final Uint8List _issuer, _serverDigest, _initialDigest;
  _PairingEvent? _event;
  bool _busy = false, _completionAttempted = false, _completed = false;
  @override
  String toString() => 'AppPairingRequest(REDACTED)';
}

/// Inactive composition-side Pairing verifier. It accepts only private local
/// correlation events, never a decoded message/receipt/digest as evidence.
/// Authentication deliberately rejects: Package 2 owns channel verification.
final class WindowsPairingVerification
    implements ExternalCredentialVerificationPort {
  WindowsPairingVerification(
      {required WindowsExternalCrypto crypto,
      required DateTime Function() utcNow,
      required Duration Function() monotonicNow,
      required bool Function() compositionIsCurrent})
      : this.withPrimitives(
            verifyDigest: crypto.verifyDigest,
            utcNow: utcNow,
            monotonicNow: monotonicNow,
            compositionIsCurrent: compositionIsCurrent);

  WindowsPairingVerification.withPrimitives({
    required CredentialDigestVerifier verifyDigest,
    required DateTime Function() utcNow,
    required Duration Function() monotonicNow,
    required bool Function() compositionIsCurrent,
  })  : _verify = verifyDigest,
        _now = utcNow,
        _elapsed = monotonicNow,
        _current = compositionIsCurrent;
  final CredentialDigestVerifier _verify;
  final DateTime Function() _now;
  final Duration Function() _elapsed;
  final bool Function() _current;
  bool _closed = false;

  @override
  bool isLive(Object attempt) {
    if (attempt is! _PairingEvent || !identical(attempt.owner, this)) {
      return false;
    }
    if (attempt.dead) return false;
    final now = _elapsed();
    if (_closed ||
        !_current() ||
        !attempt.request._owner._boundary.isCurrent ||
        now < attempt.created ||
        now - attempt.created >= attempt.requestLifetime ||
        !_now().isBefore(attempt.request._registration.challenge.expiresAt) ||
        (attempt.verifiedAt != null &&
            (now < attempt.verifiedAt! ||
                now - attempt.verifiedAt! >=
                    ExternalCredentialBoundary.evidenceLifetime))) {
      attempt.dead = true;
    }
    return !attempt.dead;
  }

  @override
  Future<bool> verifyPairing(
      ExternalCredentialChallenge challenge, Object attempt) async {
    if (attempt is! _PairingEvent || !isLive(attempt) || attempt.used) {
      return false;
    }
    attempt.used = true;
    try {
      final request = attempt.request;
      // Identity of the private P15 request is stronger than wire correlation.
      if (!identical(challenge, request._registration.challenge)) {
        _reject();
      }
      final expected = request._challenge.transcript;
      if (challenge.profileId != _uuid(expected.profileId) ||
          challenge.installationId != expected.installationId ||
          challenge.generation != expected.generation.toInt() ||
          challenge.credentialIdentity != _hex(expected.credentialIdentity) ||
          challenge.revision != expected.expectedRevision.toInt() ||
          challenge.requestId != _hex(expected.requestId) ||
          challenge.expiresAt.millisecondsSinceEpoch !=
              expected.expiresAtUtcMs.toInt()) {
        _reject();
      }
      final proof = attempt.read!.message;
      if (!bootstrapEqual(
              proof.submissionId, request._challenge.submissionId) ||
          !bootstrapEqual(proof.requestId, expected.requestId)) {
        _reject();
      }
      final leaf = _chain(
          request._issuer, request._challenge.clientLeafDer, _now(), _verify);
      if (!bootstrapEqual(bootstrapDigest(request._challenge.clientLeafDer),
          expected.credentialIdentity)) {
        _reject();
      }
      // Reconstruct exclusively from App-held Pending fields, never Proof DTOs.
      final digest = PairingTranscriptCodec.digest(expected);
      bootstrapSignature(proof.rawSignature);
      _verify(
          publicPoint: leaf.publicKey,
          digest: digest,
          rawSignature: proof.rawSignature);
      // E0 settlement cannot extend the 30 seconds from mathematical success.
      attempt.verifiedAt = _elapsed();
      if (!isLive(attempt)) {
        _reject();
      }
      attempt.settle(
          consume: true); // Unknown/failed E0 can never open P15's window.
      if (!isLive(attempt)) {
        _reject();
      }
      return true;
    } catch (_) {
      attempt.dead = true;
      return false;
    } finally {
      attempt.settle(consume: false);
    }
  }

  @override
  Future<bool> verifyAuthentication(
          ExternalCredentialChallenge challenge, Object attempt) async =>
      false;
  void close() => _closed = true;
}

final class _PairingEvent {
  _PairingEvent(
      this.owner, this.request, this.read, this.created, this.requestLifetime);
  final WindowsPairingVerification owner;
  final AppPairingRequest request;
  ExchangeFileRead<PossessionProofMessage>? read;
  final Duration created, requestLifetime;
  Duration? verifiedAt;
  bool used = false, dead = false;
  void settle({required bool consume}) {
    final current = read;
    read = null; // Spend the capability even on exceptions; never retry.
    if (current == null) return;
    if (consume) {
      current.consume();
    } else {
      current.release();
    }
  }

  @override
  String toString() => 'PairingEvent(REDACTED)';
}

/// Explicit inactive App composition. No startup, UI, polling or listener.
/// The caller supplies the SAME verifier to P15 and owns all protected Owners.
final class WindowsAppPairing {
  WindowsAppPairing(
      {required WindowsExchangeFileStore exchange,
      required WindowsCredentialInitialization credentials,
      required ExternalCredentialBoundary boundary,
      required ExternalCredentialAssociationStore associations,
      required WindowsPairingVerification verification,
      required DateTime Function() utcNow,
      required Duration Function() monotonicNow,
      required bool Function() compositionIsCurrent})
      : this.withPrimitives(
            exchange: exchange,
            credentials: credentials,
            boundary: boundary,
            associations: associations,
            verification: verification,
            utcNow: utcNow,
            monotonicNow: monotonicNow,
            compositionIsCurrent: compositionIsCurrent,
            randomBytes: _random);

  WindowsAppPairing.withPrimitives(
      {required WindowsExchangeFileStore exchange,
      required WindowsCredentialInitialization credentials,
      required ExternalCredentialBoundary boundary,
      required ExternalCredentialAssociationStore associations,
      required WindowsPairingVerification verification,
      required DateTime Function() utcNow,
      required Duration Function() monotonicNow,
      required bool Function() compositionIsCurrent,
      required Uint8List Function(int) randomBytes})
      : _exchange = exchange,
        _credentials = credentials,
        _boundary = boundary,
        _associations = associations,
        _verification = verification,
        _now = utcNow,
        _elapsed = monotonicNow,
        _current = compositionIsCurrent,
        _randomBytes = randomBytes {
    _runtime = _bytes(_randomBytes, 16);
  }
  final WindowsExchangeFileStore _exchange;
  final WindowsCredentialInitialization _credentials;
  final ExternalCredentialBoundary _boundary;
  final ExternalCredentialAssociationStore _associations;
  final WindowsPairingVerification _verification;
  final DateTime Function() _now;
  final Duration Function() _elapsed;
  final bool Function() _current;
  final Uint8List Function(int) _randomBytes;
  late final Uint8List _runtime;
  final _requests = <AppPairingRequest>{};
  final _nonces = <String>{}, _ids = <String>{};
  bool _closed = false, _creating = false;
  Future<void>? _closing;
  int _pending = 0;
  Completer<void>? _idle;

  /// Public correlation bytes only, shared with the same Runtime's Discovery.
  Uint8List get runtimeInstanceId => bootstrapCopy(_runtime);

  /// Trusted composition identity only; never a Pairing or Session capability.
  bool usesRuntime(
          ExternalProtectedObjects owner,
          ExternalCredentialBoundary boundary,
          ExternalCredentialAssociationStore associations,
          ExternalCredentialVerificationPort verification,
          Uint8List runtimeInstanceId) =>
      _credentials.usesOwner(owner) &&
      _exchange.usesOwner(owner) &&
      bootstrapEqual(_runtime, runtimeInstanceId) &&
      identical(_boundary, boundary) &&
      identical(_associations, associations) &&
      identical(_verification, verification);

  Future<T> _track<T>(Future<T> Function() work) async {
    _check();
    if (_pending >= ExternalCredentialBoundary.maxPending) {
      _reject();
    }
    if (_pending++ == 0) _idle = Completer<void>();
    try {
      return await work();
    } finally {
      if (--_pending == 0) {
        _idle!.complete();
        _idle = null;
      }
    }
  }

  void _check([AppPairingRequest? request]) {
    if (!_current() || !_boundary.isCurrent) {
      _closed = true;
      _verification.close();
    }
    if (_closed ||
        (request != null &&
            (!identical(request._owner, this) ||
                !_requests.contains(request)))) {
      _reject();
    }
  }

  /// Trusted local selection only. Both publication AND original E0 consumption
  /// must settle before a request/display handle can escape this method.
  Future<AppPairingRequest> createChallenge(
          ExternalProfileReference profile, Uint8List submissionId) =>
      _track(() async {
        _check();
        if (_creating ||
            _requests.length >= ExternalCredentialBoundary.maxPending) {
          _reject();
        }
        _creating = true;
        ExchangeFileRead<EnrollmentSubmission>? read;
        try {
          read = _exchange.readSubmissionForConsumption(submissionId);
          if (read == null) {
            _reject();
          }
          final public = _credentials.validatedPublicMaterial();
          if (public.publicationEpoch < BigInt.one) {
            _reject();
          }
          final leaf = _credentials.issueClientLeaf(read.message.publicPoint);
          if (!bootstrapEqual(
              leaf.issuerCertificateDer, public.issuerCertificateDer)) {
            _reject();
          }
          final association = await _associations.read(profile.profileId);
          _check();
          if (!association.isCurrent) {
            _reject();
          }
          final nonce = _bytes(_randomBytes, 32), id = _bytes(_randomBytes, 16);
          if (_nonces.contains(_hex(nonce)) || _ids.contains(_hex(id))) {
            _reject();
          }
          final registration = await _boundary.requestPairing(profile,
              requestId: _hex(id),
              credentialIdentity: leaf.credentialIdentity,
              expectedRevision: association.record?.revision ?? 0);
          _nonces.add(_hex(nonce));
          _ids.add(_hex(id));
          final bound = registration.challenge;
          final transcript = PairingTranscript(
              nonce: nonce,
              requestId: id,
              profileId: _unhex(profile.profileId.replaceAll('-', '')),
              installationId: bound.installationId,
              generation: BigInt.from(bound.generation),
              runtimeInstanceId: _runtime,
              credentialIdentity: bootstrapDigest(leaf.clientLeafDer),
              expectedRevision: BigInt.from(bound.revision),
              expiresAtUtcMs:
                  BigInt.from(bound.expiresAt.millisecondsSinceEpoch));
          if (public.installationId != bound.installationId) {
            _reject();
          }
          final challenge = PairingChallengeMessage(
              submissionId: read.message.submissionId,
              transcript: transcript,
              publicationEpoch: public.publicationEpoch,
              clientLeafDer: leaf.clientLeafDer);
          _check();
          await _boundary.validatePairingRequest(registration);
          _check();
          final published = _exchange.createCaptured(challenge);
          final original = read;
          read = null;
          original.consume(); // Never reacquire or delete by path on failure.
          _check();
          await _boundary.validatePairingRequest(registration);
          final server = bootstrapDigest(public.serverLeafDer!);
          final request = AppPairingRequest._(
              this,
              registration,
              challenge,
              public.issuerCertificateDer,
              server,
              _initial(public.issuerCertificateDer, server, published.bytes));
          _check();
          _requests.add(request);
          return request;
        } catch (_) {
          // P15 may already be pending. Recovery is explicit runtime close/rebuild.
          _closed = true;
          _verification.close();
          rethrow;
        } finally {
          try {
            read?.release();
          } finally {
            _creating = false;
          }
        }
      });

  Future<PairingTrustDisplay> initialDisplay(AppPairingRequest request) =>
      _track(() async {
        _check(request);
        await _boundary.validatePairingRequest(request._registration);
        _check(request);
        return PairingTrustDisplay._(request._issuer, request._serverDigest,
            _hex(request._initialDigest));
      });

  /// Independent trusted App-local action; no Exchange or Bridge action calls it.
  Future<void> approve(AppPairingRequest request) => _track(() async {
        _check(request);
        await _boundary.approvePairing(request._registration);
        _check(request);
      });

  Future<void> complete(AppPairingRequest request) => _track(() async {
        _check(request);
        if (request._busy || request._completionAttempted) {
          _reject();
        }
        request._busy = true;
        try {
          await _boundary.validatePairingRequest(request._registration,
              requireApproval: true);
          _check(request);
          request._completionAttempted = true;
          final read = _exchange
              .readProofForConsumption(request._challenge.submissionId);
          if (read == null) {
            _reject();
          }
          final remaining =
              request._registration.challenge.expiresAt.difference(_now());
          final event = _PairingEvent(
              _verification, request, read, _elapsed(), remaining);
          request._event = event;
          try {
            await _boundary.completePairing(request._registration, event);
            _check(request);
            request._completed = true;
          } finally {
            event.dead = true;
            event.settle(consume: false);
          }
        } finally {
          request._busy = false;
        }
      });

  /// UI must refresh this projection while displayed; stale copied data is not
  /// an App acknowledgement or a continuous validity signal to the Bridge.
  Future<PairingCompletionDisplay> completionDisplay(
          AppPairingRequest request) =>
      _track(() async {
        _check(request);
        if (!request._completed) {
          _reject();
        }
        final record = await _boundary.confirmedPairing(request._registration);
        _check(request);
        return PairingCompletionDisplay._(record.revision,
            _hex(_completion(request._initialDigest, record.revision)));
      });

  /// Explicit recovery entry. Close/drain before caller closes Owners and
  /// builds an entirely fresh P0/P12/P15 composition; no automatic rebuild.
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _verification.close();
    try {
      await Future.wait(
          [_boundary.shutdown(), _idle?.future ?? Future<void>.value()]);
    } finally {
      for (final request in _requests) {
        request._event?.dead = true;
        request._event?.settle(consume: false);
      }
      _requests.clear();
    }
  }

  @override
  String toString() => 'WindowsAppPairing(REDACTED)';
}

/// Independently imported public bytes, never verified trust or identity.
final class BridgeAppPublicMaterial {
  BridgeAppPublicMaterial(
      {required Uint8List issuerDer, required Uint8List serverLeafDigest})
      : issuerDer = bootstrapCopy(issuerDer),
        serverLeafDigest = bootstrapCopy(serverLeafDigest);
  final Uint8List issuerDer, serverLeafDigest;
  @override
  String toString() => 'BridgeAppPublicMaterial(REDACTED)';
}

/// Public local controls projection, never Pairing or authorization evidence.
final class BridgeOnboardingDisplay {
  BridgeOnboardingDisplay._({
    Uint8List? submissionId,
    this.initialDigest,
    this.completionDigest,
    this.revision,
    required this.proofPublished,
    required this.closed,
    required this.pinSaved,
  }) : submissionId = submissionId == null ? null : bootstrapCopy(submissionId);
  final Uint8List? submissionId;
  final String? initialDigest, completionDigest;
  final int? revision;
  final bool proofPublished, closed, pinSaved;
  @override
  String toString() => 'BridgeOnboardingDisplay(REDACTED)';
}

/// Inactive first-party local controls over one original Bridge Enrollment.
///
/// Trusted composition supplies independent local App public-material and
/// completion readers, bound to the supplied Submission ID. They may adapt the
/// App export and [FirstPartyPairingRequest.display], but never Discovery or a
/// new Exchange message. Only explicit human actions may call the two comparison
/// methods after checking both complete local displays. Construction performs
/// no I/O. The caller retains the Pairing adapter and protected Owner custody.
final class WindowsBridgeOnboarding {
  WindowsBridgeOnboarding({
    required WindowsBridgePairing owner,
    required Future<BridgeAppPublicMaterial> Function(Uint8List)
        readAppPublicTrust,
    required Future<FirstPartyPairingDisplay> Function(Uint8List)
        readAppCompletion,
  })  : _owner = owner,
        _readTrust = readAppPublicTrust,
        _readCompletion = readAppCompletion;

  final WindowsBridgePairing _owner;
  final Future<BridgeAppPublicMaterial> Function(Uint8List) _readTrust;
  final Future<FirstPartyPairingDisplay> Function(Uint8List) _readCompletion;
  BridgeEnrollment? _enrollment;
  PairingTrustDisplay? _initial;
  PairingCompletionDisplay? _completion;
  Completer<void>? _pending;
  bool _closed = false, _saved = false;

  /// Publishes one Submission only after the user starts this local attempt.
  void beginEnrollment(
          {required String displayLabel, required String clientBuild}) =>
      _action(() {
        if (_enrollment != null) _reject();
        _enrollment = _owner.beginEnrollment(
            displayLabel: displayLabel, clientBuild: clientBuild);
      });

  /// Reads independent public inputs and displays P27's full initial digest.
  Future<void> inspectAppTrust() => _read(() {
        final enrollment = _liveEnrollment();
        if (_initial != null) _reject();
        return _readTrust(bootstrapCopy(enrollment.submissionId));
      }, (material) {
        _initial = _owner.inspectChallenge(_liveEnrollment(),
            importedIssuerDer: material.issuerDer,
            independentlyObtainedServerDigest: material.serverLeafDigest);
      });

  /// Confirms the user's full initial comparison and publishes P27's Proof.
  void confirmInitialAndPublishProof({required String comparedDigest}) =>
      _action(() {
        final enrollment = _liveEnrollment();
        if (_initial == null) _reject();
        _owner.confirmIndependentlyComparedInitial(enrollment, comparedDigest);
        _owner.publishProof(enrollment);
      });

  /// Reads the actual App completion Revision and displays P27's full digest.
  ///
  /// A matching imported display still requires the separate human save action.
  Future<void> inspectAppCompletion() => _read(() {
        final enrollment = _liveEnrollment();
        if (enrollment._published == null || _completion != null) _reject();
        return _readCompletion(bootstrapCopy(enrollment.submissionId));
      }, (material) {
        final revision = material.revision, digest = material.digest;
        if (revision == null || digest == null) _reject();
        final local = _owner.completionDisplay(_liveEnrollment(), revision);
        if (digest != local.digest) _reject();
        _completion = local;
      });

  /// Confirms the user's second digest and Revision comparison, then saves once.
  void confirmCompletionAndSave({
    required String comparedDigest,
    required int comparedRevision,
  }) =>
      _action(() {
        final completion = _completion;
        if (completion == null || comparedRevision != completion.revision) {
          _reject();
        }
        _owner.confirmIndependentlyComparedCompletionAndSave(_liveEnrollment(),
            committedRevision: comparedRevision,
            comparedDigest: comparedDigest);
        _invalidate();
        _saved = true; // Acknowledged storage result only, never authorization.
      });

  /// Refreshes visible data against the original Enrollment's current lifetime.
  ///
  /// Hosts call this while presenting a display and withdraw it on failure.
  /// Closed projections expose no old comparison data; pinSaved is historical.
  BridgeOnboardingDisplay display() {
    if (!_closed) {
      try {
        _owner._check(_enrollment);
      } catch (error) {
        _fail(error);
      }
    }
    return BridgeOnboardingDisplay._(
        submissionId: _enrollment?.submissionId,
        initialDigest: _initial?.digest,
        completionDigest: _completion?.digest,
        revision: _completion?.revision,
        proofPublished: _enrollment?._published != null,
        closed: _closed,
        pinSaved: _saved);
  }

  BridgeEnrollment _liveEnrollment() {
    if (_closed || _enrollment == null) _reject();
    _owner._check(_enrollment);
    return _enrollment!;
  }

  void _action(void Function() work) {
    try {
      if (_closed || _pending != null) _reject();
      _owner._check(_enrollment);
      work();
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _read<T>(
      Future<T> Function() read, void Function(T) apply) async {
    Completer<void>? pending;
    try {
      if (_closed || _pending != null) _reject();
      _liveEnrollment();
      pending = Completer<void>();
      _pending = pending;
      final material = await read();
      _liveEnrollment(); // Close/expiry during input can never revive custody.
      apply(material);
    } catch (error) {
      _fail(error);
    } finally {
      if (pending != null) {
        _pending = null;
        pending.complete();
      }
    }
  }

  Never _fail(Object error) {
    _invalidate();
    if (error is ExternalCredentialException ||
        error is ExternalExchangeException) {
      throw error;
    }
    credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
  }

  void _invalidate() {
    _closed = true;
    final enrollment = _enrollment;
    _enrollment = null;
    _initial = null;
    _completion = null;
    if (enrollment != null) _owner.closeEnrollment(enrollment);
  }

  /// Cancels this attempt immediately and drains any pending local input.
  ///
  /// This also handles surface closure. It never deletes public Exchange files
  /// or closes the caller's Pairing adapter, Store, writer lock or Owner.
  Future<void> close() async {
    try {
      _invalidate();
    } finally {
      await _pending?.future;
    }
  }

  @override
  String toString() => 'WindowsBridgeOnboarding(REDACTED)';
}

/// Opaque memory-only Enrollment resource, NOT a second PairingState.
final class BridgeEnrollment {
  BridgeEnrollment._(this._owner, this._key, Uint8List id, this._created)
      : submissionId = bootstrapCopy(id);
  final WindowsBridgePairing _owner;
  final ExternalP256KeyPair _key;
  final Uint8List submissionId;
  final Duration _created;
  ExchangeFileRead<PairingChallengeMessage>? _read;
  PairingChallengeMessage? _challenge;
  Uint8List? _issuer, _initialDigest;
  Duration? _published;
  bool _dead = false, _inspected = false, _accepted = false, _saveUsed = false;
  @override
  String toString() => 'BridgeEnrollment(REDACTED)';
}

/// Inactive Bridge-local actions. The UI adapter must call comparison actions
/// ONLY after independent comparison of the FULL digest on both local surfaces.
/// Importing public material or receiving a display never invokes those actions.
final class WindowsBridgePairing {
  WindowsBridgePairing(
      {required WindowsExchangeFileStore exchange,
      required WindowsCredentialObjectStore store,
      required WindowsExternalCrypto crypto,
      required DateTime Function() utcNow,
      required Duration Function() monotonicNow,
      required bool Function() compositionIsCurrent})
      : this.withPrimitives(
            exchange: exchange,
            store: store,
            generateKey: crypto.generateKey,
            signDigest: crypto.signDigest,
            verifyDigest: crypto.verifyDigest,
            utcNow: utcNow,
            monotonicNow: monotonicNow,
            compositionIsCurrent: compositionIsCurrent,
            randomBytes: _random);
  WindowsBridgePairing.withPrimitives(
      {required WindowsExchangeFileStore exchange,
      required WindowsCredentialObjectStore store,
      required ExternalP256KeyPair Function() generateKey,
      required CredentialDigestSigner signDigest,
      required CredentialDigestVerifier verifyDigest,
      required DateTime Function() utcNow,
      required Duration Function() monotonicNow,
      required bool Function() compositionIsCurrent,
      required Uint8List Function(int) randomBytes})
      : _exchange = exchange,
        _store = store,
        _generate = generateKey,
        _sign = signDigest,
        _verify = verifyDigest,
        _now = utcNow,
        _elapsed = monotonicNow,
        _current = compositionIsCurrent,
        _randomBytes = randomBytes;
  final WindowsExchangeFileStore _exchange;
  final WindowsCredentialObjectStore _store;
  final ExternalP256KeyPair Function() _generate;
  final CredentialDigestSigner _sign;
  final CredentialDigestVerifier _verify;
  final DateTime Function() _now;
  final Duration Function() _elapsed;
  final bool Function() _current;
  final Uint8List Function(int) _randomBytes;
  final _enrollments = <BridgeEnrollment>{};
  final _ids = <String>{};
  bool _closed = false, _busy = false;

  void _check([BridgeEnrollment? enrollment]) {
    if (_closed || !_current()) {
      close();
      _reject();
    }
    if (enrollment == null) return;
    if (!identical(enrollment._owner, this) ||
        !_enrollments.contains(enrollment) ||
        enrollment._dead) {
      _reject();
    }
    final now = _elapsed();
    final published = enrollment._published;
    if (now < enrollment._created ||
        (published == null &&
            now - enrollment._created >= const Duration(seconds: 600)) ||
        (published != null &&
            (now < published ||
                now - published >= const Duration(seconds: 120))) ||
        (published == null &&
            enrollment._challenge != null &&
            _now().millisecondsSinceEpoch >=
                enrollment._challenge!.transcript.expiresAtUtcMs.toInt())) {
      closeEnrollment(enrollment);
      _reject();
    }
  }

  T _action<T>(T Function() work) {
    _check();
    if (_busy) {
      _reject();
    }
    _busy = true;
    try {
      return work();
    } finally {
      _busy = false;
    }
  }

  BridgeEnrollment beginEnrollment(
          {required String displayLabel, required String clientBuild}) =>
      _action(() {
        if (_enrollments.length >= 16 || _ids.length >= 1024) {
          _reject();
        }
        final id = _bytes(_randomBytes, 16);
        if (!_ids.add(_hex(id))) {
          _reject();
        }
        final key = _generate();
        final enrollment = BridgeEnrollment._(this, key, id, _elapsed());
        try {
          _exchange.create(EnrollmentSubmission(
              submissionId: id,
              publicPoint: key.publicPoint,
              displayLabel: displayLabel,
              clientBuild: clientBuild));
          _enrollments.add(enrollment);
          return enrollment;
        } catch (_) {
          key.clearPrivateKey();
          rethrow;
        }
      });

  /// Explicit public import. Source provenance is completed by the separate
  /// independent comparison action; Discovery cannot select or accept an anchor.
  PairingTrustDisplay inspectChallenge(BridgeEnrollment enrollment,
          {required Uint8List importedIssuerDer,
          required Uint8List independentlyObtainedServerDigest}) =>
      _action(() {
        _check(enrollment);
        if (enrollment._inspected) {
          _reject();
        }
        enrollment._inspected = true;
        try {
          final read =
              _exchange.readChallengeForConsumption(enrollment.submissionId);
          enrollment._read = read;
          if (read == null || independentlyObtainedServerDigest.length != 32) {
            _reject();
          }
          final challenge = read.message;
          enrollment._challenge = challenge;
          _check(enrollment);
          final remaining = challenge.transcript.expiresAtUtcMs -
              BigInt.from(_now().millisecondsSinceEpoch);
          if (remaining <= BigInt.zero ||
              remaining > BigInt.from(600000) ||
              challenge.publicationEpoch < BigInt.one ||
              !bootstrapEqual(
                  challenge.submissionId, enrollment.submissionId)) {
            _reject();
          }
          final leaf = _chain(
              importedIssuerDer, challenge.clientLeafDer, _now(), _verify);
          if (!bootstrapEqual(leaf.publicKey, enrollment._key.publicPoint) ||
              !bootstrapEqual(bootstrapDigest(challenge.clientLeafDer),
                  challenge.transcript.credentialIdentity)) {
            _reject();
          }
          _keyMatches(enrollment._key, leaf);
          final initial = _initial(
              importedIssuerDer, independentlyObtainedServerDigest, read.bytes);
          enrollment._issuer = bootstrapCopy(importedIssuerDer);
          enrollment._initialDigest = initial;
          return PairingTrustDisplay._(importedIssuerDer,
              independentlyObtainedServerDigest, _hex(initial));
        } catch (_) {
          closeEnrollment(enrollment);
          rethrow;
        }
      });

  /// Trusted local action after a human compares both full 64-character digests.
  void confirmIndependentlyComparedInitial(
          BridgeEnrollment enrollment, String comparedDigest) =>
      _action(() {
        _check(enrollment);
        if (enrollment._accepted ||
            enrollment._initialDigest == null ||
            !_comparison(comparedDigest, enrollment._initialDigest!)) {
          closeEnrollment(enrollment);
          _reject();
        }
        enrollment._accepted = true;
      });

  void publishProof(BridgeEnrollment enrollment) => _action(() {
        _check(enrollment);
        if (!enrollment._accepted || enrollment._published != null) {
          _reject();
        }
        try {
          final challenge = enrollment._challenge!;
          final leaf = _chain(
              enrollment._issuer!, challenge.clientLeafDer, _now(), _verify);
          final signature = PairingTranscriptCodec.sign(challenge.transcript,
              signer: (digest) => _sign(
                  pkcs8Der: enrollment._key.pkcs8Der,
                  publicPoint: leaf.publicKey,
                  digest: digest));
          _verify(
              publicPoint: leaf.publicKey,
              digest: PairingTranscriptCodec.digest(challenge.transcript),
              rawSignature: signature);
          _check(enrollment);
          final read = enrollment._read;
          enrollment._read = null;
          if (read == null) {
            _reject();
          }
          read.consume(); // Consumption must succeed BEFORE any Proof publication.
          _check(enrollment);
          _exchange.create(PossessionProofMessage(
              submissionId: enrollment.submissionId,
              requestId: challenge.transcript.requestId,
              rawSignature: signature));
          enrollment._published = _elapsed();
        } catch (_) {
          closeEnrollment(enrollment);
          rethrow;
        }
      });

  PairingCompletionDisplay completionDisplay(
          BridgeEnrollment enrollment, int committedRevision) =>
      _action(() {
        _check(enrollment);
        _completionInputs(enrollment, committedRevision);
        return PairingCompletionDisplay._(committedRevision,
            _hex(_completion(enrollment._initialDigest!, committedRevision)));
      });

  void _completionInputs(BridgeEnrollment enrollment, int revision) {
    final expected = enrollment._challenge?.transcript.expectedRevision;
    if (!enrollment._accepted ||
        enrollment._published == null ||
        enrollment._saveUsed ||
        expected == null ||
        revision < 1 ||
        revision > ExternalAuthLimits.maxRevision ||
        (BigInt.from(revision) != expected &&
            BigInt.from(revision) != expected + BigInt.one)) {
      _reject();
    }
  }

  /// Separate trusted local action after comparison of completion digest AND
  /// actual Revision. Exactly one Missing-only transaction, even on unknown.
  void confirmIndependentlyComparedCompletionAndSave(
          BridgeEnrollment enrollment,
          {required int committedRevision,
          required String comparedDigest}) =>
      _action(() {
        _check(enrollment);
        try {
          _completionInputs(enrollment, committedRevision);
          enrollment._saveUsed = true;
          if (!_comparison(comparedDigest,
              _completion(enrollment._initialDigest!, committedRevision))) {
            _reject();
          }
          final challenge = enrollment._challenge!;
          final leaf = _chain(
              enrollment._issuer!, challenge.clientLeafDer, _now(), _verify);
          _keyMatches(enrollment._key, leaf);
          _check(enrollment);
          if (!_store.createIfMissing(
              4,
              () => ExternalBridgeClient(
                  clientPkcs8Der: Uint8List.fromList(enrollment._key.pkcs8Der),
                  clientLeafDer: Uint8List.fromList(challenge.clientLeafDer),
                  issuerCertificateDer: Uint8List.fromList(enrollment._issuer!),
                  pinnedInstallationId: challenge.transcript.installationId,
                  pinnedDiscoveryEpochHighWater: challenge.publicationEpoch))) {
            credentialFail(ExternalCredentialFailure.conflict);
          }
        } finally {
          closeEnrollment(enrollment);
        }
      });

  void _keyMatches(ExternalP256KeyPair key, ExternalCertificateStructure leaf) {
    final digest = bootstrapDigest(leaf.tbs);
    final signature = _sign(
        pkcs8Der: key.pkcs8Der, publicPoint: leaf.publicKey, digest: digest);
    _verify(
        publicPoint: leaf.publicKey, digest: digest, rawSignature: signature);
  }

  void closeEnrollment(BridgeEnrollment enrollment) {
    if (!identical(enrollment._owner, this)) {
      _reject();
    }
    enrollment._dead = true;
    enrollment._key.clearPrivateKey();
    _enrollments.remove(enrollment);
    final read = enrollment._read;
    enrollment._read = null;
    read?.release(); // Release is not deletion. Never retry an uncertain release.
  }

  void close() {
    _closed = true;
    Object? failure;
    for (final enrollment in _enrollments.toList()) {
      try {
        closeEnrollment(enrollment);
      } catch (e) {
        failure = e;
      }
    }
    if (failure != null) {
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    }
  }

  @override
  String toString() => 'WindowsBridgePairing(REDACTED)';
}

ExternalCertificateStructure _chain(Uint8List issuer, Uint8List leaf,
    DateTime now, CredentialDigestVerifier verify) {
  final anchor = ExternalCertificateDer.inspect(issuer,
      role: ExternalCertificateRole.issuer);
  final client = ExternalCertificateDer.inspect(leaf,
      role: ExternalCertificateRole.client);
  if (now.isBefore(anchor.notBefore) ||
      !now.isBefore(anchor.notAfter) ||
      now.isBefore(client.notBefore) ||
      !now.isBefore(client.notAfter) ||
      client.notBefore.isBefore(anchor.notBefore) ||
      client.notAfter.isAfter(anchor.notAfter)) {
    _reject();
  }
  verify(
      publicPoint: anchor.publicKey,
      digest: bootstrapDigest(anchor.tbs),
      rawSignature: anchor.rawSignature);
  verify(
      publicPoint: anchor.publicKey,
      digest: bootstrapDigest(client.tbs),
      rawSignature: client.rawSignature);
  return client;
}

Uint8List _initial(Uint8List issuer, Uint8List server, Uint8List challenge) {
  if (server.length != 32) {
    _reject();
  }
  return bootstrapDigest([
    ...ascii.encode('SHIROHA-EXTERNAL-TRUST-CONFIRM-V1'),
    0,
    ...bootstrapDigest(issuer),
    ...server,
    ...bootstrapDigest(challenge)
  ]);
}

Uint8List _completion(Uint8List initial, int revision) {
  if (revision < 1 || revision > ExternalAuthLimits.maxRevision) {
    _reject();
  }
  final out = BootstrapWriter();
  out.u64(BigInt.from(revision));
  return bootstrapDigest([
    ...ascii.encode('SHIROHA-EXTERNAL-COMPLETION-CONFIRM-V1'),
    0,
    ...initial,
    ...out.finish(8),
    1
  ]);
}

bool _comparison(String text, Uint8List digest) =>
    text.length == 64 &&
    RegExp(r'^[0-9a-f]{64}$').hasMatch(text) &&
    bootstrapEqual(ascii.encode(text), ascii.encode(_hex(digest)));
String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
Uint8List _unhex(String text) => Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16)
    ]);
String _uuid(Uint8List bytes) {
  final hex = _hex(bytes);
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Uint8List _bytes(Uint8List Function(int) random, int count) {
  final bytes = random(count);
  if (bytes.length != count) {
    _reject();
  }
  return bootstrapCopy(bytes);
}

Uint8List _random(int count) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(count, (_) => random.nextInt(256)));
}

Never _reject() =>
    credentialFail(ExternalCredentialFailure.verificationRejected);
