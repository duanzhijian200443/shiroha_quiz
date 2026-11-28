import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../application/backup/backup_restore_gate.dart';
import '../../application/capabilities/capability.dart';
import '../../application/external/android_foreground_access.dart';
import '../../application/external/android_http_access.dart';
import '../../application/external/external_authorization.dart';
import '../../application/external/external_credential_association.dart';
import '../../application/external/external_runtime_admission.dart';
import '../../application/external/external_trust_core.dart';
import '../../services/backup/sha256.dart';
import 'android_association_store.dart';

/// One-time token issuance result. `toString()` never exposes the raw token.
final class AndroidIssuedClientToken {
  const AndroidIssuedClientToken({
    required this.profileReference,
    required this.clientProfileId,
    required this.displayName,
    required this.token,
    required this.credentialIdentity,
    required this.associationRevision,
  });

  final ExternalProfileReference profileReference;
  final String clientProfileId;
  final String displayName;
  final String token;
  final String credentialIdentity;
  final int associationRevision;

  @override
  String toString() =>
      'AndroidIssuedClientToken(profileId: $clientProfileId, REDACTED)';
}

/// Pure Bearer token minting, validation, domain-separated SHA-256 digesting,
/// and constant-time digest comparison for Android Streamable HTTP MCP.
abstract final class AndroidHttpTokenCodec {
  static const tokenPrefix = 'shq_';
  static const tokenLength = 47;
  static const domainPrefix = 'shiroha-http-bearer-v1:';
  static const adapterName = androidHttpAdapter;
  static const protocolName = androidHttpProtocol;

  static final _bodyPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _hex64Pattern = RegExp(r'^[0-9a-f]{64}$');

  /// Mints a 256-bit CSPRNG token formatted as `shq_<43 unpadded base64url>`.
  static String mint({Random? random}) {
    final rng = random ?? Random.secure();
    final bytes = Uint8List(32);
    try {
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = rng.nextInt(256);
      }
      final body = base64Url.encode(bytes).substring(0, 43);
      return '$tokenPrefix$body';
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  /// Strictly validates syntax and canonical unpadded 32-byte base64url tail.
  static bool isWellFormedToken(String value) {
    if (value.length != tokenLength || !value.startsWith(tokenPrefix)) {
      return false;
    }
    final body = value.substring(tokenPrefix.length);
    if (!_bodyPattern.hasMatch(body)) return false;
    // 32 bytes = 256 bits; 43 * 6 = 258 bits -> last 2 bits must be zero.
    final lastBits = _base64UrlValue(body.codeUnitAt(42));
    return lastBits >= 0 && (lastBits & 0x03) == 0;
  }

  /// Parses exactly one strict `Authorization: Bearer <token>` header.
  static String? parseBearerHeader(List<String>? authorizationHeaders) {
    if (authorizationHeaders == null || authorizationHeaders.length != 1) {
      return null;
    }
    final header = authorizationHeaders.single;
    if (!header.startsWith('Bearer ')) return null;
    final token = header.substring(7);
    return isWellFormedToken(token) ? token : null;
  }

  /// Computes domain-separated lowercase hex SHA-256 over
  /// `"shiroha-http-bearer-v1:" || token`.
  static String digestToken(String token) {
    if (!isWellFormedToken(token)) {
      throw const FormatException('Invalid HTTP Bearer token');
    }
    final tokenBytes = Uint8List.fromList(ascii.encode(token));
    try {
      final hasher = StreamingSha256()
        ..update(ascii.encode(domainPrefix))
        ..update(tokenBytes);
      return hasher.digestHex();
    } finally {
      tokenBytes.fillRange(0, tokenBytes.length, 0);
    }
  }

  /// Constant-time comparison over canonical 64-character lowercase SHA-256 hex
  /// digests. Always inspects all 64 code units when lengths match.
  static bool constantTimeDigestEquals(String left, String right) {
    if (left.length != 64 || right.length != 64) return false;
    var diff = 0;
    var valid = 1;
    for (var i = 0; i < 64; i++) {
      final a = left.codeUnitAt(i);
      final b = right.codeUnitAt(i);
      diff |= a ^ b;
      if (!_isLowerHex(a) || !_isLowerHex(b)) {
        valid = 0;
      }
    }
    return diff == 0 && valid == 1;
  }

  static bool isValidDigest(String value) => _hex64Pattern.hasMatch(value);

  static bool _isLowerHex(int code) =>
      (code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x66);

  static int _base64UrlValue(int code) {
    if (code >= 0x41 && code <= 0x5a) return code - 0x41;
    if (code >= 0x61 && code <= 0x7a) return code - 0x61 + 26;
    if (code >= 0x30 && code <= 0x39) return code - 0x30 + 52;
    if (code == 0x2d) return 62; // '-'
    if (code == 0x5f) return 63; // '_'
    return -1;
  }
}

/// Default READ-only questionContent policy for a newly minted HTTP client
/// Profile: `studyStatistics` and `fileContent` are strictly off by default,
/// and no `STAGE` permission is granted in H1.
ExternalGrantPolicy androidHttpDefaultReadPolicy({
  Iterable<ExternalGrantScope> scopes = const [],
  bool allContent = true,
}) =>
    ExternalGrantPolicy(
      permissions: const [CapabilityPermission.read],
      scopes: scopes,
      categories: const [ExternalContentCategory.questionContent],
      allContent: allContent,
    );

/// Private one-use bridge from verified Android HTTP Bearer tokens to P0
/// `ExternalTrustCore`. Never constructed from untrusted HTTP input.
final class AndroidHttpCredentialPort implements ExternalCredentialPort {
  final _proofWindows = Set<_HttpProofTicket>.identity();
  final _authWindows = Set<_HttpAuthTicket>.identity();

  T _withProof<T>(
    String requestId,
    String credentialIdentity,
    T Function(Object ticket) action,
  ) {
    final ticket = _HttpProofTicket(requestId, credentialIdentity);
    _proofWindows.add(ticket);
    try {
      return action(ticket);
    } finally {
      ticket.consumed = true;
      _proofWindows.remove(ticket);
    }
  }

  T _withAuth<T>(
    String credentialIdentity,
    T Function(Object ticket) action,
  ) {
    final ticket = _HttpAuthTicket(credentialIdentity);
    _authWindows.add(ticket);
    try {
      return action(ticket);
    } finally {
      ticket.consumed = true;
      _authWindows.remove(ticket);
    }
  }

  @override
  PairingProof? provePossession(Object proofAttempt) {
    if (proofAttempt is! _HttpProofTicket ||
        proofAttempt.consumed ||
        !_proofWindows.contains(proofAttempt)) {
      return null;
    }
    proofAttempt.consumed = true;
    return PairingProof(
        proofAttempt.requestId, proofAttempt.credentialIdentity);
  }

  @override
  AuthenticatedPeerEvidence? authenticate(Object authenticationAttempt) {
    if (authenticationAttempt is! _HttpAuthTicket ||
        authenticationAttempt.consumed ||
        !_authWindows.contains(authenticationAttempt)) {
      return null;
    }
    authenticationAttempt.consumed = true;
    return AuthenticatedPeerEvidence(authenticationAttempt.credentialIdentity);
  }
}

final class _HttpProofTicket {
  _HttpProofTicket(this.requestId, this.credentialIdentity);
  final String requestId;
  final String credentialIdentity;
  bool consumed = false;
}

final class _HttpAuthTicket {
  _HttpAuthTicket(this.credentialIdentity);
  final String credentialIdentity;
  bool consumed = false;
}

/// Identifies the original Profile for first-party cleanup when issuance could
/// not settle. It never carries the unpublished Token or a native exception.
final class AndroidHttpIssuanceRecoveryRequired implements Exception {
  const AndroidHttpIssuanceRecoveryRequired(this.profileId);
  final String profileId;

  @override
  String toString() => 'android_http_issuance_recovery_required';
}

final class _HttpEnableWindow {
  _HttpEnableWindow(this.foregroundGeneration, this.trustGeneration);
  final int foregroundGeneration;
  final int trustGeneration;
  bool ready = false;
}

/// Multi-client Android HTTP Bearer Token custody over existing P1/P0/P4/P15
/// stores. Construction performs no I/O and hydrates no credentials at startup.
final class AndroidHttpClientCredentials {
  AndroidHttpClientCredentials({
    required this.associations,
    required this.management,
    required this.trust,
    required this.credentialPort,
    required this.admission,
    required this.foreground,
    required this.installationId,
    required this.mintRequestId,
    required this.onRevokeFailureWithdrawEnable,
    this.onProfileRevoked,
    Random? random,
  }) : _random = random {
    if (!identical(trust.credentials, credentialPort)) {
      throw ArgumentError('Mismatched ExternalTrustCore credential port');
    }
    if (!identical(admission.trust, trust)) {
      throw ArgumentError('Mismatched ExternalRuntimeAdmission owners');
    }
    if (!ExternalAuthLimits.text(installationId, 128)) {
      throw ArgumentError('Invalid installationId');
    }
  }

  final AndroidAssociationStore associations;
  final ExternalAuthorizationManagement management;
  final ExternalTrustCore trust;
  final AndroidHttpCredentialPort credentialPort;
  final ExternalRuntimeAdmission admission;
  final AndroidForegroundAccess foreground;
  final String installationId;
  final String Function() mintRequestId;

  /// Fail-closed callback invoked when durable revocation fails so the entire
  /// current Enable window is withdrawn immediately.
  final Future<void> Function() onRevokeFailureWithdrawEnable;

  /// Optional per-Profile cleanup (e.g., closing only the revoked Profile's
  /// HTTP legacy sessions and invalidating its READ contexts) without touching
  /// sibling clients.
  final Future<void> Function(String profileId, ExternalSession? session)?
      onProfileRevoked;

  final Random? _random;

  final _references = <String, ExternalProfileReference>{};
  final _principals = <String, ExternalPrincipal>{};
  final _sessions = <String, ExternalSession>{};
  final _revoking = <String>{};
  _HttpEnableWindow? _enable;
  bool _preparingEnable = false;
  bool _reissuing = false;
  int _issuing = 0;

  bool get enableWindowOpen {
    final window = _enable;
    return window != null && window.ready && _isCurrent(window);
  }

  bool _isCurrent(_HttpEnableWindow window) =>
      identical(_enable, window) &&
      foreground.generation == window.foregroundGeneration &&
      trust.generation == window.trustGeneration &&
      foreground.allowsAuthenticatedUse;

  void _requireCurrent(_HttpEnableWindow window) {
    if (!_isCurrent(window)) {
      throw const ExternalCoreException(ExternalFailure.cancelled);
    }
  }

  void _enablePrincipal(ExternalPrincipal principal, _HttpEnableWindow window) {
    _requireCurrent(window);
    final remaining = foreground.boundedRemaining;
    trust.enableForRuntime(
      principal,
      isCurrent: () => _isCurrent(window),
      expiresAt: remaining == null ? null : trust.clock.now().add(remaining),
    );
  }

  /// Reserve the protected association slot before creating durable P1 state.
  /// Pairing proof completes after the association commit, and the Token is
  /// delivered only after both owners acknowledge the same Profile.
  Future<AndroidIssuedClientToken> issueClient({
    required String displayName,
    ExternalGrantPolicy? initialPolicy,
  }) async {
    if (_reissuing) credentialFail(ExternalCredentialFailure.resourceLimit);
    return _issueClient(displayName: displayName, initialPolicy: initialPolicy);
  }

  Future<AndroidIssuedClientToken> _issueClient({
    required String displayName,
    ExternalGrantPolicy? initialPolicy,
  }) async {
    if (_preparingEnable || _issuing >= associations.maxActiveAssociations) {
      credentialFail(ExternalCredentialFailure.resourceLimit);
    }
    _issuing++;
    String? committedProfileId;
    ExternalProfileReference? preparedReference;
    late final ExternalPrincipal principal;
    late final String requestId;
    late final String digest;
    try {
      final policy = initialPolicy ?? androidHttpDefaultReadPolicy();
      final token = AndroidHttpTokenCodec.mint(random: _random);
      digest = AndroidHttpTokenCodec.digestToken(token);
      await BackupRestoreMutationGate.instance.runMutation(
        () => associations.retireOrphanedHttpAssociations(
          installationId: installationId,
          profileIsMissing: (id) async =>
              await management.selectProfileIfPresent(id) == null,
          validateManagement: management.validateCurrent,
        ),
      );
      final snapshot = await associations.registerNewHttpAssociation(
        installationId: installationId,
        credentialIdentity: digest,
        prepareProfile: () async {
          if (!trust.hasProfileCapacity) {
            credentialFail(ExternalCredentialFailure.resourceLimit);
          }
          final ref = preparedReference = await management.createProfile(
            displayName: displayName,
            adapter: AndroidHttpTokenCodec.adapterName,
            protocol: AndroidHttpTokenCodec.protocolName,
            onCommitted: (id) => committedProfileId = id,
          );
          await management.replaceGrant(ref, 0, policy);
          principal = await _bindIdentity(ref);
          requestId = _preparePairing(principal, digest);
          return ref.profileId;
        },
        validateManagement: (id) async {
          final current = await _readHttpProfile(preparedReference!);
          if (current.profile.revokedAtUtcMs != null ||
              current.grant?.revision != 1 ||
              _revoking.contains(id)) {
            credentialFail(ExternalCredentialFailure.unauthorized);
          }
        },
      );
      final reference = preparedReference!;
      final record = snapshot.record;
      if (record == null || record.revoked) {
        credentialFail(ExternalCredentialFailure.dataCorrupt);
      }
      final current = await _readHttpProfile(reference);
      if (current.profile.revokedAtUtcMs != null ||
          current.grant?.revision != 1 ||
          _revoking.contains(reference.profileId)) {
        credentialFail(ExternalCredentialFailure.unauthorized);
      }
      _completePairing(principal, requestId, digest);
      final window = _enable;
      if (window != null &&
          window.ready &&
          _isCurrent(window) &&
          foreground.allowsHttpReadGrant(current.grant)) {
        _enablePrincipal(principal, window);
      }
      return AndroidIssuedClientToken(
        profileReference: reference,
        clientProfileId: reference.profileId,
        displayName: displayName,
        token: token,
        credentialIdentity: digest,
        associationRevision: record.revision,
      );
    } catch (_) {
      final reference = preparedReference;
      if (reference == null) {
        final id = committedProfileId;
        if (id != null) throw AndroidHttpIssuanceRecoveryRequired(id);
        rethrow;
      }
      final id = reference.profileId;
      _revokeLocal(id);
      try {
        // The unpublished credential cannot rehydrate even if Native's
        // original commit is uncertain. Only reconcile its exact association.
        await _revokeDurableProfile(reference);
        await _revokeAssociation(reference, unpublishedDigest: digest);
        await _forgetRevokedProfile(reference);
      } catch (_) {
        throw AndroidHttpIssuanceRecoveryRequired(id);
      }
      rethrow;
    } finally {
      _issuing--;
    }
  }

  /// Uses the already prepared, explicit Android Enable window for each P0
  /// Principal. Its owner and generation are captured before the first await.
  Future<List<String>> enableActiveClients() async {
    if (_preparingEnable ||
        _issuing != 0 ||
        _reissuing ||
        enableWindowOpen ||
        !foreground.acceptsNew) {
      throw const ExternalCoreException(ExternalFailure.invalidState);
    }
    if (_enable != null) disableAllActiveClients();
    final remaining = foreground.boundedRemaining;
    if (!foreground.allowBackgroundRead &&
        (remaining == null || remaining > trust.maxEnableDuration)) {
      throw const ExternalCoreException(ExternalFailure.invalidRequest);
    }
    final window =
        _enable = _HttpEnableWindow(foreground.generation, trust.generation);
    _preparingEnable = true;
    try {
      final active = await associations.listActive();
      _requireCurrent(window);
      final candidates = <(ExternalPrincipal, ExternalCredentialAssociation)>[];
      for (final association in active.records) {
        final id = association.profileId;
        if (association.installationId != installationId ||
            _revoking.contains(id)) {
          continue;
        }
        final reference =
            _references[id] ?? await management.selectProfileIfPresent(id);
        _requireCurrent(window);
        if (reference == null) continue;
        final current = await management.read(reference);
        _requireCurrent(window);
        if (!_isHttpProfile(current.profile) ||
            current.profile.revokedAtUtcMs != null ||
            !foreground.allowsHttpReadGrant(current.grant) ||
            !active.isRecordCurrent(association) ||
            _revoking.contains(id)) {
          continue;
        }
        void validateSelection() {
          _requireCurrent(window);
          if (_revoking.contains(id) || !active.isRecordCurrent(association)) {
            throw const ExternalCoreException(ExternalFailure.revoked);
          }
        }

        final ExternalPrincipal principal;
        try {
          principal = await _bindIdentity(reference,
              validateSelection: validateSelection);
          validateSelection();
        } on ExternalCoreException catch (error) {
          if (error.failure != ExternalFailure.revoked) rethrow;
          _requireCurrent(window);
          continue;
        }
        if (trust.snapshot(principal).state == PairingState.unpaired) {
          _completePairing(
            principal,
            _preparePairing(principal, association.credentialIdentity),
            association.credentialIdentity,
          );
        }
        candidates.add((principal, association));
      }
      _requireCurrent(window);
      final enabledIds = <String>[];
      for (final (principal, association) in candidates) {
        if (!active.isRecordCurrent(association) ||
            _revoking.contains(principal.profileId) ||
            trust.snapshot(principal).state == PairingState.revoked) {
          continue;
        }
        _enablePrincipal(principal, window);
        enabledIds.add(principal.profileId);
      }
      window.ready = true;
      return enabledIds;
    } catch (_) {
      if (identical(_enable, window)) disableAllActiveClients();
      rethrow;
    } finally {
      _preparingEnable = false;
    }
  }

  /// Admission and P0 Sessions lose the original window synchronously.
  /// Pending preparation may settle but cannot reopen it.
  void disableAllActiveClients() {
    _enable = null;
    _sessions.clear();
    for (final principal in _principals.values) {
      // P0 observes the withdrawn owner and releases its runtime reference.
      trust.snapshot(principal);
    }
  }

  /// Matches all active digests and revalidates the matched record after the
  /// asynchronous P1 lookup. A sibling's commit does not invalidate that row.
  /// Never opens or caches a P0 [ExternalSession] for a brand-new client while
  /// the device is locked (`!foreground.acceptsNew`).
  Future<AndroidHttpAuthResult> authenticateRequest(
    List<String>? authorizationHeaders,
  ) async {
    final window = _enable;
    if (window == null || !window.ready || !_isCurrent(window)) {
      return const AndroidHttpUnauthenticated();
    }
    final token = AndroidHttpTokenCodec.parseBearerHeader(authorizationHeaders);
    if (token == null) return const AndroidHttpUnauthenticated();
    final candidateDigest = AndroidHttpTokenCodec.digestToken(token);
    try {
      final active = await associations.listActive();
      ExternalCredentialAssociation? matched;
      for (final record in active.records) {
        final sameDigest = AndroidHttpTokenCodec.constantTimeDigestEquals(
          record.credentialIdentity,
          candidateDigest,
        );
        if (sameDigest && record.installationId == installationId) {
          matched = record;
        }
      }
      if (matched == null || !active.isRecordCurrent(matched)) {
        return const AndroidHttpUnauthenticated();
      }
      final profileId = matched.profileId;
      final reference = _references[profileId];
      final principal = _principals[profileId];
      if (reference == null || principal == null) {
        return const AndroidHttpUnauthenticated();
      }
      final current = await _readHttpProfile(reference);
      if (!_isCurrent(window) ||
          _revoking.contains(profileId) ||
          current.profile.revokedAtUtcMs != null ||
          !foreground.allowsHttpReadGrant(current.grant) ||
          !active.isRecordCurrent(matched) ||
          trust.snapshot(principal).state !=
              PairingState.enabledForCurrentRuntime) {
        return const AndroidHttpUnauthenticated();
      }
      final existing = _sessions[profileId];
      if (existing != null && existing.failure == null) {
        return AndroidHttpAuthenticated(existing);
      }
      if (!foreground.acceptsNew) {
        return AndroidHttpLockedNewClientRefused(profileId);
      }
      final session = credentialPort._withAuth(
        matched.credentialIdentity,
        (ticket) {
          final peer = trust.authenticate(ticket);
          if (!identical(peer.principal, principal)) {
            throw const ExternalCoreException(
                ExternalFailure.authenticationRejected);
          }
          return trust.openSession(peer);
        },
      );
      _sessions[profileId] = session;
      return AndroidHttpAuthenticated(session);
    } catch (_) {
      return const AndroidHttpUnauthenticated();
    }
  }

  /// Convenience wrapper returning the admitted [ExternalSession], or `null`
  /// when unauthenticated or refused as a brand-new client while locked.
  Future<ExternalSession?> authenticateAuthorizationHeader(
    List<String>? authorizationHeaders,
  ) async =>
      switch (await authenticateRequest(authorizationHeaders)) {
        AndroidHttpAuthenticated(:final session) => session,
        AndroidHttpLockedNewClientRefused() ||
        AndroidHttpUnauthenticated() =>
          null,
      };

  /// Withdraw the target before any durable I/O. A failure closes the entire
  /// Enable window while keeping the original Profile identity for retry.
  Future<void> revokeClient(String profileId) => _revokeClient(profileId);

  Future<void> _revokeClient(String profileId,
      {int? expectedGrantRevision}) async {
    if (!_revoking.add(profileId)) {
      credentialFail(ExternalCredentialFailure.resourceLimit);
    }
    try {
      final known = _references[profileId];
      final reference = known ?? await management.selectProfile(profileId);
      if (known == null || expectedGrantRevision != null) {
        await _readHttpProfile(reference,
            expectedGrantRevision: expectedGrantRevision);
      }
      final existingSession = _revokeLocal(profileId);
      try {
        await onProfileRevoked?.call(profileId, existingSession);
        await _revokeAssociation(reference,
            expectedGrantRevision: expectedGrantRevision);
        await _revokeDurableProfile(reference,
            expectedGrantRevision: expectedGrantRevision);
        await _forgetRevokedProfile(reference);
      } catch (_) {
        disableAllActiveClients();
        await onRevokeFailureWithdrawEnable();
        rethrow;
      }
    } finally {
      _revoking.remove(profileId);
    }
  }

  ExternalSession? _revokeLocal(String id) {
    final session = _sessions.remove(id);
    final principal = _principals[id];
    if (principal != null &&
        trust.snapshot(principal).state != PairingState.revoked) {
      trust.revoke(principal);
    }
    return session;
  }

  Future<void> _revokeAssociation(
    ExternalProfileReference reference, {
    String? unpublishedDigest,
    int? expectedGrantRevision,
  }) async {
    final profileId = reference.profileId;
    final current = await associations.read(profileId);
    final record = current.record;
    if (record == null || record.revoked) return;
    if (record.installationId != installationId ||
        (unpublishedDigest != null &&
            (record.revision != 1 ||
                record.credentialIdentity != unpublishedDigest))) {
      credentialFail(ExternalCredentialFailure.staleRevision);
    }
    await associations.revoke(
      profileId: profileId,
      expectedRevision: record.revision,
      validateManagement: () async {
        await _readHttpProfile(reference,
            expectedGrantRevision: expectedGrantRevision);
      },
    );
  }

  Future<void> _revokeDurableProfile(
    ExternalProfileReference reference, {
    int? expectedGrantRevision,
  }) async {
    final current = await _readHttpProfile(reference,
        expectedGrantRevision: expectedGrantRevision);
    if (current.profile.revokedAtUtcMs == null) {
      await management.revokeProfile(reference, current.profile.grantRevision);
    }
  }

  Future<void> _forgetRevokedProfile(ExternalProfileReference reference) async {
    final id = reference.profileId;
    final principal = _principals[id];
    if (principal != null) {
      await admission.releaseRevokedIdentity(reference, principal);
    }
    _references.remove(id);
    _principals.remove(id);
  }

  /// Re-issuance is strictly "revoke old Profile preserving tombstone + create
  /// a brand-new Profile & Token" (no in-place silent credential overwrite).
  Future<AndroidIssuedClientToken> reissueClient({
    required String oldProfileId,
    String? newDisplayName,
    ExternalGrantPolicy? policyOverride,
  }) async {
    if (_reissuing || _issuing != 0 || _preparingEnable) {
      credentialFail(ExternalCredentialFailure.resourceLimit);
    }
    _reissuing = true;
    try {
      final oldRef = _references[oldProfileId] ??
          await management.selectProfile(oldProfileId);
      final oldRecord = await _readHttpProfile(oldRef);
      final displayName = newDisplayName ?? oldRecord.profile.displayName;
      final oldGrant = oldRecord.grant;
      if (policyOverride == null &&
          (oldRecord.profile.revokedAtUtcMs != null ||
              oldGrant == null ||
              oldGrant.revokedAtUtcMs != null ||
              oldGrant.profileId != oldProfileId ||
              oldGrant.revision != oldRecord.profile.grantRevision)) {
        credentialFail(ExternalCredentialFailure.unauthorized);
      }
      final policy = policyOverride ?? oldGrant!.policy;
      final expectedGrantRevision =
          policyOverride == null ? oldRecord.profile.grantRevision : null;
      // Keep other issuance and Enable preparations out until the replacement
      // consumes the capacity checked here.
      if (!trust.hasProfileCapacity && !_principals.containsKey(oldProfileId)) {
        credentialFail(ExternalCredentialFailure.resourceLimit);
      }
      await associations.checkHttpReplacementCapacity(oldProfileId);
      await _revokeClient(oldProfileId,
          expectedGrantRevision: expectedGrantRevision);
      return await _issueClient(
          displayName: displayName, initialPolicy: policy);
    } finally {
      _reissuing = false;
    }
  }

  ExternalSession? activeSessionFor(String profileId) {
    final session = _sessions[profileId];
    if (!enableWindowOpen || session == null || session.failure != null) {
      return null;
    }
    return session;
  }

  Future<ExternalPrincipal> _bindIdentity(ExternalProfileReference reference,
      {void Function()? validateSelection}) async {
    final principal = await trust.registerExistingProfile(reference, management,
        validateSelection: validateSelection);
    _references[reference.profileId] = reference;
    _principals[reference.profileId] = principal;
    await admission.bindIdentity(reference, principal,
        validateSelection: validateSelection);
    return principal;
  }

  String _preparePairing(ExternalPrincipal principal, String digest) {
    final requestId = mintRequestId();
    trust.requestPairing(principal,
        requestId: requestId, credentialIdentity: digest);
    trust.approvePairing(principal);
    return requestId;
  }

  void _completePairing(
    ExternalPrincipal principal,
    String requestId,
    String digest,
  ) {
    credentialPort._withProof(
      requestId,
      digest,
      (ticket) => trust.completePairing(principal, ticket),
    );
  }

  bool _isHttpProfile(ExternalClientProfile profile) =>
      profile.adapter == AndroidHttpTokenCodec.adapterName &&
      profile.protocol == AndroidHttpTokenCodec.protocolName;

  Future<ExternalAuthorizationRecord> _readHttpProfile(
      ExternalProfileReference reference,
      {int? expectedGrantRevision}) async {
    final record = await management.read(reference);
    if (record.profile.clientProfileId != reference.profileId ||
        !_isHttpProfile(record.profile)) {
      credentialFail(ExternalCredentialFailure.unauthorized);
    }
    if (expectedGrantRevision != null &&
        (record.profile.revokedAtUtcMs != null ||
            record.profile.grantRevision != expectedGrantRevision)) {
      credentialFail(ExternalCredentialFailure.staleRevision);
    }
    return record;
  }
}
