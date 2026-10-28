import 'dart:async';
import 'dart:typed_data';

import '../../application/external/external_authorization.dart';
import '../../application/external/external_credential_association.dart';
import 'association_object_codec.dart';

/// Native owns encryption, the fixed no-backup object, and conditional replace.
/// No method exposes private keys. Construction performs no platform I/O.
abstract interface class AndroidAssociationBackend {
  bool get isCurrent;
  Future<AndroidAssociationLease> begin();
}

abstract interface class AndroidAssociationLease {
  Uint8List? get plaintext;
  bool get isCurrent;
  Future<void> commit(Uint8List plaintext);
  Future<void> close();
}

/// Original P15 port over an explicitly acquired, single-owner Native backend.
final class AndroidAssociationStore
    implements
        ExternalCredentialAssociationStore,
        ExternalCredentialIdentityLookup {
  AndroidAssociationStore(this.backend, {required int Function() nowUtcMs})
      : _now = nowUtcMs;
  final AndroidAssociationBackend backend;
  final int Function() _now;
  Future<void> _tail = Future.value();
  int _epoch = 0, _pending = 0;
  bool _closed = false;
  static const maxRecords = 64, maxBytes = 65536;

  void _guard() {
    if (_closed || !backend.isCurrent) {
      _epoch++;
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    }
  }

  Future<T> _run<T>(Future<T> Function(AndroidAssociationLease) action) async {
    _guard();
    if (_pending >= 16) credentialFail(ExternalCredentialFailure.resourceLimit);
    _pending++;
    final previous = _tail, done = Completer<void>();
    _tail = done.future;
    AndroidAssociationLease? lease;
    try {
      await previous;
      _guard();
      lease = await backend.begin();
      _guard();
      if (!lease.isCurrent) {
        credentialFail(ExternalCredentialFailure.staleRevision);
      }
      return await action(lease);
    } on ExternalCredentialException {
      // An observed outage/corruption must not later revive old snapshots.
      _epoch++;
      rethrow;
    } catch (_) {
      _epoch++;
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    } finally {
      try {
        await lease?.close();
      } catch (_) {
        _closed = true;
        _epoch++;
        credentialFail(ExternalCredentialFailure.commitUnknown);
      } finally {
        _pending--;
        done.complete();
      }
    }
  }

  List<AssociationObjectRecord> _read(AndroidAssociationLease lease) {
    final bytes = lease.plaintext;
    try {
      if (bytes == null) return [];
      if (bytes.length > maxBytes) {
        credentialFail(ExternalCredentialFailure.dataCorrupt);
      }
      final records = AssociationObjectCodec.decode(bytes);
      if (records.length > maxRecords ||
          records.where((r) => !r.association.revoked).length > 1) {
        credentialFail(ExternalCredentialFailure.dataCorrupt);
      }
      return List.of(records);
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
    }
  }

  void _id(String value) {
    if (!ExternalAuthLimits.validId(value)) {
      credentialFail(ExternalCredentialFailure.invalidInput);
    }
  }

  ExternalCredentialAssociationSnapshot _snapshot(
          ExternalCredentialAssociation? record) =>
      _AndroidSnapshot(this, record, _epoch);

  @override
  Future<ExternalCredentialAssociationSnapshot> read(String profileId) =>
      _run((lease) async {
        _id(profileId);
        final matches =
            _read(lease).where((r) => r.association.profileId == profileId);
        return _snapshot(matches.isEmpty ? null : matches.single.association);
      });

  @override
  Future<ExternalCredentialAssociationSnapshot> findCredential(
          String identity) =>
      _run((lease) async {
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(identity)) {
          credentialFail(ExternalCredentialFailure.invalidInput);
        }
        final matches = _read(lease).where((r) =>
            !r.association.revoked &&
            r.association.credentialIdentity == identity);
        return _snapshot(matches.isEmpty ? null : matches.single.association);
      });

  @override
  Future<ExternalCredentialAssociationSnapshot> register(
          {required String profileId,
          required String installationId,
          required String credentialIdentity,
          required int expectedRevision,
          required Future<void> Function() validateManagement}) =>
      _write(profileId, expectedRevision, installationId, credentialIdentity,
          validateManagement);

  @override
  Future<ExternalCredentialAssociationSnapshot> revoke(
          {required String profileId,
          required int expectedRevision,
          required Future<void> Function() validateManagement}) =>
      _write(profileId, expectedRevision, null, null, validateManagement);

  Future<ExternalCredentialAssociationSnapshot> _write(
          String id,
          int revision,
          String? installation,
          String? identity,
          Future<void> Function() validate) =>
      _run((lease) async {
        _id(id);
        if (revision < 0 || revision > ExternalAuthLimits.maxRevision) {
          credentialFail(ExternalCredentialFailure.invalidInput);
        }
        final records = _read(lease);
        final index = records.indexWhere((r) => r.association.profileId == id);
        final old = index < 0 ? null : records[index].association;
        if ((old?.revision ?? 0) != revision) {
          credentialFail(ExternalCredentialFailure.staleRevision);
        }
        final revoke = identity == null;
        if (!revoke) {
          AssociationObjectCodec.validateAssociation(
              ExternalCredentialAssociation(
                  profileId: id,
                  installationId: installation!,
                  credentialIdentity: identity,
                  revision: 1,
                  revoked: false),
              failure: ExternalCredentialFailure.invalidInput);
          if (records.any(
              (r) => !r.association.revoked && r.association.profileId != id)) {
            credentialFail(ExternalCredentialFailure.conflict);
          }
          if (old != null &&
              !old.revoked &&
              (old.credentialIdentity != identity ||
                  old.installationId != installation)) {
            credentialFail(ExternalCredentialFailure.conflict);
          }
        }
        await validate();
        _guard();
        if (!lease.isCurrent) {
          credentialFail(ExternalCredentialFailure.staleRevision);
        }
        if ((revoke && (old == null || old.revoked)) ||
            (!revoke && old != null && !old.revoked)) {
          return _snapshot(old);
        }
        if (revision == ExternalAuthLimits.maxRevision ||
            (index < 0 && records.length >= maxRecords)) {
          credentialFail(ExternalCredentialFailure.resourceLimit);
        }
        final updated = ExternalCredentialAssociation(
            profileId: id,
            installationId: installation ?? old!.installationId,
            credentialIdentity: identity ?? old!.credentialIdentity,
            revision: revision + 1,
            revoked: revoke);
        final row = AssociationObjectRecord(updated, _now());
        if (index < 0) {
          records.add(row);
        } else {
          records[index] = row;
        }
        final bytes = AssociationObjectCodec.encode(records);
        try {
          if (bytes.length > maxBytes) {
            credentialFail(ExternalCredentialFailure.resourceLimit);
          }
          await validate();
          _guard();
          if (!lease.isCurrent) {
            credentialFail(ExternalCredentialFailure.staleRevision);
          }
          _epoch++;
          await lease.commit(bytes);
          _guard();
          return _snapshot(updated);
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      });

  Future<void> close() async {
    _closed = true;
    _epoch++;
    await _tail;
  }
}

final class _AndroidSnapshot implements ExternalCredentialAssociationSnapshot {
  _AndroidSnapshot(this.owner, this.record, this.epoch);
  final AndroidAssociationStore owner;
  final int epoch;
  bool _invalid = false;
  @override
  final ExternalCredentialAssociation? record;
  @override
  bool get isCurrent {
    _invalid |=
        owner._closed || !owner.backend.isCurrent || owner._epoch != epoch;
    return !_invalid;
  }
}
