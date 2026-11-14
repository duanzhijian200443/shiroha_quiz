import 'dart:convert';
import 'dart:io';

import 'link_installation.dart';
import 'link_values.dart';
import 'link_state_store.dart';
import 'slot_ownership_store.dart';

/// This is a failed proof, even when its local resources have settled.
final class LinkPreauthFailure implements Exception {
  const LinkPreauthFailure();
  @override
  String toString() => 'ShirohaLink(preauth_failed)';
}

final class LinkPreauthPublicationFailure implements Exception {
  const LinkPreauthPublicationFailure();
  @override
  String toString() => 'ShirohaLink(preauth_publication_unknown)';
}

/// Original adapter facts and original supervisor facts are independent.
/// Neither record can replace the other or authorize Android access.
final class LinkFailureSettlement {
  LinkFailureSettlement(this.installation)
      : slots = SlotOwnershipStore(installation);
  final LinkInstallation installation;
  final SlotOwnershipStore slots;

  String receiptName(String resource) =>
      'link-preauth-${linkToken(resource)}.json';
  String joinName(String resource) =>
      'link-preauth-${linkToken(resource)}-joined.json';

  Future<void> _publish(String name, Map<String, Object?> value) async {
    final destination = slots.file(name);
    final pending = slots.file('$name.pending');
    if (await destination.exists() || await pending.exists()) {
      linkFail();
    }
    await pending.create(exclusive: true);
    final handle = await pending.open(mode: FileMode.writeOnly);
    try {
      await handle.writeString(jsonEncode(value));
      await handle.flush();
    } finally {
      await handle.close();
    }
    await pending.rename(destination.path);
    if (jsonEncode(await slots.readJson(name)) != jsonEncode(value)) {
      linkFail();
    }
  }

  Map<String, Object?> _binding(LinkOwnerReference owner) => {
        'operationId': installation.operationId,
        'owner': installation.connectorInstanceId,
        'ownerGeneration': installation.operationId,
        ...owner.toJson(),
      };

  void _requireBinding(Map<String, dynamic> record, LinkOwnerReference owner) {
    for (final entry in _binding(owner).entries) {
      if (record[entry.key] != entry.value) {
        linkFail();
      }
    }
  }

  Future<Map<String, dynamic>> receipt(LinkOwnerReference owner) async {
    final name = receiptName(owner.resourceId);
    if (await slots.file('$name.pending').exists()) {
      linkFail();
    }
    final value = await slots.readJson(name);
    linkFields(value, {
      'formatVersion',
      'kind',
      'operationId',
      'owner',
      'ownerGeneration',
      'slotRef',
      'runId',
      'resourceId',
      'receiptRef',
      'processId',
      'processStarted',
      'mode',
      'stage',
      'resources',
      'tlsEstablished',
      'peerObserved',
      'socketClosed',
      'tlsClosed',
      'keyRetired',
      'pendingClear',
      'target'
    });
    _requireBinding(value, owner);
    if (value['formatVersion'] != 1 ||
        value['kind'] != 'preauth-failure' ||
        value['mode'] != 'enable-proof' ||
        value['receiptRef'] != owner.resourceId ||
        !{'configuration', 'protected-configuration', 'client-key', 'tls'}
            .contains(value['stage']) ||
        !{'not-acquired', 'released'}.contains(value['resources']) ||
        value['tlsEstablished'] != false ||
        value['peerObserved'] != false ||
        value['socketClosed'] != true ||
        value['tlsClosed'] != true ||
        value['keyRetired'] != true ||
        value['pendingClear'] != true ||
        owner.processId < 1 ||
        (int.tryParse(owner.processStarted) ?? 0) < 1) {
      linkFail();
    }
    LinkVerifiedTarget.fromJson(value['target'] as Map<String, dynamic>);
    return value;
  }

  /// Called only after the original process object, all original streams,
  /// exact creation identity, versioned event and exit 80 have been observed.
  Future<void> publishJoined(LinkOwnerReference owner) =>
      slots.locked(() async {
        final value = await receipt(owner);
        await slots.requireNoUnsettledFiles();
        await _publish(joinName(owner.resourceId), {
          'formatVersion': 1,
          'kind': 'preauth-supervisor',
          ..._binding(owner),
          'adapterReceipt': value,
          'processExitCode': 80,
          'stdinClosed': true,
          'stdoutDrained': true,
          'stderrDrained': true,
        });
      });

  /// The original supervisor refused before invoking process creation at all.
  Future<void> publishNotStarted(LinkOwnerReference owner) =>
      slots.locked(() async {
        if (owner.processId != 0 || owner.processStarted != 'not-created') {
          linkFail();
        }
        await slots.requireNoUnsettledFiles();
        await _publish(joinName(owner.resourceId), {
          'formatVersion': 1,
          'kind': 'preauth-not-started',
          ..._binding(owner),
        });
      });

  Future<String> requireComplete(
      LinkOwnerReference owner, LinkVerifiedTarget target) async {
    await slots.requireNoUnsettledFiles();
    final name = joinName(owner.resourceId);
    if (await slots.file('$name.pending').exists()) {
      linkFail();
    }
    final joined = await slots.readJson(name);
    _requireBinding(joined, owner);
    if (joined['formatVersion'] != 1) {
      linkFail();
    }
    if (joined['kind'] == 'preauth-not-started') {
      linkFields(joined, {'formatVersion', 'kind', ..._binding(owner).keys});
      if (owner.processId != 0 ||
          owner.processStarted != 'not-created' ||
          await slots.file(receiptName(owner.resourceId)).exists() ||
          await slots
              .file('${receiptName(owner.resourceId)}.pending')
              .exists()) {
        linkFail();
      }
    } else {
      linkFields(joined, {
        'formatVersion',
        'kind',
        ..._binding(owner).keys,
        'adapterReceipt',
        'processExitCode',
        'stdinClosed',
        'stdoutDrained',
        'stderrDrained'
      });
      final value = await receipt(owner);
      if (joined['kind'] != 'preauth-supervisor' ||
          joined['processExitCode'] != 80 ||
          joined['stdinClosed'] != true ||
          joined['stdoutDrained'] != true ||
          joined['stderrDrained'] != true ||
          jsonEncode(joined['adapterReceipt']) != jsonEncode(value) ||
          jsonEncode(value['target']) != jsonEncode(target.toJson())) {
        linkFail();
      }
    }
    return owner.resourceId;
  }

  /// A bounded two-file transition: preserve slot DIRTY until the state CAS
  /// succeeds. Its immutable intent permits only explicit completion of this
  /// exact transition after interruption; no historical evidence is inferred.
  Future<void> recoverPreauth(LinkStateStore store, int expectedRevision) =>
      slots.locked(() async {
        final current = store.state;
        if (current.revision != expectedRevision) {
          linkFail('stale_revision');
        }
        final custody = await slots.readLocked();
        if (custody == null || !custody.owned || current.lease != null) {
          linkFail();
        }
        final resource = current.owner?.resourceId ??
            linkToken(custody.value['resourceGeneration']);
        final name = 'link-preauth-$resource-recovery.json';
        if (await slots.file('$name.pending').exists()) {
          linkFail();
        }
        LinkState before;
        SlotOwnershipRecord beforeSlot;
        Map<String, dynamic>? intent;
        if (await slots.file(name).exists()) {
          intent = await slots.readJson(name);
          linkFields(intent, {
            'formatVersion',
            'kind',
            'beforeState',
            'afterState',
            'beforeSlot',
            'afterSlot'
          });
          if (intent['formatVersion'] != 1 ||
              intent['kind'] != 'preauth-recovery') {
            linkFail();
          }
          before =
              LinkState.fromJson(intent['beforeState'] as Map<String, dynamic>);
          beforeSlot =
              SlotOwnershipRecord(intent['beforeSlot'] as Map<String, dynamic>);
        } else {
          before = current;
          beforeSlot = custody;
        }
        final original = before.owner;
        if (original == null ||
            before.lease != null ||
            before.businessResult != LinkBusinessResult.notStarted ||
            before.delivery != LinkDelivery.none ||
            before.dirtyPhase != LinkDirtyPhase.recoveryRequired ||
            before.connectorInstanceId != installation.connectorInstanceId ||
            before.initializationOperationId != installation.operationId ||
            before.targetRef != installation.slotRef ||
            original.slotRef != installation.slotRef ||
            before.ownerGeneration != installation.operationId ||
            !beforeSlot.owned ||
            beforeSlot.value['ownerInstanceId'] !=
                installation.connectorInstanceId ||
            beforeSlot.operationId != installation.operationId ||
            beforeSlot.value['ownerGeneration'] != before.ownerGeneration ||
            beforeSlot.value['slotRef'] != installation.slotRef ||
            beforeSlot.value['resourceGeneration'] != resource ||
            original.resourceId != resource ||
            beforeSlot.value['lastSettlementState'] != 'DIRTY') {
          linkFail();
        }
        final receiptRef = await requireComplete(original, beforeSlot.target!);
        final after = before.change({
          'owner': null,
          'lease': null,
          'dirtyPhase': 'clean',
          'settlement': 'clean',
          'diagnostic': 'none'
        });
        final afterSlot = beforeSlot.change(
            {'lastSettlementState': 'CLEAN', 'lastSettlementRef': receiptRef});
        final expected = <String, Object?>{
          'formatVersion': 1,
          'kind': 'preauth-recovery',
          'beforeState': before.toJson(),
          'afterState': after.toJson(),
          'beforeSlot': beforeSlot.value,
          'afterSlot': afterSlot.value
        };
        if (intent != null && jsonEncode(intent) != jsonEncode(expected)) {
          linkFail();
        }
        final stateBefore =
            jsonEncode(current.toJson()) == jsonEncode(before.toJson());
        final stateAfter =
            jsonEncode(current.toJson()) == jsonEncode(after.toJson());
        final slotBefore =
            jsonEncode(custody.value) == jsonEncode(beforeSlot.value);
        final slotAfter =
            jsonEncode(custody.value) == jsonEncode(afterSlot.value);
        if ((!stateBefore && !stateAfter) ||
            (!slotBefore && !slotAfter) ||
            stateBefore && slotAfter) {
          linkFail();
        }
        try {
          if (intent == null) {
            await _publish(name, expected);
          }
          // On any state-write failure the original custody remains DIRTY. A
          // completed state write alone cannot pass requireOwned/admit work.
          if (stateBefore) {
            await store.replace(after, expectedRevision: before.revision);
          }
          if (slotBefore) {
            await slots.writeLocked(afterSlot, beforeSlot.revision);
          }
        } catch (_) {
          throw const LinkPreauthPublicationFailure();
        }
      });
}
