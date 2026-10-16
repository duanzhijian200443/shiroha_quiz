import 'dart:async';
import 'dart:typed_data';

import '../../application/external/external_authorization.dart';
import '../../application/external/external_credential_association.dart';
import 'association_object_codec.dart';
import 'native/windows_external_native.dart';

/// Unactivated production P15 backend. Caller supplies an explicitly acquired
/// App owner and retains its OS lock through store drain and owner close.
final class WindowsCredentialAssociationStore
    implements
        ExternalCredentialAssociationStore,
        ExternalCredentialIdentityLookup {
  WindowsCredentialAssociationStore(this._owner, {int Function()? nowUtcMs})
      : _now =
            nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);
  final ExternalProtectedObjects _owner;
  final int Function() _now;
  Future<void> _tail = Future.value();
  int _pending = 0, _epoch = 0;
  bool _closed = false;

  Future<T> _run<T>(Future<T> Function() work) async {
    if (_closed) {
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    }
    if (_pending >= 16) credentialFail(ExternalCredentialFailure.resourceLimit);
    _pending++;
    final previous = _tail, settled = Completer<void>();
    _tail = settled.future;
    await previous;
    try {
      _guard();
      return await work();
    } finally {
      _pending--;
      settled.complete();
    }
  }

  void _guard() {
    if (_closed) {
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    }
    _native(_owner.ensureOpen);
  }

  T _native<T>(T Function() operation) {
    try {
      return operation();
    } on ExternalNativeException catch (e) {
      credentialFail(switch (e.failure) {
        ExternalNativeFailure.dataCorrupt =>
          ExternalCredentialFailure.dataCorrupt,
        ExternalNativeFailure.resourceLimit =>
          ExternalCredentialFailure.resourceLimit,
        ExternalNativeFailure.commitUnknown =>
          ExternalCredentialFailure.commitUnknown,
        _ => ExternalCredentialFailure.temporarilyUnavailable,
      });
    } catch (_) {
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    }
  }

  void _invalidate() {
    _epoch++;
    _owner.invalidateAssociationSnapshots();
  }

  void _id(String id) {
    if (!ExternalAuthLimits.validId(id)) {
      credentialFail(ExternalCredentialFailure.invalidInput);
    }
  }

  List<AssociationObjectRecord> _load(ExternalAssociationTransaction txn) {
    Uint8List? plaintext;
    try {
      final encrypted = txn.encrypted;
      final records = encrypted == null
          ? <AssociationObjectRecord>[]
          : AssociationObjectCodec.decode((plaintext =
              _native(() => _owner.unprotectAssociation(encrypted)))!);
      final revisions = {
        for (final r in records) r.association.profileId: r.association.revision
      };
      _native(() => _owner.observeAssociationRevisions(revisions));
      return List.of(records);
    } catch (_) {
      _invalidate();
      rethrow;
    } finally {
      plaintext?.fillRange(0, plaintext.length, 0);
    }
  }

  ExternalAssociationTransaction _begin() {
    try {
      return _native(_owner.beginAssociation);
    } catch (_) {
      _invalidate();
      rethrow;
    }
  }

  ExternalCredentialAssociationSnapshot _snapshot(
          ExternalCredentialAssociation? record) =>
      _AssociationSnapshot(this, record, _epoch, _owner.associationEpoch);

  @override
  Future<ExternalCredentialAssociationSnapshot> read(String profileId) =>
      _run(() async {
        _id(profileId);
        final txn = _begin();
        try {
          final records = _load(txn);
          final match =
              records.where((r) => r.association.profileId == profileId);
          _guard();
          return _snapshot(match.isEmpty ? null : match.single.association);
        } finally {
          _native(txn.abort);
        }
      });

  @override
  Future<ExternalCredentialAssociationSnapshot> findCredential(
          String identity) =>
      _run(() async {
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(identity)) {
          credentialFail(ExternalCredentialFailure.invalidInput);
        }
        final txn = _begin();
        try {
          // The existing strict codec enforces global identity uniqueness;
          // no cache, second registry, or client-supplied Profile is consulted.
          final records = _load(txn);
          final matches = records
              .where((r) =>
                  !r.association.revoked &&
                  r.association.credentialIdentity == identity)
              .toList();
          if (matches.length > 1) {
            _invalidate();
            credentialFail(ExternalCredentialFailure.dataCorrupt);
          }
          _guard();
          return _snapshot(matches.isEmpty ? null : matches.single.association);
        } finally {
          _native(txn.abort);
        }
      });

  @override
  Future<ExternalCredentialAssociationSnapshot> register({
    required String profileId,
    required String installationId,
    required String credentialIdentity,
    required int expectedRevision,
    required Future<void> Function() validateManagement,
  }) =>
      _write(profileId, expectedRevision, false, installationId,
          credentialIdentity, validateManagement);
  @override
  Future<ExternalCredentialAssociationSnapshot> revoke({
    required String profileId,
    required int expectedRevision,
    required Future<void> Function() validateManagement,
  }) =>
      _write(profileId, expectedRevision, true, null, null, validateManagement);

  Future<ExternalCredentialAssociationSnapshot> _write(
          String id,
          int revision,
          bool revoke,
          String? installation,
          String? identity,
          Future<void> Function() validate) =>
      _run(() async {
        _id(id);
        if (revision < 0 || revision > ExternalAuthLimits.maxRevision) {
          credentialFail(ExternalCredentialFailure.invalidInput);
        }
        if (!revoke) {
          AssociationObjectCodec.validateAssociation(
              ExternalCredentialAssociation(
                  profileId: id,
                  installationId: installation!,
                  credentialIdentity: identity!,
                  revision: 1,
                  revoked: false),
              failure: ExternalCredentialFailure.invalidInput);
        }
        final txn = _begin();
        Uint8List? plaintext, ciphertext;
        try {
          final records = _load(txn);
          final index =
              records.indexWhere((r) => r.association.profileId == id);
          final old = index < 0 ? null : records[index].association;
          if ((old?.revision ?? 0) != revision) {
            credentialFail(ExternalCredentialFailure.staleRevision);
          }
          var unchanged = revoke && (old == null || old.revoked);
          if (!revoke) {
            identity = identity!.toLowerCase();
            if (records.any((r) =>
                !r.association.revoked &&
                r.association.profileId != id &&
                r.association.credentialIdentity == identity)) {
              credentialFail(ExternalCredentialFailure.conflict);
            }
            if (old != null && !old.revoked) {
              if (old.installationId != installation ||
                  old.credentialIdentity != identity) {
                credentialFail(ExternalCredentialFailure.conflict);
              }
              unchanged = true;
            }
          }
          if (unchanged) {
            await validate();
            _guard();
            return _snapshot(old);
          }
          if (revision == ExternalAuthLimits.maxRevision) {
            credentialFail(ExternalCredentialFailure.dataCorrupt);
          }
          if (index < 0 &&
              records.length >= AssociationObjectCodec.maxRecords) {
            credentialFail(ExternalCredentialFailure.resourceLimit);
          }
          final now = _now();
          if (now < 0 || now > ExternalAuthLimits.maxTime) {
            credentialFail(ExternalCredentialFailure.invalidInput);
          }
          final updated = ExternalCredentialAssociation(
              profileId: id,
              installationId: revoke ? old!.installationId : installation!,
              credentialIdentity: revoke ? old!.credentialIdentity : identity!,
              revision: revision + 1,
              revoked: revoke);
          final row = AssociationObjectRecord(updated, now);
          if (index < 0) {
            records.add(row);
          } else {
            records[index] = row;
          }
          plaintext = AssociationObjectCodec.encode(records);
          ciphertext = _native(() => _owner.protectAssociation(plaintext!));
          // No native file mutation occurs until current management succeeds here.
          await validate();
          _guard();
          _invalidate();
          _native(() => txn.commit(ciphertext!));
          _native(() => _owner.observeAssociationRevisions({
                for (final r in records)
                  r.association.profileId: r.association.revision,
              }));
          _guard();
          return _snapshot(updated);
        } finally {
          plaintext?.fillRange(0, plaintext.length, 0);
          ciphertext?.fillRange(0, ciphertext.length, 0);
          _native(txn.abort);
        }
      });

  /// Immediately invalidates snapshots; waits for admitted work to settle.
  /// Owner close remains the caller's responsibility after this drain.
  Future<void> close() async {
    _closed = true;
    _epoch++;
    await _tail;
  }

  @override
  String toString() => 'WindowsCredentialAssociationStore(REDACTED)';
}

final class _AssociationSnapshot
    implements ExternalCredentialAssociationSnapshot {
  _AssociationSnapshot(this.store, this.record, this.epoch, this.ownerEpoch);
  final WindowsCredentialAssociationStore store;
  @override
  final ExternalCredentialAssociation? record;
  final int epoch, ownerEpoch;
  @override
  bool get isCurrent {
    if (store._closed ||
        epoch != store._epoch ||
        ownerEpoch != store._owner.associationEpoch ||
        !store._owner.isUsable) {
      return false;
    }
    try {
      store._guard();
      return ownerEpoch == store._owner.associationEpoch;
    } catch (_) {
      store._invalidate();
      return false;
    }
  }

  @override
  String toString() => 'ExternalCredentialAssociationSnapshot(REDACTED)';
}
