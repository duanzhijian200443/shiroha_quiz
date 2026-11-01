import 'dart:io';
import 'package:path/path.dart' as p;
import '../bounded_json_object.dart';
import '../windows_local_relay.dart';
import 'link_adapter_process.dart';
import 'link_installation.dart';
import 'link_state_store.dart';
import 'link_values.dart';
import 'registration_evidence.dart';
import 'slot_ownership_store.dart';

final class PairingRegistration {
  PairingRegistration(this.installation, this.registration);
  final LinkInstallation installation;
  final Map<String, dynamic> registration;
  static Future<PairingRegistration> load() async {
    final root = p.dirname(Platform.resolvedExecutable);
    final value = boundedJsonObject(
        await readBoundedLinkFile(
            File(p.join(root, 'pairing-registration.json')),
            limit: 16384),
        maxBytes: 16384);
    linkFields(value, {
      'version',
      'slotDirectory',
      'slotRef',
      'registrarInstanceId',
      'registrationOperationId',
      'registrationGeneration',
      'runId',
      'resourceId',
      'adapterExecutable',
      'pairingInput'
    });
    if (value['version'] != 1) linkFail();
    final slot = value['slotDirectory'];
    if (slot is! String ||
        !p.isAbsolute(slot) ||
        p.normalize(slot) != slot ||
        p.isWithin(root, slot) ||
        p.equals(root, slot) ||
        value['adapterExecutable'] !=
            p.join(root, 'AndroidDeviceAdapter.exe')) {
      linkFail();
    }
    final registration = <String, dynamic>{
      'registrarInstanceId': value['registrarInstanceId'],
      'operationId': value['registrationOperationId'],
      'generation': value['registrationGeneration'],
      'runId': value['runId'],
      'resourceId': value['resourceId']
    };
    RegistrationEvidence.registration(registration);
    return PairingRegistration(
        LinkInstallation(
            stateDirectory: slot,
            slotDirectory: slot,
            slotRef: linkToken(value['slotRef']),
            connectorInstanceId: registration['registrarInstanceId'] as String,
            operationId: registration['operationId'] as String,
            adapterExecutable: value['adapterExecutable'] as String,
            pairingInput: value['pairingInput'] as Map<String, dynamic>),
        registration);
  }
}

/// No business runtime, state store, IPC or credential plaintext. Lock order:
/// Link lifetime (when present), slot control, adapter resource; never wait for
/// a process/TLS/user while holding either short lock. Native custody callbacks
/// read only and never acquire slot control while adapter.lock is held.
final class LinkRegistration {
  LinkRegistration(this.installation,
      {bool Function(int, String)? processCurrent})
      : slots = SlotOwnershipStore(installation),
        evidence = RegistrationEvidence(installation.slotDirectory),
        processCurrent = processCurrent ?? WindowsLocalRelay.linkProcessCurrent;
  final LinkInstallation installation;
  final SlotOwnershipStore slots;
  final RegistrationEvidence evidence;
  final bool Function(int, String) processCurrent;

  Future<T> resourceLocked<T>(Future<T> Function() action) async {
    final file = slots.file('adapter.lock');
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      linkFail();
    }
    RandomAccessFile? handle;
    var locked = false;
    try {
      handle = await file.open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive);
      locked = true;
      return await action();
    } on FileSystemException {
      linkFail('slot_busy');
    } finally {
      if (locked) await handle!.unlock();
      await handle?.close();
    }
  }

  Future<SlotOwnershipRecord> prepare(Map<String, dynamic> registration) =>
      slots.locked(() async {
        RegistrationEvidence.registration(registration);
        await slots.rejectLegacy();
        if (await slots.file('slot-ownership.pending').exists()) {
          await resourceLocked(resumeSlotPending);
        }
        final current = await slots.readAnyLocked();
        if (current != null) {
          if (!current.registered ||
              !RegistrationEvidence.same(
                  current.value['registration'], registration) ||
              !{'REGISTERING', 'SEALED'}
                  .contains(current.value['ownershipState'])) {
            linkFail('owner_conflict');
          }
          if (current.value['ownershipState'] == 'REGISTERING' &&
              !await slots.file('device.dpapi').exists() &&
              !await slots.file('adapter-pairing-attempt.json').exists()) {
            await evidence.publish('registration-attempt.json', {
              'formatVersion': 1,
              'slotRef': installation.slotRef,
              'registration': registration
            });
          }
          return current;
        }
        // Before creating adapter.lock: only the already-held control lock is allowed.
        await for (final entry in slots.directory.list(followLinks: false)) {
          if (p.basename(entry.path) != 'slot-ownership.lock') {
            linkFail('legacy_status_unknown');
          }
        }
        final next = SlotOwnershipRecord({
          'formatVersion': 2,
          'slotRef': installation.slotRef,
          'operationId': registration['operationId'],
          'initializationSource': 'registered_pairing',
          'ownershipState': 'REGISTERING',
          'ownerKind': 'independent_registrar',
          'ownerInstanceId': registration['registrarInstanceId'],
          'ownerGeneration': registration['generation'],
          'verifiedInstallationBinding': null,
          'adapterCredentialSlotRef': null,
          'resourceGeneration': registration['resourceId'],
          'lastSettlementRef': null,
          'lastSettlementState': 'UNKNOWN',
          'revision': 0,
          'registration': registration,
          'sourceDigest': null,
          'adoption': null
        });
        await slots.writeLocked(next, null);
        await evidence.publish('registration-attempt.json', {
          'formatVersion': 1,
          'slotRef': installation.slotRef,
          'registration': registration
        });
        return next;
      });

  Future<void> run(PairingRegistration config,
      {required void Function() requireCurrent,
      Future<LinkInitializationSupervision> Function()? producer}) async {
    requireCurrent();
    final current = await prepare(config.registration);
    if (current.value['ownershipState'] == 'SEALED') {
      await slots.locked(() => resourceLocked(() async {
            await evidence.noPending();
            await evidence.verify(current.value);
          }));
      return;
    }
    if (await evidence.file('registration-joined.json').exists() ||
        await evidence.file('registration-joined.json.pending').exists()) {
      await seal();
      return;
    }
    if (await slots.file('device.dpapi').exists() ||
        await slots.file('adapter-pairing-attempt.json').exists()) {
      linkFail();
    }
    requireCurrent();
    final result = await (producer?.call() ??
        LinkAdapterProcess.superviseInitialization(installation,
            runId: config.registration['runId'] as String,
            resourceId: config.registration['resourceId'] as String,
            action: '--register-pair'));
    requireCurrent();
    await publishJoin(result);
    await seal();
  }

  Future<void> publishJoin(LinkInitializationSupervision result) =>
      slots.locked(() => resourceLocked(() async {
            final custody = await slots.readLocked();
            if (custody == null ||
                !custody.registered ||
                custody.value['ownershipState'] != 'REGISTERING') {
              linkFail();
            }
            await slots.requireNoUnsettledFiles();
            final origin = await evidence.original(custody.value);
            final receipt = await evidence.read('registration-receipt.json');
            final owner = result.owner;
            final join = <String, dynamic>{
              'formatVersion': 1,
              'operationId': installation.operationId,
              'slotRef': installation.slotRef,
              'ownerInstanceId': installation.connectorInstanceId,
              'runId': owner.runId,
              'resourceId': owner.resourceId,
              'processId': owner.processId,
              'processStarted': owner.processStarted,
              'adapterReceiptRef': origin['settlementRef'],
              'target': result.target.toJson(),
              'processExitCode': 0,
              'stdinClosed': true,
              'stdoutDrained': true,
              'stderrDrained': true
            };
            RegistrationEvidence.requireJoin(join, receipt);
            await evidence.publish('registration-joined.json', join);
          }));

  Future<void> seal() => slots.locked(() => resourceLocked(() async {
        final current = await slots.readLocked();
        if (current == null ||
            !current.registered ||
            current.value['ownershipState'] != 'REGISTERING') {
          linkFail();
        }
        await slots.requireNoUnsettledFiles();
        // Only a complete original join pending may finish its atomic publication.
        if (await evidence.file('registration-joined.json.pending').exists()) {
          final joined =
              await evidence.read('registration-joined.json.pending');
          RegistrationEvidence.requireJoin(
              joined, await evidence.read('registration-receipt.json'));
          await evidence.publish('registration-joined.json', joined);
        }
        final origin =
            await evidence.verify(current.value, requireManifest: false);
        final receipt = await evidence.read('registration-receipt.json');
        if (processCurrent(
            receipt['processId'] as int, receipt['processStarted'] as String)) {
          linkFail();
        }
        final hashes = <String, dynamic>{};
        for (final name in [
          'registration-attempt.json',
          'registration-receipt.json',
          'registration-origin.json',
          'registration-joined.json'
        ]) {
          hashes[name] = await evidence.digest(name);
        }
        await evidence.publish('registration-source.json', {
          'formatVersion': 1,
          'slotRef': installation.slotRef,
          'registration': current.value['registration'],
          'files': hashes
        });
        await evidence.noPending();
        final next = current.change({
          'ownershipState': 'SEALED',
          'verifiedInstallationBinding': origin['target'],
          'adapterCredentialSlotRef': 'device.dpapi',
          'lastSettlementRef': origin['settlementRef'],
          'lastSettlementState': 'CLEAN',
          'sourceDigest': await evidence.digest('registration-source.json')
        });
        await slots.writeLocked(next, current.revision);
      }));

  Future<void> requireAdoption(SlotOwnershipRecord custody) async {
    await slots.requireNoUnsettledFiles();
    await evidence.noPending();
    await evidence.verify(custody.value);
    await _validateAdoptionJoin(
        custody, await evidence.read('registration-adoption-joined.json'));
  }

  Future<void> _validateAdoptionJoin(
      SlotOwnershipRecord custody, Map<String, dynamic> join) async {
    linkFields(join, {
      'formatVersion',
      'connectorInstanceId',
      'operationId',
      'sourceDigest',
      'owner',
      'target',
      'processExitCode',
      'stdinClosed',
      'stdoutDrained',
      'stderrDrained'
    });
    final owner =
        LinkOwnerReference.fromJson(join['owner'] as Map<String, dynamic>);
    if (join['formatVersion'] != 1 ||
        join['connectorInstanceId'] != installation.connectorInstanceId ||
        join['operationId'] != installation.operationId ||
        join['sourceDigest'] != custody.value['sourceDigest'] ||
        owner.slotRef != installation.slotRef ||
        owner.processId < 1 ||
        processCurrent(owner.processId, owner.processStarted) ||
        !RegistrationEvidence.same(
            join['target'], custody.value['verifiedInstallationBinding']) ||
        join['processExitCode'] != 0 ||
        join['stdinClosed'] != true ||
        join['stdoutDrained'] != true ||
        join['stderrDrained'] != true) {
      linkFail();
    }
  }

  Future<SlotOwnershipRecord?> adopt(
      {Future<LinkInitializationSupervision> Function()? inspect}) async {
    var current = await slots.locked(() async {
      if (await slots.file('slot-ownership.pending').exists()) {
        await resourceLocked(resumeSlotPending);
      }
      return slots.readAnyLocked();
    });
    if (current == null || !current.registered) return current;
    if (current.value['ownershipState'] == 'REGISTERING') {
      linkFail('registration_incomplete');
    }
    if (current.value['ownershipState'] != 'SEALED') {
      await slots.locked(() => slots.readLocked());
      return current;
    }
    final snapshot = current;
    await slots.locked(() => resourceLocked(() async {
          await slots.requireNoUnsettledFiles();
          if (!await evidence
              .file('registration-adoption-joined.json.pending')
              .exists()) {
            await evidence.noPending();
          }
          await evidence.verify(snapshot.value);
        }));
    if (!await evidence.file('registration-adoption-joined.json').exists() &&
        !await evidence
            .file('registration-adoption-joined.json.pending')
            .exists()) {
      final result = await (inspect?.call() ??
          LinkAdapterProcess.superviseInitialization(installation,
              runId: linkNonce(),
              resourceId: linkNonce(),
              action: '--link-inspect-registration'));
      await slots.locked(() => resourceLocked(() async {
            current = await slots.readAnyLocked();
            if (current == null ||
                !RegistrationEvidence.same(current!.value, snapshot.value)) {
              linkFail('stale_revision');
            }
            await evidence.verify(current!.value);
            if (!RegistrationEvidence.same(
                result.target.toJson(), snapshot.target!.toJson())) {
              linkFail();
            }
            await evidence.publish('registration-adoption-joined.json', {
              'formatVersion': 1,
              'connectorInstanceId': installation.connectorInstanceId,
              'operationId': installation.operationId,
              'sourceDigest': snapshot.value['sourceDigest'],
              'owner': result.owner.toJson(),
              'target': result.target.toJson(),
              'processExitCode': 0,
              'stdinClosed': true,
              'stdoutDrained': true,
              'stderrDrained': true
            });
          }));
    }
    return slots.locked(() => resourceLocked(() async {
          final actual = await slots.readAnyLocked();
          if (actual == null ||
              !RegistrationEvidence.same(actual.value, snapshot.value)) {
            linkFail('stale_revision');
          }
          if (await evidence
              .file('registration-adoption-joined.json.pending')
              .exists()) {
            final pending = await evidence
                .read('registration-adoption-joined.json.pending');
            if (pending['connectorInstanceId'] !=
                    installation.connectorInstanceId ||
                pending['operationId'] != installation.operationId) {
              linkFail();
            }
            await _validateAdoptionJoin(actual, pending);
            await evidence.publish(
                'registration-adoption-joined.json', pending);
          }
          await requireAdoption(actual);
          final next = actual.change({
            'ownershipState': 'ADOPT_PENDING',
            'ownerKind': 'independent_link',
            'ownerInstanceId': installation.connectorInstanceId,
            'operationId': installation.operationId,
            'ownerGeneration': installation.operationId,
            'adoption': {
              'connectorInstanceId': installation.connectorInstanceId,
              'operationId': installation.operationId
            }
          });
          await slots.writeLocked(next, actual.revision, transfer: true);
          return next;
        }));
  }

  Future<void> resumeSlotPending() async {
    if (!await slots.file('slot-ownership.pending').exists()) return;
    final next =
        SlotOwnershipRecord(await slots.readJson('slot-ownership.pending'));
    if (!next.registered) return; // Existing v1 owner handles its own protocol.
    final previous = await slots.file('slot-ownership.json').exists()
        ? SlotOwnershipRecord(await slots.readJson('slot-ownership.json'))
        : null;
    if (next.value['slotRef'] != installation.slotRef ||
        next.revision != (previous == null ? 0 : previous.revision + 1)) {
      linkFail();
    }
    if (previous == null) {
      if (next.value['ownershipState'] != 'REGISTERING' ||
          next.operationId != installation.operationId ||
          next.value['ownerInstanceId'] != installation.connectorInstanceId) {
        linkFail();
      }
    } else {
      if (!previous.registered ||
          !RegistrationEvidence.same(
              previous.value['registration'], next.value['registration'])) {
        linkFail();
      }
      final transition =
          '${previous.value['ownershipState']}:${next.value['ownershipState']}';
      if (!{
        'REGISTERING:SEALED',
        'SEALED:ADOPT_PENDING',
        'ADOPT_PENDING:LINK_OWNED'
      }.contains(transition)) {
        linkFail();
      }
      await evidence.verify(next.value);
      if (transition == 'REGISTERING:SEALED') {
        if (next.operationId != installation.operationId ||
            next.value['ownerInstanceId'] != installation.connectorInstanceId) {
          linkFail();
        }
      } else {
        if (next.operationId != installation.operationId ||
            next.value['ownerInstanceId'] != installation.connectorInstanceId ||
            next.value['sourceDigest'] != previous.value['sourceDigest']) {
          linkFail();
        }
        if (transition == 'ADOPT_PENDING:LINK_OWNED' &&
            (!RegistrationEvidence.same(
                    next.value['adoption'], previous.value['adoption']) ||
                next.operationId != previous.operationId ||
                next.value['ownerInstanceId'] !=
                    previous.value['ownerInstanceId'] ||
                next.value['ownerGeneration'] !=
                    previous.value['ownerGeneration'])) {
          linkFail('owner_conflict');
        }
        await requireAdoption(next);
        if (next.owned) {
          final local = LinkState.fromJson(boundedJsonObject(
              await readBoundedLinkFile(File(
                  p.join(installation.stateDirectory, 'link-state-v2.json'))),
              maxBytes: linkStateLimit));
          if (local.connectorInstanceId != next.value['ownerInstanceId'] ||
              local.initializationOperationId != next.operationId ||
              local.targetRef != next.value['slotRef'] ||
              local.dirtyPhase != LinkDirtyPhase.initializing ||
              local.owner != null ||
              local.lease != null ||
              local.ownerGeneration != null) {
            linkFail();
          }
        }
      }
    }
    await slots
        .file('slot-ownership.pending')
        .rename(slots.file('slot-ownership.json').path);
  }
}
