import 'dart:convert';
import '../../application/backup/backup_restore_gate.dart';
import '../../core/database/database_helper.dart';
import '../../services/backup/sha256.dart';
import '../external/bounded_json_object.dart';
import '../external/link/host_handoff.dart';
import '../external/link/link_values.dart';
import 'generated_local_authority_repository.dart';

/// Constructed only by the Windows App. Independent Link never imports this.
final class LegacyLinkHandoffRepository implements OldHostReleaseAuthority {
  LegacyLinkHandoffRepository(
      {required this.database,
      required this.slotRef,
      required this.closeOriginalOwners,
      required this.readOriginalBinding});
  final DatabaseHelper database;
  final String slotRef;
  final Future<void> Function() closeOriginalOwners;
  final Future<LinkVerifiedTarget> Function() readOriginalBinding;
  static const selectionKey = 'external_device_selection_v1';
  static const releaseKey = 'external_link_handoff_release_v1';
  bool _frozen = false;
  Future<void> _freeze() async {
    await closeOriginalOwners();
    _frozen = true;
  }

  @override
  Future<HostHandoffRecord> freezeAndSettle(String newOwner) async {
    await _freeze();
    final raw = await database.getSetting(selectionKey);
    if (raw == null || raw.length > linkStateLimit) {
      linkFail('old_owner_unresolved');
    }
    final value = boundedJsonObject(utf8.encode(raw), maxBytes: linkStateLimit);
    linkFields(
        value, {'version', 'kind', 'reference', 'generation', 'needsCleanup'});
    if (value['version'] != 1 ||
        value['kind'] != 'android' ||
        value['reference'] != slotRef ||
        value['needsCleanup'] != false) {
      linkFail('old_owner_unresolved');
    }
    final generation = linkRevision(value['generation']);
    final owner = await database
        .getSetting(GeneratedLocalAuthorityRepository.ownerSettingKey);
    if (owner == null) linkFail('old_owner_unresolved');
    final target = await readOriginalBinding();
    // v1 has no separate row revision: the exact raw digest + generation is
    // its CAS identity. No newly invented historical clean/instance fact.
    return HostHandoffRecord(
        handoffId: linkNonce(),
        handoffRevision: 0,
        slotRef: slotRef,
        target: target,
        oldOwnerInstance: linkToken(owner),
        oldSelectionGeneration: generation,
        oldStateRevision: generation,
        oldStateDigest: sha256Hex(utf8.encode(raw)),
        releaseRecordRef: linkNonce(),
        newOwner: newOwner,
        newLinkStateRevision: 0,
        phase: HostHandoffPhase.prepared);
  }

  @override
  Future<bool> releaseCommitted(HostHandoffRecord prepared) async {
    await _freeze();
    final raw = await database.getSetting(releaseKey);
    if (raw == null) return false;
    if (raw != jsonEncode(prepared.toJson())) linkFail('handoff_conflict');
    final tombstone = await database.getSetting(selectionKey);
    if (tombstone != _tombstone(prepared)) linkFail('handoff_conflict');
    return true;
  }

  String _tombstone(HostHandoffRecord value) => jsonEncode({
        'version': 2,
        'state': 'released',
        'handoffId': value.handoffId,
        'releaseRecordRef': value.releaseRecordRef
      });
  @override
  Future<void> commitRelease(HostHandoffRecord prepared) =>
      BackupRestoreMutationGate.instance.runMutation(() async {
        if (!_frozen) linkFail('old_owner_unresolved');
        final db = await database.database;
        await db.transaction((txn) async {
          final rows = await txn
              .query('app_settings', where: 'key=?', whereArgs: [selectionKey]);
          final owners = await txn.query('app_settings',
              where: 'key=?',
              whereArgs: [GeneratedLocalAuthorityRepository.ownerSettingKey]);
          final releases = await txn
              .query('app_settings', where: 'key=?', whereArgs: [releaseKey]);
          if (rows.length != 1 ||
              owners.length != 1 ||
              owners.single['value'] != prepared.oldOwnerInstance ||
              releases.isNotEmpty ||
              rows.single['value'] is! String ||
              sha256Hex(utf8.encode(rows.single['value'] as String)) !=
                  prepared.oldStateDigest) {
            linkFail('handoff_conflict');
          }
          await txn.insert('app_settings',
              {'key': releaseKey, 'value': jsonEncode(prepared.toJson())});
          final changed = await txn.update(
              'app_settings', {'value': _tombstone(prepared)},
              where: 'key=? AND value=?',
              whereArgs: [selectionKey, rows.single['value']]);
          if (changed != 1 || !_frozen) linkFail('handoff_conflict');
        });
      });
}
