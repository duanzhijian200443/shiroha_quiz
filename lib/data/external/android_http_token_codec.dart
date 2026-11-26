import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../application/capabilities/capability.dart';
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
  static const adapterName = 'android-http';
  static const protocolName = 'streamable-http';

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

/// Multi-client Android HTTP Bearer Token custody over existing P1/P0/P4/P15
/// stores. Construction performs no I/O and hydrates no credentials at startup.
final class AndroidHttpClientCredentials {
  AndroidHttpClientCredentials({
    required this.associations,
    required this.management,
    required this.trust,
    required this.credentialPort,
    required this.admission,
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

  final Map<String, ExternalProfileReference> _references = {};
  final Map<String, ExternalPrincipal> _principals = {};
  final Map<String, ExternalSession> _sessions = {};
  bool _enableWindowOpen = false;
  DateTime? _enableNotAfter;
  Duration? _enableDuration;

  bool get enableWindowOpen => _enableWindowOpen;

  /// Creates a new SQLite Profile + default READ/questionContent Grant, mints
  /// an independent 256-bit Bearer Token, persists only its domain-separated
  /// SHA-256 in `AndroidAssociationStore`, and pairs it in `ExternalTrustCore`.
  Future<AndroidIssuedClientToken> issueClient({
    required String displayName,
    ExternalGrantPolicy? initialPolicy,
  }) async {
    final policy = initialPolicy ?? androidHttpDefaultReadPolicy();
    final reference = await management.createProfile(
      displayName: displayName,
      adapter: AndroidHttpTokenCodec.adapterName,
      protocol: AndroidHttpTokenCodec.protocolName,
    );
    await management.replaceGrant(reference, 0, policy);
    final token = AndroidHttpTokenCodec.mint(random: _random);
    final digest = AndroidHttpTokenCodec.digestToken(token);
    final snapshot = await associations.register(
      profileId: reference.profileId,
      installationId: installationId,
      credentialIdentity: digest,
      expectedRevision: 0,
      validateManagement: () => _requireActiveProfile(reference),
    );
    final record = snapshot.record;
    if (record == null || record.revoked) {
      credentialFail(ExternalCredentialFailure.dataCorrupt);
    }
    final principal = await _bindAndPair(reference, digest);
    if (_enableWindowOpen &&
        _enableDuration != null &&
        _enableNotAfter != null &&
        trust.clock.now().isBefore(_enableNotAfter!)) {
      final remaining = _enableNotAfter!.difference(trust.clock.now());
      final clamped = remaining > trust.maxEnableDuration
          ? trust.maxEnableDuration
          : remaining;
      trust.enable(principal, clamped, notAfter: _enableNotAfter);
    }
    return AndroidIssuedClientToken(
      profileReference: reference,
      clientProfileId: reference.profileId,
      displayName: displayName,
      token: token,
      credentialIdentity: digest,
      associationRevision: record.revision,
    );
  }

  /// Explicitly enables all currently active, unrevoked HTTP Profiles matching
  /// `installationId` for one bounded local Enable window. Calling this after
  /// stop, expiry, IP change, or restart keeps existing Tokens valid without
  /// re-minting or re-pairing.
  Future<List<String>> enableActiveClients({
    required Duration duration,
    DateTime? notAfter,
  }) async {
    if (duration <= Duration.zero) {
      throw const ExternalCoreException(ExternalFailure.invalidRequest);
    }
    final effectiveDuration =
        duration > trust.maxEnableDuration ? trust.maxEnableDuration : duration;
    final now = trust.clock.now();
    var targetNotAfter = now.add(effectiveDuration);
    if (notAfter != null && notAfter.isBefore(targetNotAfter)) {
      targetNotAfter = notAfter;
    }
    if (!now.isBefore(targetNotAfter)) {
      throw const ExternalCoreException(ExternalFailure.invalidRequest);
    }
    final activeProfiles = await _loadActiveHttpProfiles();
    final enabledIds = <String>[];
    for (final (reference, assoc) in activeProfiles) {
      final principal = await _bindAndPair(reference, assoc.credentialIdentity);
      final state = trust.snapshot(principal).state;
      if (state == PairingState.enabledForCurrentRuntime) {
        trust.disable(principal);
      }
      _sessions.remove(reference.profileId);
      trust.enable(principal, effectiveDuration, notAfter: targetNotAfter);
      enabledIds.add(reference.profileId);
    }
    _enableWindowOpen = true;
    _enableDuration = effectiveDuration;
    _enableNotAfter = targetNotAfter;
    return enabledIds;
  }

  /// Disables the current Enable window without revoking any durable client
  /// Token or SQLite Profile. Subsequent Enable windows (including after an IP
  /// address change) admit the exact same Tokens.
  void disableAllActiveClients() {
    _enableWindowOpen = false;
    _enableDuration = null;
    _enableNotAfter = null;
    for (final principal in _principals.values) {
      final state = trust.snapshot(principal).state;
      if (state == PairingState.enabledForCurrentRuntime) {
        trust.disable(principal);
      }
    }
    _sessions.clear();
  }

  /// Authenticates one HTTP `Authorization` header against active associations
  /// using domain-separated SHA-256 + constant-time digest comparison across
  /// all active records, then returns the Profile's current `ExternalSession`.
  /// Returns `null` on any auth/state failure (HTTP 401).
  Future<ExternalSession?> authenticateAuthorizationHeader(
    List<String>? authorizationHeaders,
  ) async {
    if (!_enableWindowOpen) return null;
    final token = AndroidHttpTokenCodec.parseBearerHeader(authorizationHeaders);
    if (token == null) return null;
    final candidateDigest = AndroidHttpTokenCodec.digestToken(token);
    final activeSnapshots = await associations.listActive();
    ExternalCredentialAssociation? matched;
    for (final record in activeSnapshots.records) {
      final sameDigest = AndroidHttpTokenCodec.constantTimeDigestEquals(
        record.credentialIdentity,
        candidateDigest,
      );
      if (sameDigest &&
          !record.revoked &&
          record.installationId == installationId) {
        matched = record;
      }
    }
    if (matched == null || !activeSnapshots.isCurrent) return null;
    final profileId = matched.profileId;
    final reference = _references[profileId];
    final principal = _principals[profileId];
    if (reference == null || principal == null) return null;
    try {
      final authRecord = await management.read(reference);
      if (authRecord.profile.revokedAtUtcMs != null ||
          authRecord.profile.clientProfileId != profileId) {
        return null;
      }
    } catch (_) {
      return null;
    }
    if (!activeSnapshots.isCurrent) return null;
    final snapshot = trust.snapshot(principal);
    if (snapshot.state != PairingState.enabledForCurrentRuntime) {
      _sessions.remove(profileId);
      return null;
    }
    final existing = _sessions[profileId];
    if (existing != null && existing.failure == null) {
      return existing;
    }
    try {
      final session = credentialPort._withAuth(
        matched.credentialIdentity,
        (ticket) {
          final peer = trust.authenticate(ticket);
          return trust.openSession(peer);
        },
      );
      _sessions[profileId] = session;
      return session;
    } catch (_) {
      _sessions.remove(profileId);
      return null;
    }
  }

  /// Revokes a single client Profile cleanly without disrupting sibling clients.
  ///
  /// Ordering:
  /// 1. Synchronously revoke only the target `ExternalPrincipal` in memory and
  ///    drop its `ExternalSession` + invoke `onProfileRevoked` (so the target
  ///    loses access immediately even before durable commit).
  /// 2. Durably commit `AndroidAssociationStore.revoke` (preserving monotonic
  ///    tombstone) and `ExternalAuthorizationManagement.revokeProfile`.
  /// 3. If either durable revocation fails, FAIL CLOSED by synchronously
  ///    withdrawing the entire Enable window (`disableAllActiveClients` +
  ///    `onRevokeFailureWithdrawEnable`), then rethrow the failure.
  Future<void> revokeClient(String profileId) async {
    final reference =
        _references[profileId] ?? await _selectReference(profileId);
    final principal = _principals[profileId];
    final existingSession = _sessions.remove(profileId);
    if (principal != null) {
      final state = trust.snapshot(principal).state;
      if (state != PairingState.revoked) {
        trust.revoke(principal);
      }
    }
    try {
      if (onProfileRevoked != null) {
        await onProfileRevoked!(profileId, existingSession);
      }
      final currentAssoc = await associations.read(profileId);
      final assocRecord = currentAssoc.record;
      if (assocRecord != null && !assocRecord.revoked) {
        await associations.revoke(
          profileId: profileId,
          expectedRevision: assocRecord.revision,
          validateManagement: () async {
            final rec = await management.read(reference);
            if (rec.profile.clientProfileId != profileId) {
              credentialFail(ExternalCredentialFailure.unauthorized);
            }
          },
        );
      }
      final currentPolicy = await management.read(reference);
      if (currentPolicy.profile.revokedAtUtcMs == null) {
        await management.revokeProfile(
          reference,
          currentPolicy.profile.grantRevision,
        );
      }
      _references.remove(profileId);
      _principals.remove(profileId);
    } catch (_) {
      disableAllActiveClients();
      await onRevokeFailureWithdrawEnable();
      rethrow;
    }
  }

  /// Re-issuance is strictly "revoke old Profile preserving tombstone + create
  /// a brand-new Profile & Token" (no in-place silent credential overwrite).
  Future<AndroidIssuedClientToken> reissueClient({
    required String oldProfileId,
    String? newDisplayName,
    ExternalGrantPolicy? policyOverride,
  }) async {
    final oldRef =
        _references[oldProfileId] ?? await _selectReference(oldProfileId);
    final oldRecord = await management.read(oldRef);
    final displayName = newDisplayName ?? oldRecord.profile.displayName;
    final policy = policyOverride ??
        oldRecord.grant?.policy ??
        androidHttpDefaultReadPolicy();
    await revokeClient(oldProfileId);
    return issueClient(displayName: displayName, initialPolicy: policy);
  }

  ExternalSession? activeSessionFor(String profileId) {
    final session = _sessions[profileId];
    if (session == null || session.failure != null) return null;
    return session;
  }

  Future<ExternalPrincipal> _bindAndPair(
    ExternalProfileReference reference,
    String credentialIdentity,
  ) async {
    final principal =
        await trust.registerExistingProfile(reference, management);
    final state = trust.snapshot(principal).state;
    if (state == PairingState.unpaired) {
      final reqId = mintRequestId();
      trust.requestPairing(
        principal,
        requestId: reqId,
        credentialIdentity: credentialIdentity,
      );
      trust.approvePairing(principal);
      credentialPort._withProof(
        reqId,
        credentialIdentity,
        (ticket) => trust.completePairing(principal, ticket),
      );
    }
    await admission.bindIdentity(reference, principal);
    _references[reference.profileId] = reference;
    _principals[reference.profileId] = principal;
    return principal;
  }

  Future<void> _requireActiveProfile(ExternalProfileReference reference) async {
    final record = await management.read(reference);
    if (record.profile.clientProfileId != reference.profileId ||
        record.profile.revokedAtUtcMs != null) {
      credentialFail(ExternalCredentialFailure.unauthorized);
    }
  }

  Future<ExternalProfileReference> _selectReference(String profileId) async {
    final ref = await management.selectProfile(profileId);
    _references[profileId] = ref;
    return ref;
  }

  Future<List<(ExternalProfileReference, ExternalCredentialAssociation)>>
      _loadActiveHttpProfiles() async {
    final active = await associations.listActive();
    final result =
        <(ExternalProfileReference, ExternalCredentialAssociation)>[];
    for (final assoc in active.records) {
      if (assoc.revoked || assoc.installationId != installationId) continue;
      final reference = _references[assoc.profileId] ??
          await _selectReference(assoc.profileId);
      final record = await management.read(reference);
      if (record.profile.revokedAtUtcMs != null) continue;
      if (record.profile.adapter != AndroidHttpTokenCodec.adapterName ||
          record.profile.protocol != AndroidHttpTokenCodec.protocolName) {
        continue;
      }
      result.add((reference, assoc));
    }
    return result;
  }
}
