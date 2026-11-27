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
  AndroidAssociationStore(
    this.backend, {
    required int Function() nowUtcMs,
    this.maxActiveAssociations = 1,
  }) : _now = nowUtcMs {
    if (maxActiveAssociations < 1 || maxActiveAssociations > maxRecords) {
      throw ArgumentError.value(
        maxActiveAssociations,
        'maxActiveAssociations',
        'Must be between 1 and $maxRecords',
      );
    }
  }

  /// Creates an association store bounded to Android HTTP multi-client custody
  /// (at most 16 concurrent active client profiles, preserving up to 64 total
  /// records including monotonic revocation tombstones).
  factory AndroidAssociationStore.forHttp(
    AndroidAssociationBackend backend, {
    required int Function() nowUtcMs,
  }) =>
      AndroidAssociationStore(
        backend,
        nowUtcMs: nowUtcMs,
        maxActiveAssociations: defaultHttpMaxActiveAssociations,
      );

  final AndroidAssociationBackend backend;
  final int Function() _now;
  final int maxActiveAssociations;
  Future<void> _tail = Future.value();
  int _epoch = 0, _pending = 0, _invalidatedAt = 0;
  final _changedAt = <String, int>{};
  bool _closed = false;
  static const maxRecords = 64, maxBytes = 65536;
  static const defaultHttpMaxActiveAssociations = 16;

  void _invalidateSnapshots() => _invalidatedAt = ++_epoch;

  void _guard() {
    if (_closed || !backend.isCurrent) {
      _invalidateSnapshots();
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
      _invalidateSnapshots();
      rethrow;
    } catch (_) {
      _invalidateSnapshots();
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    } finally {
      try {
        await lease?.close();
      } catch (_) {
        _closed = true;
        _invalidateSnapshots();
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
      final active = records.where((r) => !r.association.revoked).toList();
      if (records.length > maxRecords ||
          active.length > maxActiveAssociations ||
          records.map((r) => r.association.profileId).toSet().length !=
              records.length ||
          active.map((r) => r.association.credentialIdentity).toSet().length !=
              active.length) {
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

  /// Returns a monotonic read-only snapshot of all currently active
  /// (non-revoked) associations, ordered deterministically by profileId.
  Future<AndroidActiveAssociationsSnapshot> listActive() => _run((lease) async {
        final active = _read(lease)
            .where((r) => !r.association.revoked)
            .map((r) => r.association)
            .toList()
          ..sort((a, b) => a.profileId.compareTo(b.profileId));
        return AndroidActiveAssociationsSnapshot._(
          this,
          List.unmodifiable(active),
          _epoch,
        );
      });

  /// Portable B0 can scrub SQLite Profiles while retaining this installation's
  /// protected store. Preserve the revoked digests and the total record bound.
  Future<void> retireOrphanedHttpAssociations({
    required String installationId,
    required Future<bool> Function(String) profileIsMissing,
    required void Function() validateManagement,
  }) =>
      _run((lease) async {
        final records = _read(lease);
        final retired = <String>[];
        for (var index = 0; index < records.length; index++) {
          final old = records[index].association;
          if (old.revoked ||
              old.installationId != installationId ||
              !await profileIsMissing(old.profileId)) {
            continue;
          }
          if (old.revision == ExternalAuthLimits.maxRevision) {
            credentialFail(ExternalCredentialFailure.resourceLimit);
          }
          records[index] = AssociationObjectRecord(
            ExternalCredentialAssociation(
              profileId: old.profileId,
              installationId: old.installationId,
              credentialIdentity: old.credentialIdentity,
              revision: old.revision + 1,
              revoked: true,
            ),
            _now(),
          );
          retired.add(old.profileId);
        }
        if (retired.isEmpty) return;
        await _commit(lease, records, retired, validate: validateManagement);
      });

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
          (_) => validateManagement());

  /// Reserves capacity under the original Native lease before the first-party
  /// owner creates the Profile. [prepareProfile] must not reenter this store.
  Future<ExternalCredentialAssociationSnapshot> registerNewHttpAssociation({
    required String installationId,
    required String credentialIdentity,
    required Future<String> Function() prepareProfile,
    required Future<void> Function(String) validateManagement,
  }) =>
      _write(null, 0, installationId, credentialIdentity, validateManagement,
          prepareProfile: prepareProfile);

  /// A replacement can reuse the old client's active slot. The tombstone
  /// still occupies a durable record, so check both limits before revocation.
  Future<void> checkHttpReplacementCapacity(String oldProfileId) =>
      _run((lease) async {
        _id(oldProfileId);
        _requireNewProfileCapacity(_read(lease),
            replacingProfileId: oldProfileId);
      });

  @override
  Future<ExternalCredentialAssociationSnapshot> revoke(
          {required String profileId,
          required int expectedRevision,
          required Future<void> Function() validateManagement}) =>
      _write(
          profileId, expectedRevision, null, null, (_) => validateManagement());

  void _requireNewProfileCapacity(
    List<AssociationObjectRecord> records, {
    String? replacingProfileId,
  }) {
    final otherActive = records.where((row) =>
        !row.association.revoked &&
        row.association.profileId != replacingProfileId);
    if (records.length >= maxRecords ||
        otherActive.length >= maxActiveAssociations) {
      credentialFail(ExternalCredentialFailure.resourceLimit);
    }
  }

  Future<String> _reserveNewProfile(
    List<AssociationObjectRecord> records,
    String identity,
    Future<String> Function() prepareProfile,
  ) async {
    _requireNewProfileCapacity(records);
    if (records.any((row) => row.association.credentialIdentity == identity)) {
      credentialFail(ExternalCredentialFailure.conflict);
    }
    final id = await prepareProfile();
    _id(id);
    return id;
  }

  Future<ExternalCredentialAssociationSnapshot> _write(
          String? existingId,
          int revision,
          String? installation,
          String? identity,
          Future<void> Function(String) validate,
          {Future<String> Function()? prepareProfile}) =>
      _run((lease) async {
        if (existingId != null) _id(existingId);
        if (revision < 0 || revision > ExternalAuthLimits.maxRevision) {
          credentialFail(ExternalCredentialFailure.invalidInput);
        }
        final records = _read(lease);
        final id = existingId ??
            await _reserveNewProfile(records, identity!, prepareProfile!);
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
          if (records.any((r) =>
              !r.association.revoked &&
              r.association.profileId != id &&
              r.association.credentialIdentity == identity)) {
            credentialFail(ExternalCredentialFailure.conflict);
          }
          final otherActiveCount = records
              .where((r) =>
                  !r.association.revoked && r.association.profileId != id)
              .length;
          if (otherActiveCount >= maxActiveAssociations) {
            credentialFail(
              maxActiveAssociations == 1
                  ? ExternalCredentialFailure.conflict
                  : ExternalCredentialFailure.resourceLimit,
            );
          }
          if (old != null &&
              !old.revoked &&
              (old.credentialIdentity != identity ||
                  old.installationId != installation)) {
            credentialFail(ExternalCredentialFailure.conflict);
          }
        }
        await validate(id);
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
        await validate(id);
        await _commit(lease, records, [id]);
        return _snapshot(updated);
      });

  Future<void> _commit(
    AndroidAssociationLease lease,
    List<AssociationObjectRecord> records,
    Iterable<String> changedProfiles, {
    void Function()? validate,
  }) async {
    final bytes = AssociationObjectCodec.encode(records);
    try {
      if (bytes.length > maxBytes) {
        credentialFail(ExternalCredentialFailure.resourceLimit);
      }
      validate?.call();
      _guard();
      if (!lease.isCurrent) {
        credentialFail(ExternalCredentialFailure.staleRevision);
      }
      for (final id in changedProfiles) {
        _changedAt[id] = ++_epoch;
      }
      await lease.commit(bytes);
      _guard();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> close() async {
    _closed = true;
    _invalidateSnapshots();
    await _tail;
  }
}

final class AndroidActiveAssociationsSnapshot {
  AndroidActiveAssociationsSnapshot._(this._owner, this.records, this._epoch);

  final AndroidAssociationStore _owner;
  final List<ExternalCredentialAssociation> records;
  final int _epoch;
  bool _unavailable = false;

  bool get _canUse {
    _unavailable |= _owner._closed ||
        !_owner.backend.isCurrent ||
        _owner._invalidatedAt > _epoch;
    return !_unavailable;
  }

  bool get isCurrent => _canUse && _owner._epoch == _epoch;

  /// Sibling commits keep this row current. Storage failure or any attempted
  /// mutation of this exact Profile invalidates it permanently.
  bool isRecordCurrent(ExternalCredentialAssociation record) =>
      _canUse &&
      records.contains(record) &&
      (_owner._changedAt[record.profileId] ?? 0) <= _epoch;
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
