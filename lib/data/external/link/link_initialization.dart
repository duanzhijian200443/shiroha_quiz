import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import '../bounded_json_object.dart';
import '../windows_local_relay.dart';

import 'link_installation.dart';
import 'link_registration.dart';
import 'link_adapter_process.dart';
import 'link_state_store.dart';
import 'link_values.dart';
import 'slot_ownership_store.dart';

/// The native-admitted local entry supplies this coordinator; MCP never does.
final class LinkInitialization {
  LinkInitialization(this.installation,
      {bool Function(int, String)? processCurrent})
      : slots = SlotOwnershipStore(installation),
        processCurrent = processCurrent ?? WindowsLocalRelay.linkProcessCurrent;
  final LinkInstallation installation;
  final SlotOwnershipStore slots;
  final bool Function(int, String) processCurrent;

  Future<LinkOwnerReference> beginAttempt(LinkStateStore store, String runId) =>
      slots.locked(() async {
        final record = await slots.readLocked();
        if (record == null ||
            record.owned ||
            store.state.dirtyPhase != LinkDirtyPhase.initializing ||
            store.state.lease != null ||
            record.operationId != store.state.initializationOperationId) {
          linkFail();
        }
        final original = store.state.owner ??
            LinkOwnerReference(
                runId: runId,
                resourceId: record.value['resourceGeneration'] as String? ??
                    linkNonce(),
                processId: 0,
                processStarted: 'not-created',
                slotRef: installation.slotRef);
        if (record.value['resourceGeneration'] == null) {
          await slots.writeLocked(
              record.change({
                'resourceGeneration': original.resourceId,
                'lastSettlementState': 'UNKNOWN',
              }),
              record.revision);
        } else if (record.value['resourceGeneration'] != original.resourceId) {
          linkFail();
        }
        if (store.state.owner == null) {
          await store.replace(store.state.change({'owner': original.toJson()}),
              expectedRevision: store.state.revision);
        }
        return original;
      });

  Future<LinkStateStore> open(
      {required bool initialize,
      Future<LinkInitializationSupervision> Function()?
          registrationInspector}) async {
    final raw = await slots.locked(() async {
      if (await slots.file('slot-ownership.pending').exists()) {
        return SlotOwnershipRecord(
            await slots.readJson('slot-ownership.pending'));
      }
      return slots.readAnyLocked();
    });
    if (raw?.registered == true) {
      final registration =
          LinkRegistration(installation, processCurrent: processCurrent);
      if (initialize) await registration.adopt(inspect: registrationInspector);
      final custody = await slots.locked(() => slots.readLocked());
      if (custody == null ||
          (!custody.owned &&
              (!initialize ||
                  custody.value['ownershipState'] != 'ADOPT_PENDING'))) {
        linkFail();
      }
      final destination =
          File(p.join(installation.stateDirectory, 'link-state-v2.json'));
      if (custody.owned && !await destination.exists()) {
        linkFail('recovery_required');
      }
      final store = await LinkStateStore.open(
          Directory(installation.stateDirectory),
          beforeReadUnderLock: initialize ? _resumeStatePreparation : null,
          initialState: custody.owned
              ? null
              : LinkState(
                  connectorInstanceId: installation.connectorInstanceId,
                  initializationOperationId: installation.operationId,
                  targetRef: installation.slotRef,
                  dirtyPhase: LinkDirtyPhase.initializing,
                  diagnostic: 'initialization_pending',
                  settlement: LinkSettlement.unknown));
      try {
        if (store.state.connectorInstanceId !=
                installation.connectorInstanceId ||
            store.state.initializationOperationId != installation.operationId ||
            store.state.targetRef != installation.slotRef) {
          linkFail('owner_conflict');
        }
        if (store.state.dirtyPhase == LinkDirtyPhase.initializing &&
            initialize) {
          await slots.locked(() => registration.resourceLocked(() async {
                var current = await slots.readLocked();
                if (current == null ||
                    store.state.lease != null ||
                    store.state.owner != null) {
                  linkFail();
                }
                await registration.requireAdoption(current);
                if (!current.owned) {
                  if (current.value['ownershipState'] != 'ADOPT_PENDING' ||
                      store.state.ownerGeneration != null) {
                    linkFail();
                  }
                  final next = current.change({'ownershipState': 'LINK_OWNED'});
                  await slots.writeLocked(next, current.revision);
                  current = next;
                }
                await _finishState(store, current);
              }));
        }
        return store;
      } catch (_) {
        await store.close();
        rethrow;
      }
    }
    final record = initialize ? await slots.prepare() : null;
    final store =
        await LinkStateStore.open(Directory(installation.stateDirectory),
            beforeReadUnderLock: initialize ? _resumeStatePreparation : null,
            initialState: record == null
                ? null
                : LinkState(
                    connectorInstanceId: installation.connectorInstanceId,
                    initializationOperationId: record.operationId,
                    targetRef: installation.slotRef,
                    dirtyPhase: LinkDirtyPhase.initializing,
                    diagnostic: 'initialization_pending',
                    settlement: LinkSettlement.unknown,
                  ));
    try {
      final state = store.state;
      if (state.connectorInstanceId != installation.connectorInstanceId ||
          state.initializationOperationId != installation.operationId) {
        linkFail('owner_conflict');
      }
      // Only finish the two-file INITIAL owner publication. No business dirty
      // snapshot or legacy owner is repaired by this path.
      await slots.locked(() async {
        final owner = await slots.readLocked();
        if (owner == null) linkFail('legacy_status_unknown');
        if (owner.owned &&
            state.dirtyPhase == LinkDirtyPhase.initializing &&
            state.lease == null) {
          await _finishState(store, owner);
        }
      });
      return store;
    } catch (_) {
      await store.close();
      rethrow;
    }
  }

  Future<void> _finishState(
      LinkStateStore store, SlotOwnershipRecord owner) async {
    await slots.requireNoUnsettledFiles();
    final origin = await slots.registeredPairing();
    final receipt = owner.registered
        ? await slots.readJson('registration-receipt.json')
        : await slots.receiptFor(origin['resourceGeneration'] as String);
    if (processCurrent(
        receipt['processId'] as int, receipt['processStarted'] as String)) {
      linkFail();
    }
    if (owner.value['lastSettlementState'] != 'CLEAN' ||
        owner.value['lastSettlementRef'] != origin['settlementRef'] ||
        jsonEncode(owner.target!.toJson()) != jsonEncode(origin['target'])) {
      linkFail();
    }
    await store.replace(
        store.state.change({
          'ownerGeneration': owner.value['ownerGeneration'],
          'dirtyPhase': 'clean',
          'settlement': 'clean',
          'diagnostic': 'none',
          'owner': null,
          'lease': null,
        }),
        expectedRevision: store.state.revision);
  }

  Future<void> _resumeStatePreparation() => slots.locked(() async {
        final custody = await slots.readLocked();
        if (custody?.registered == true) {
          await LinkRegistration(installation, processCurrent: processCurrent)
              .resourceLocked(_resumeStatePreparationLocked);
        } else {
          await _resumeStatePreparationLocked();
        }
      });

  Future<void> _resumeStatePreparationLocked() async {
    final pending =
        File(p.join(installation.stateDirectory, 'link-state-v2.pending'));
    if (!await pending.exists()) return;
    final destination =
        File(p.join(installation.stateDirectory, 'link-state-v2.json'));
    Future<LinkState> read(File file) async =>
        LinkState.fromJson(boundedJsonObject(await readBoundedLinkFile(file),
            maxBytes: linkStateLimit));
    final next = await read(pending);
    final previous =
        await destination.exists() ? await read(destination) : null;
    final owner = await slots.readLocked();
    if (owner == null ||
        next.initializationOperationId != installation.operationId ||
        next.connectorInstanceId != installation.connectorInstanceId ||
        next.targetRef != installation.slotRef ||
        next.lease != null ||
        next.revision != (previous == null ? 0 : previous.revision + 1) ||
        previous != null &&
            previous.dirtyPhase != LinkDirtyPhase.initializing ||
        previous != null &&
            previous.initializationOperationId !=
                next.initializationOperationId) {
      linkFail();
    }
    if (owner.registered &&
        previous == null &&
        (owner.owned || next.dirtyPhase != LinkDirtyPhase.initializing)) {
      linkFail();
    }
    if (owner.registered) {
      await LinkRegistration(installation, processCurrent: processCurrent)
          .requireAdoption(owner);
    }
    if (next.dirtyPhase == LinkDirtyPhase.clean) {
      if (!owner.owned ||
          next.ownerGeneration != owner.value['ownerGeneration'] ||
          next.owner != null ||
          owner.value['lastSettlementState'] != 'CLEAN') {
        linkFail();
      }
      final origin = await slots.registeredPairing();
      if (origin['settlementRef'] != owner.value['lastSettlementRef']) {
        linkFail();
      }
    } else if (next.dirtyPhase != LinkDirtyPhase.initializing ||
        next.ownerGeneration != null) {
      linkFail();
    }
    await pending.rename(destination.path);
  }

  /// Adapter has verified the protected pairing, and its original process and
  /// all streams have joined. A model argument cannot supply this result.
  Future<void> complete(LinkStateStore store, LinkVerifiedTarget verified) =>
      slots.locked(() async {
        var owner = await slots.readLocked();
        if (owner == null ||
            owner.operationId != store.state.initializationOperationId) {
          linkFail();
        }
        if (owner.owned) {
          if (store.state.ownerGeneration != owner.value['ownerGeneration'] ||
              jsonEncode(owner.target!.toJson()) !=
                  jsonEncode(verified.toJson())) {
            linkFail();
          }
          return;
        }
        await slots.requireNoUnsettledFiles();
        final origin = await slots.registeredPairing();
        final receipt =
            await slots.receiptFor(origin['resourceGeneration'] as String);
        if (processCurrent(
            receipt['processId'] as int, receipt['processStarted'] as String)) {
          linkFail();
        }
        if (jsonEncode(origin['target']) != jsonEncode(verified.toJson()) ||
            owner.value['initializationSource'] == 'new_pairing' &&
                (origin['operationId'] != owner.operationId ||
                    receipt['owner'] != installation.connectorInstanceId ||
                    owner.value['resourceGeneration'] != null &&
                        origin['resourceGeneration'] !=
                            owner.value['resourceGeneration'])) {
          linkFail();
        }
        owner = owner.change({
          'verifiedInstallationBinding': verified.toJson(),
          'adapterCredentialSlotRef': origin['credentialSlotRef'],
          'resourceGeneration': origin['resourceGeneration'],
          'lastSettlementRef': origin['settlementRef'],
          'lastSettlementState': 'CLEAN',
          'ownershipState': 'LINK_OWNED',
          // Stable initialization identity, never a process/run generation.
          'ownerGeneration': owner.operationId,
        });
        await slots.writeLocked(owner, owner.revision - 1);
        await _finishState(store, owner);
      });
}
