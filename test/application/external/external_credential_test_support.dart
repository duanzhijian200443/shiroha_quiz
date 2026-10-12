import 'dart:async';

import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/application/external/external_credential_boundary.dart';

/// Synthetic association authority: never stores keys, touches OS or enters DI.
final class MemoryExternalAssociations
    implements ExternalCredentialAssociationStore {
  final records = <String, ExternalCredentialAssociation>{};
  int _epoch = 0;
  ExternalCredentialFailure? _failure;
  ExternalCredentialFailure? get failure => _failure;
  set failure(ExternalCredentialFailure? value) {
    _epoch++;
    _failure = value;
  }

  Completer<void>? reached, resume;
  bool unknownAfterCommit = false;
  Future<void> _tail = Future<void>.value();
  void _available() {
    if (_failure != null) credentialFail(_failure!);
  }

  ExternalCredentialAssociationSnapshot _view(String id) =>
      _MemoryAssociationSnapshot(this, id, records[id], _epoch);
  @override
  Future<ExternalCredentialAssociationSnapshot> read(String profileId) async {
    _available();
    return _view(profileId);
  }

  Future<ExternalCredentialAssociationSnapshot> _write(
      String id,
      int revision,
      Future<void> Function() validate,
      bool revoke,
      String? install,
      String? identity) async {
    final previous = _tail;
    final settled = Completer<void>();
    _tail = settled.future;
    await previous;
    try {
      _available();
      if (reached != null && !reached!.isCompleted) reached!.complete();
      await resume?.future;
      await validate();
      _available();
      final old = records[id];
      if ((old?.revision ?? 0) != revision) {
        credentialFail(ExternalCredentialFailure.staleRevision);
      }
      if (!revoke) {
        if (records.values.any((r) =>
            !r.revoked &&
            r.profileId != id &&
            r.credentialIdentity == identity)) {
          credentialFail(ExternalCredentialFailure.conflict);
        }
        if (old != null && !old.revoked) {
          if (old.installationId != install ||
              old.credentialIdentity != identity) {
            credentialFail(ExternalCredentialFailure.conflict);
          }
          return _view(id); // CAS precedes idempotency.
        }
      } else if (old == null || old.revoked) {
        return _view(id);
      }
      if (revision >= 2147483647) {
        credentialFail(ExternalCredentialFailure.dataCorrupt);
      }
      records[id] = ExternalCredentialAssociation(
          profileId: id,
          installationId: revoke ? old!.installationId : install!,
          credentialIdentity: revoke ? old!.credentialIdentity : identity!,
          revision: revision + 1,
          revoked: revoke);
      if (unknownAfterCommit) {
        credentialFail(ExternalCredentialFailure.commitUnknown);
      }
      return _view(id);
    } finally {
      settled.complete();
    }
  }

  @override
  Future<ExternalCredentialAssociationSnapshot> register(
          {required String profileId,
          required String installationId,
          required String credentialIdentity,
          required int expectedRevision,
          required Future<void> Function() validateManagement}) =>
      _write(profileId, expectedRevision, validateManagement, false,
          installationId, credentialIdentity);
  @override
  Future<ExternalCredentialAssociationSnapshot> revoke(
          {required String profileId,
          required int expectedRevision,
          required Future<void> Function() validateManagement}) =>
      _write(profileId, expectedRevision, validateManagement, true, null, null);
}

final class _MemoryAssociationSnapshot
    implements ExternalCredentialAssociationSnapshot {
  _MemoryAssociationSnapshot(this.owner, this.id, this.record, this.epoch);
  final MemoryExternalAssociations owner;
  final String id;
  @override
  final ExternalCredentialAssociation? record;
  final int epoch;
  @override
  bool get isCurrent =>
      owner.failure == null &&
      epoch == owner._epoch &&
      identical(owner.records[id], record);
}

/// Test-only possession/event registry. It verifies no real cryptography.
final class SyntheticCredentialVerifier
    implements ExternalCredentialVerificationPort {
  final _owned = Set<Object>.identity();
  ExternalCredentialChallenge? observed;
  Completer<void>? reached, resume;
  Object event(
      {required String profile,
      bool pairing = false,
      String identity = 'verified-leaf',
      String installation = 'offline-install',
      int generation = 1,
      int revision = 0,
      String? request = 'registration'}) {
    final result = _SyntheticCredentialEvent(profile, installation, generation,
        identity, revision, pairing ? request : null, pairing);
    _owned.add(result);
    return result;
  }

  void disconnect(Object event) {
    if (event is _SyntheticCredentialEvent) event.closed = true;
  }

  @override
  bool isLive(Object event) =>
      _owned.contains(event) &&
      event is _SyntheticCredentialEvent &&
      !event.closed;
  Future<bool> _verify(
      ExternalCredentialChallenge challenge, Object event, bool pairing) async {
    observed = challenge;
    if (reached != null && !reached!.isCompleted) reached!.complete();
    await resume?.future;
    final valid = isLive(event) &&
        event is _SyntheticCredentialEvent &&
        event.pairing == pairing &&
        event.profile == challenge.profileId &&
        event.installation == challenge.installationId &&
        event.generation == challenge.generation &&
        event.identity == challenge.credentialIdentity &&
        event.revision == challenge.revision &&
        event.request == challenge.requestId;
    if (!valid) {
      return false;
    }
    // A synthetic event pins the exact first verified runtime, not its number.
    event.runtimeInstance ??= challenge.runtimeInstance;
    return identical(event.runtimeInstance, challenge.runtimeInstance);
  }

  @override
  Future<bool> verifyPairing(
          ExternalCredentialChallenge challenge, Object attempt) =>
      _verify(challenge, attempt, true);
  @override
  Future<bool> verifyAuthentication(
          ExternalCredentialChallenge challenge, Object attempt) =>
      _verify(challenge, attempt, false);
}

final class _SyntheticCredentialEvent {
  _SyntheticCredentialEvent(this.profile, this.installation, this.generation,
      this.identity, this.revision, this.request, this.pairing);
  final String profile, installation, identity;
  final int generation, revision;
  final String? request;
  final bool pairing;
  bool closed = false;
  Object? runtimeInstance;
}
