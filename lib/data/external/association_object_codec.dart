import 'dart:convert';
import 'dart:typed_data';

import '../../application/external/external_authorization.dart';
import '../../application/external/external_credential_association.dart';

/// Backend bookkeeping is deliberately absent from the P15 port record.
final class AssociationObjectRecord {
  const AssociationObjectRecord(this.association, this.updatedAtUtcMs);
  final ExternalCredentialAssociation association;
  final int updatedAtUtcMs;
  @override
  String toString() => 'AssociationObjectRecord(REDACTED)';
}

/// Frozen kind 3 plaintext only; no crypto, files or authentication authority.
abstract final class AssociationObjectCodec {
  static const maxRecords = 64, maxBytes = 65536;
  static const _header = [83, 72, 82, 69, 88, 79, 66, 74, 1, 3];
  static final _identity = RegExp(r'^[0-9a-fA-F]{64}$');

  static void validateAssociation(ExternalCredentialAssociation a,
      {ExternalCredentialFailure failure =
          ExternalCredentialFailure.dataCorrupt}) {
    if (!ExternalAuthLimits.validId(a.profileId) ||
        !ExternalAuthLimits.validId(a.installationId) ||
        utf8.encode(a.installationId).length > 128 ||
        !_identity.hasMatch(a.credentialIdentity) ||
        a.revision < 1 ||
        a.revision > ExternalAuthLimits.maxRevision) {
      credentialFail(failure);
    }
  }

  static void _validate(List<AssociationObjectRecord> records) {
    if (records.length > maxRecords) {
      credentialFail(ExternalCredentialFailure.dataCorrupt);
    }
    final profiles = <String>{}, active = <String>{};
    for (final r in records) {
      final a = r.association;
      validateAssociation(a);
      if (r.updatedAtUtcMs < 0 ||
          r.updatedAtUtcMs > ExternalAuthLimits.maxTime ||
          !profiles.add(a.profileId) ||
          (!a.revoked && !active.add(a.credentialIdentity.toLowerCase()))) {
        credentialFail(ExternalCredentialFailure.dataCorrupt);
      }
    }
  }

  static Uint8List encode(List<AssociationObjectRecord> records) {
    _validate(records);
    final out = BytesBuilder(copy: false)..add(_header);
    void number(int n, int size) {
      final b = ByteData(size);
      if (size == 2) b.setUint16(0, n, Endian.little);
      if (size == 4) b.setUint32(0, n, Endian.little);
      if (size == 8) b.setUint64(0, n, Endian.little);
      out.add(b.buffer.asUint8List());
    }

    number(records.length, 4);
    for (final r in records) {
      final a = r.association;
      out.addByte(1);
      out.add(_hexBytes(a.profileId.replaceAll('-', '')));
      final installation = utf8.encode(a.installationId);
      number(installation.length, 2);
      out.add(installation);
      out.add(_hexBytes(a.credentialIdentity));
      number(a.revision, 8);
      out.addByte(a.revoked ? 1 : 0);
      number(r.updatedAtUtcMs, 8);
    }
    final bytes = out.takeBytes();
    if (bytes.length > maxBytes) {
      credentialFail(ExternalCredentialFailure.dataCorrupt);
    }
    return bytes;
  }

  static List<AssociationObjectRecord> decode(Uint8List bytes) {
    try {
      if (bytes.length > maxBytes) {
        credentialFail(ExternalCredentialFailure.dataCorrupt);
      }
      final cursor = _Cursor(bytes);
      for (final b in _header) {
        if (cursor.number(1) != b) {
          credentialFail(ExternalCredentialFailure.dataCorrupt);
        }
      }
      final count = cursor.number(4);
      if (count > maxRecords) {
        credentialFail(ExternalCredentialFailure.dataCorrupt);
      }
      final records = <AssociationObjectRecord>[];
      for (var i = 0; i < count; i++) {
        if (cursor.number(1) != 1) {
          credentialFail(ExternalCredentialFailure.dataCorrupt);
        }
        final raw = _hex(cursor.take(16));
        final profile = '${raw.substring(0, 8)}-${raw.substring(8, 12)}-'
            '${raw.substring(12, 16)}-${raw.substring(16, 20)}-${raw.substring(20)}';
        final length = cursor.number(2);
        if (length > 128) credentialFail(ExternalCredentialFailure.dataCorrupt);
        final installation =
            utf8.decode(cursor.take(length), allowMalformed: false);
        final identity = _hex(cursor.take(32));
        final revision = cursor.number(8), revoked = cursor.number(1);
        final updated = cursor.number(8);
        if (revoked > 1) credentialFail(ExternalCredentialFailure.dataCorrupt);
        records.add(AssociationObjectRecord(
            ExternalCredentialAssociation(
                profileId: profile,
                installationId: installation,
                credentialIdentity: identity,
                revision: revision,
                revoked: revoked == 1),
            updated));
      }
      if (cursor.offset != bytes.length) {
        credentialFail(ExternalCredentialFailure.dataCorrupt);
      }
      _validate(records);
      return List.unmodifiable(records);
    } on ExternalCredentialException {
      rethrow;
    } catch (_) {
      credentialFail(ExternalCredentialFailure.dataCorrupt);
    }
  }

  static Uint8List _hexBytes(String s) => Uint8List.fromList([
        for (var i = 0; i < s.length; i += 2)
          int.parse(s.substring(i, i + 2), radix: 16)
      ]);
  static String _hex(Uint8List b) =>
      b.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
}

final class _Cursor {
  _Cursor(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  Uint8List take(int count) {
    if (count < 0 || count > bytes.length - offset) {
      credentialFail(ExternalCredentialFailure.dataCorrupt);
    }
    final result = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return result;
  }

  int number(int size) {
    final b = ByteData.sublistView(take(size));
    return switch (size) {
      1 => b.getUint8(0),
      2 => b.getUint16(0, Endian.little),
      4 => b.getUint32(0, Endian.little),
      8 => b.getUint64(0, Endian.little),
      _ => throw StateError('invalid width'),
    };
  }
}
