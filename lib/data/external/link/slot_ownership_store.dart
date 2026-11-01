import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../bounded_json_object.dart';
import 'link_installation.dart';
import 'link_state_store.dart';
import 'link_values.dart';
import 'registration_evidence.dart';

/// Non-secret custody, never a device credential or an Application grant.
final class SlotOwnershipRecord {
  SlotOwnershipRecord(Map<String, dynamic> value)
      : value = Map.unmodifiable(value) {
    linkFields(value, {
      'formatVersion',
      'slotRef',
      'operationId',
      'initializationSource',
      'ownershipState',
      'ownerKind',
      'ownerInstanceId',
      'ownerGeneration',
      'verifiedInstallationBinding',
      'adapterCredentialSlotRef',
      'resourceGeneration',
      'lastSettlementRef',
      'lastSettlementState',
      'revision',
      if (value['formatVersion'] == 2) ...[
        'registration',
        'sourceDigest',
        'adoption'
      ]
    });
    final registered = value['formatVersion'] == 2;
    if ((!registered && value['formatVersion'] != 1) ||
        !{'new_pairing', 'registered_pairing'}
            .contains(value['initializationSource']) ||
        !(registered
                ? {'REGISTERING', 'SEALED', 'ADOPT_PENDING', 'LINK_OWNED'}
                : {'UNCLAIMED', 'LINK_OWNED'})
            .contains(value['ownershipState']) ||
        !{'UNKNOWN', 'DIRTY', 'CLEAN'}.contains(value['lastSettlementState']) ||
        value['ownerKind'] !=
            (registered &&
                    {'REGISTERING', 'SEALED'}.contains(value['ownershipState'])
                ? 'independent_registrar'
                : 'independent_link')) {
      linkFail('invalid_state');
    }
    for (final key in ['slotRef', 'operationId', 'ownerInstanceId']) {
      linkToken(value[key]);
    }
    for (final key in [
      'ownerGeneration',
      'adapterCredentialSlotRef',
      'resourceGeneration',
      'lastSettlementRef'
    ]) {
      if (value[key] != null) linkToken(value[key]);
    }
    linkRevision(value['revision']);
    if (value['verifiedInstallationBinding'] != null) {
      LinkVerifiedTarget.fromJson(
          value['verifiedInstallationBinding'] as Map<String, dynamic>);
    }
    if (owned &&
        (target == null ||
            value['ownerGeneration'] == null ||
            value['adapterCredentialSlotRef'] != 'device.dpapi' ||
            value['lastSettlementRef'] == null)) {
      linkFail('invalid_state');
    }
    if (!registered && !owned && value['ownerGeneration'] != null ||
        value['lastSettlementState'] == 'CLEAN' &&
            (target == null || value['lastSettlementRef'] == null)) {
      linkFail('invalid_state');
    }
    if (registered) {
      final registration = value['registration'] as Map<String, dynamic>;
      RegistrationEvidence.registration(registration);
      final registrar =
          {'REGISTERING', 'SEALED'}.contains(value['ownershipState']);
      if (value['initializationSource'] != 'registered_pairing' ||
          registrar &&
              (value['ownerInstanceId'] !=
                      registration['registrarInstanceId'] ||
                  value['operationId'] != registration['operationId'] ||
                  value['ownerGeneration'] != registration['generation']) ||
          value['ownershipState'] == 'REGISTERING' &&
              (value['sourceDigest'] != null ||
                  value['adoption'] != null ||
                  target != null ||
                  value['adapterCredentialSlotRef'] != null ||
                  value['lastSettlementRef'] != null ||
                  value['lastSettlementState'] != 'UNKNOWN') ||
          !owned && value['resourceGeneration'] != registration['resourceId'] ||
          {'SEALED', 'ADOPT_PENDING'}.contains(value['ownershipState']) &&
              value['lastSettlementState'] != 'CLEAN' ||
          value['ownershipState'] != 'REGISTERING' &&
              (target == null ||
                  value['lastSettlementRef'] == null ||
                  value['adapterCredentialSlotRef'] != 'device.dpapi')) {
        linkFail();
      }
      if (value['ownershipState'] != 'REGISTERING') {
        linkToken(value['sourceDigest'], digest: true);
      }
      if (registrar) {
        if (value['adoption'] != null) {
          linkFail();
        }
      } else {
        final adoption = value['adoption'] as Map<String, dynamic>;
        linkFields(adoption, {'connectorInstanceId', 'operationId'});
        if (adoption['connectorInstanceId'] != value['ownerInstanceId'] ||
            adoption['operationId'] != value['operationId'] ||
            value['ownerGeneration'] != value['operationId']) {
          linkFail();
        }
      }
    }
  }

  final Map<String, dynamic> value;
  bool get registered => value['formatVersion'] == 2;
  bool get owned => value['ownershipState'] == 'LINK_OWNED';
  int get revision => value['revision'] as int;
  String get operationId => value['operationId'] as String;
  LinkVerifiedTarget? get target => value['verifiedInstallationBinding'] == null
      ? null
      : LinkVerifiedTarget.fromJson(
          value['verifiedInstallationBinding'] as Map<String, dynamic>);
  SlotOwnershipRecord change(Map<String, Object?> fields) =>
      SlotOwnershipRecord({
        ...value,
        ...fields,
        'revision': revision + 1,
      });
}

/// Short control lock. Never holds adapter.lock or waits for TLS/user input.
final class SlotOwnershipStore {
  static final _held = <String>{};
  SlotOwnershipStore(this.installation);
  final LinkInstallation installation;
  Directory get directory => Directory(installation.slotDirectory);
  File file(String name) => File(p.join(directory.path, name));

  Future<T> locked<T>(Future<T> Function() action) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      linkFail('invalid_configuration');
    }
    final path = file('slot-ownership.lock');
    if (await FileSystemEntity.type(path.path, followLinks: false) ==
        FileSystemEntityType.link) {
      linkFail('invalid_state');
    }
    final key = Platform.isWindows
        ? p.normalize(path.path).toLowerCase()
        : p.normalize(path.path);
    if (!_held.add(key)) linkFail('slot_busy');
    RandomAccessFile? lock;
    var acquired = false;
    try {
      lock = await path.open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      acquired = true;
      return await action();
    } on FileSystemException {
      linkFail('slot_busy');
    } finally {
      try {
        if (acquired) await lock!.unlock();
        await lock?.close();
      } finally {
        _held.remove(key);
      }
    }
  }

  Future<Map<String, dynamic>> readJson(String name) async =>
      boundedJsonObject(await readBoundedLinkFile(file(name)),
          maxBytes: linkStateLimit);

  /// These files belong to another protocol. Detection does not migrate them.
  Future<void> rejectLegacy() async {
    if (await file('host-handoff.pending').exists()) {
      linkFail('legacy_status_unknown');
    }
    if (await file('host-handoff.json').exists()) {
      final old = await readJson('host-handoff.json');
      // Even malformed or incomplete records remain authoritative obstacles.
      linkFail(old['phase'] == 'CLAIMED'
          ? 'legacy_link_recovery_required'
          : 'legacy_retirement_required');
    }
    for (final name in ['link-state.json', 'link-state.pending']) {
      if (await File(p.join(installation.stateDirectory, name)).exists()) {
        linkFail('legacy_link_recovery_required');
      }
    }
  }

  Future<SlotOwnershipRecord?> readAnyLocked() async {
    await rejectLegacy();
    if (await file('slot-ownership.pending').exists()) {
      linkFail('recovery_required');
    }
    if (!await file('slot-ownership.json').exists()) return null;
    final record = SlotOwnershipRecord(await readJson('slot-ownership.json'));
    if (record.value['slotRef'] != installation.slotRef) {
      linkFail('owner_conflict');
    }
    return record;
  }

  Future<SlotOwnershipRecord?> readLocked() async {
    final record = await readAnyLocked();
    if (record == null) return null;
    if (record.value['slotRef'] != installation.slotRef ||
        record.value['ownerInstanceId'] != installation.connectorInstanceId ||
        record.operationId != installation.operationId) {
      linkFail('owner_conflict');
    }
    return record;
  }

  Future<void> writeLocked(SlotOwnershipRecord next, int? expectedRevision,
      {bool transfer = false}) async {
    final current = transfer ? await readAnyLocked() : await readLocked();
    if (current?.revision != expectedRevision ||
        next.revision !=
            (expectedRevision == null ? 0 : expectedRevision + 1)) {
      linkFail('stale_revision');
    }
    final bytes = utf8.encode(jsonEncode(next.value));
    final pending = file('slot-ownership.pending');
    final handle = await pending.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await pending.rename(file('slot-ownership.json').path);
    if (jsonEncode((await readAnyLocked())!.value) != jsonEncode(next.value)) {
      linkFail();
    }
  }

  Future<void> requireNoUnsettledFiles() async {
    for (final name in [
      'native-client-key.pending',
      'device.pending',
      'link-settlement.pending',
      'adapter-origin.pending'
    ]) {
      if (await file(name).exists()) linkFail('recovery_required');
    }
  }

  /// Provenance must pre-exist an historical import and name its original
  /// adapter resource. Neither pairing ciphertext nor installer flags supply it.
  Future<Map<String, dynamic>> readPairingOrigin() async {
    final origin = await readJson('adapter-origin.json');
    linkFields(origin, {
      'formatVersion',
      'slotRef',
      'origin',
      'operationId',
      'target',
      'credentialSlotRef',
      'resourceGeneration',
      'settlementRef'
    });
    if (origin['formatVersion'] != 1 ||
        origin['slotRef'] != installation.slotRef ||
        origin['origin'] != 'independent_adapter_pairing' ||
        origin['credentialSlotRef'] != 'device.dpapi') {
      linkFail('legacy_status_unknown');
    }
    linkToken(origin['operationId']);
    linkToken(origin['resourceGeneration']);
    linkToken(origin['settlementRef']);
    LinkVerifiedTarget.fromJson(origin['target'] as Map<String, dynamic>);
    final receipt = await receiptFor(origin['resourceGeneration'] as String);
    if (receipt['mode'] != 'pairing' ||
        receipt['operationId'] != origin['operationId'] ||
        receipt['receiptRef'] != origin['settlementRef'] ||
        jsonEncode(receipt['target']) != jsonEncode(origin['target'])) {
      linkFail('recovery_required');
    }
    return origin;
  }

  Future<Map<String, dynamic>> registeredPairing() async {
    final custody = await readAnyLocked();
    if (custody?.registered == true) {
      final evidence = RegistrationEvidence(directory.path);
      await evidence.noPending();
      return evidence.verify(custody!.value);
    }
    return _registeredPairingV1();
  }

  // Only prepare's locked, validated v1 publication may read this evidence
  // while its own owner pending exists. Ordinary readers retain their fence.
  Future<Map<String, dynamic>> _registeredPairingV1() async {
    if (await file('initialization-joined.pending').exists()) linkFail();
    final origin = await readPairingOrigin();
    final receipt = await receiptFor(origin['resourceGeneration'] as String);
    _requireInitializationJoin(
        await readJson('initialization-joined.json'), receipt);
    return origin;
  }

  void _requireInitializationJoin(
      Map<String, dynamic> joined, Map<String, dynamic> receipt) {
    linkFields(joined, {
      'formatVersion',
      'operationId',
      'slotRef',
      'ownerInstanceId',
      'runId',
      'resourceId',
      'processId',
      'processStarted',
      'adapterReceiptRef',
      'target',
      'processExitCode',
      'stdinClosed',
      'stdoutDrained',
      'stderrDrained'
    });
    if (joined['formatVersion'] != 1 ||
        joined['processExitCode'] != 0 ||
        joined['stdinClosed'] != true ||
        joined['stdoutDrained'] != true ||
        joined['stderrDrained'] != true ||
        joined['ownerInstanceId'] != receipt['owner'] ||
        joined['adapterReceiptRef'] != receipt['receiptRef'] ||
        jsonEncode(joined['target']) != jsonEncode(receipt['target'])) {
      linkFail();
    }
    for (final field in [
      'operationId',
      'slotRef',
      'runId',
      'resourceId',
      'processId',
      'processStarted'
    ]) {
      if (joined[field] != receipt[field]) linkFail();
    }
  }

  /// Called by the owning process runner only AFTER successful original exit
  /// and stdin/stdout/stderr settlement, never from a PID/marker observation.
  Future<void> publishInitializationJoin(
          LinkOwnerReference owner, LinkVerifiedTarget target) =>
      locked(() async {
        final record = await readLocked();
        if (record == null || record.owned) linkFail();
        await requireNoUnsettledFiles();
        final origin = await readPairingOrigin();
        final receipt =
            await receiptFor(origin['resourceGeneration'] as String);
        if (origin['operationId'] != installation.operationId ||
            receipt['owner'] != installation.connectorInstanceId ||
            receipt['runId'] != owner.runId ||
            receipt['resourceId'] != owner.resourceId ||
            receipt['processId'] != owner.processId ||
            receipt['processStarted'] != owner.processStarted ||
            jsonEncode(receipt['target']) != jsonEncode(target.toJson())) {
          linkFail();
        }
        final joined = <String, dynamic>{
          'formatVersion': 1,
          'operationId': installation.operationId,
          'slotRef': installation.slotRef,
          'ownerInstanceId': installation.connectorInstanceId,
          'runId': owner.runId,
          'resourceId': owner.resourceId,
          'processId': owner.processId,
          'processStarted': owner.processStarted,
          'adapterReceiptRef': receipt['receiptRef'],
          'target': target.toJson(),
          'processExitCode': 0,
          'stdinClosed': true,
          'stdoutDrained': true,
          'stderrDrained': true,
        };
        _requireInitializationJoin(joined, receipt);
        if (await file('initialization-joined.json').exists()) {
          if (jsonEncode(await readJson('initialization-joined.json')) !=
              jsonEncode(joined)) {
            linkFail();
          }
          return;
        }
        if (await file('initialization-joined.pending').exists()) linkFail();
        final handle = await file('initialization-joined.pending')
            .open(mode: FileMode.writeOnly);
        try {
          await handle.writeString(jsonEncode(joined));
          await handle.flush();
        } finally {
          await handle.close();
        }
        await file('initialization-joined.pending')
            .rename(file('initialization-joined.json').path);
        _requireInitializationJoin(
            await readJson('initialization-joined.json'), receipt);
      });

  Future<void> _resumeInitializationJoin(SlotOwnershipRecord current) async {
    final pending = file('initialization-joined.pending');
    if (!await pending.exists()) return;
    if (current.owned || await file('initialization-joined.json').exists()) {
      linkFail();
    }
    await requireNoUnsettledFiles();
    final origin = await readPairingOrigin();
    final receipt = await receiptFor(origin['resourceGeneration'] as String);
    final joined = await readJson('initialization-joined.pending');
    _requireInitializationJoin(joined, receipt);
    if (joined['operationId'] != current.operationId ||
        joined['ownerInstanceId'] != current.value['ownerInstanceId']) {
      linkFail();
    }
    await pending.rename(file('initialization-joined.json').path);
  }

  Future<Map<String, dynamic>> receiptFor(String resource) async {
    final receipt = await readJson('link-settlement.json');
    linkFields(receipt, {
      'formatVersion',
      'operationId',
      'receiptRef',
      'runId',
      'resourceId',
      'processId',
      'processStarted',
      'slotRef',
      'owner',
      'mode',
      'target',
      'targetClose',
      'tlsShutdown',
      'keyRetired'
    });
    if (receipt['formatVersion'] != 2 ||
        receipt['slotRef'] != installation.slotRef ||
        receipt['resourceId'] != resource ||
        receipt['targetClose'] != true ||
        receipt['tlsShutdown'] != true ||
        receipt['keyRetired'] != true) {
      linkFail();
    }
    for (final key in [
      'operationId',
      'receiptRef',
      'runId',
      'resourceId',
      'processStarted',
      'owner'
    ]) {
      linkToken(receipt[key]);
    }
    if (linkRevision(receipt['processId']) == 0) linkFail();
    LinkVerifiedTarget.fromJson(receipt['target'] as Map<String, dynamic>);
    return receipt;
  }

  /// Called only after native admission of the explicitly launched Link.
  Future<SlotOwnershipRecord> prepare() => locked(() async {
        await rejectLegacy();
        final pending = file('slot-ownership.pending');
        if (await pending.exists()) {
          final next =
              SlotOwnershipRecord(await readJson('slot-ownership.pending'));
          final current = await file('slot-ownership.json').exists()
              ? SlotOwnershipRecord(await readJson('slot-ownership.json'))
              : null;
          if (next.registered ||
              current?.registered == true ||
              next.operationId != installation.operationId ||
              next.value['ownerInstanceId'] !=
                  installation.connectorInstanceId ||
              next.value['slotRef'] != installation.slotRef ||
              current?.owned == true ||
              next.revision != (current == null ? 0 : current.revision + 1) ||
              current != null &&
                  (current.value['slotRef'] != next.value['slotRef'] ||
                      current.operationId != next.operationId ||
                      current.value['initializationSource'] !=
                          next.value['initializationSource'] ||
                      current.value['ownerInstanceId'] !=
                          next.value['ownerInstanceId'])) {
            linkFail();
          }
          if (next.owned) {
            // An owner publication always has its original preparation. Do not
            // turn an orphan pending or a v2 adoption into v1 initialization.
            if (current == null) linkFail();
            await requireNoUnsettledFiles();
            final origin = await _registeredPairingV1();
            final receipt =
                await receiptFor(origin['resourceGeneration'] as String);
            if (next.value['ownerGeneration'] != current.operationId ||
                next.value['adapterCredentialSlotRef'] !=
                    origin['credentialSlotRef'] ||
                next.value['resourceGeneration'] !=
                    origin['resourceGeneration'] ||
                next.value['lastSettlementState'] != 'CLEAN' ||
                next.value['lastSettlementRef'] != origin['settlementRef'] ||
                jsonEncode(next.target!.toJson()) !=
                    jsonEncode(origin['target']) ||
                current.value['initializationSource'] == 'new_pairing' &&
                    (origin['operationId'] != current.operationId ||
                        receipt['owner'] != current.value['ownerInstanceId'] ||
                        current.value['resourceGeneration'] != null &&
                            origin['resourceGeneration'] !=
                                current.value['resourceGeneration'])) {
              linkFail();
            }
          }
          await pending.rename(file('slot-ownership.json').path);
        }
        final current = await readLocked();
        if (current != null) {
          if (current.registered) {
            if (!{'ADOPT_PENDING', 'LINK_OWNED'}
                .contains(current.value['ownershipState'])) {
              linkFail();
            }
            await registeredPairing();
            return current;
          }
          await _resumeInitializationJoin(current);
          return current;
        }
        await requireNoUnsettledFiles();
        final paired = await file('device.dpapi').exists();
        Map<String, dynamic>? origin;
        if (paired) {
          if (!await file('adapter-origin.json').exists()) {
            linkFail('legacy_status_unknown');
          }
          origin = await registeredPairing();
        } else {
          // Absence of a new record alone is insufficient. Fresh registration
          // requires an empty installation-selected slot, apart from our lock.
          await for (final entry in directory.list(followLinks: false)) {
            if (p.basename(entry.path) != 'slot-ownership.lock') {
              linkFail('legacy_status_unknown');
            }
          }
        }
        final prepared = SlotOwnershipRecord({
          'formatVersion': 1,
          'slotRef': installation.slotRef,
          'operationId': installation.operationId,
          'initializationSource': paired ? 'registered_pairing' : 'new_pairing',
          'ownershipState': 'UNCLAIMED',
          'ownerKind': 'independent_link',
          'ownerInstanceId': installation.connectorInstanceId,
          'ownerGeneration': null,
          'verifiedInstallationBinding': origin?['target'],
          'adapterCredentialSlotRef': origin?['credentialSlotRef'],
          'resourceGeneration': origin?['resourceGeneration'],
          'lastSettlementRef': origin?['settlementRef'],
          'lastSettlementState': origin == null ? 'UNKNOWN' : 'CLEAN',
          'revision': 0,
        });
        await writeLocked(prepared, null);
        return prepared;
      });

  Future<LinkVerifiedTarget> requireOwned(LinkState state) => locked(() async {
        if (await file('initialization-joined.pending').exists()) linkFail();
        final record = await readLocked();
        if (record == null ||
            !record.owned ||
            state.initializationOperationId != record.operationId ||
            state.ownerGeneration != record.value['ownerGeneration'] ||
            state.targetRef != record.value['slotRef'] ||
            record.value['lastSettlementState'] != 'CLEAN' ||
            state.dirtyPhase != LinkDirtyPhase.clean) {
          linkFail('recovery_required');
        }
        await requireNoUnsettledFiles();
        return record.target!;
      });
}
