import 'dart:convert';
import 'dart:math';

const linkStateLimit = 32768;
const linkMaxRevision = 9007199254740990;

final class LinkException implements Exception {
  const LinkException(this.code);
  final String code;
  @override
  String toString() => 'ShirohaLink($code)';
}

Never linkFail([String code = 'recovery_required']) =>
    throw LinkException(code);

String linkNonce() =>
    'l${base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256))).replaceAll('=', '')}';

String linkToken(Object? value, {bool digest = false}) {
  if (value is! String ||
      !(digest
              ? RegExp(r'^[a-f0-9]{64}$')
              : RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'))
          .hasMatch(value)) {
    linkFail('invalid_state');
  }
  return value;
}

int linkRevision(Object? value) {
  if (value is! int || value < 0 || value > linkMaxRevision) {
    linkFail('invalid_state');
  }
  return value;
}

void linkFields(Map value, Set<String> fields) {
  if (value.length != fields.length || !fields.every(value.containsKey)) {
    linkFail('invalid_state');
  }
}

enum LinkDirtyPhase {
  clean,
  preparing,
  active,
  draining,
  recoveryRequired,
  claimPending
}

enum LinkDelivery { none, delivered, undelivered, unknown }

enum LinkBusinessResult { notStarted, pending, returned, unknown }

enum LinkSettlement { clean, draining, unknown }

/// Non-secret resource selectors. They are never credentials or App authority.
final class LinkOwnerReference {
  const LinkOwnerReference(
      {required this.runId,
      required this.resourceId,
      required this.processId,
      required this.processStarted,
      required this.slotRef});
  final String runId, resourceId, processStarted, slotRef;
  final int processId;
  Map<String, Object?> toJson() => {
        'runId': runId,
        'resourceId': resourceId,
        'processId': processId,
        'processStarted': processStarted,
        'slotRef': slotRef
      };
  factory LinkOwnerReference.fromJson(Map<String, dynamic> value) {
    linkFields(value,
        {'runId', 'resourceId', 'processId', 'processStarted', 'slotRef'});
    return LinkOwnerReference(
        runId: linkToken(value['runId']),
        resourceId: linkToken(value['resourceId']),
        processId: linkRevision(value['processId']),
        processStarted: linkToken(value['processStarted']),
        slotRef: linkToken(value['slotRef']));
  }
}

/// Constructed only after the original adapter's authenticated READY event.
final class LinkVerifiedTarget {
  const LinkVerifiedTarget(
      this.deviceIdentity, this.installationIdentity, this.profileReference);
  final String deviceIdentity, installationIdentity, profileReference;
  Map<String, Object?> toJson() => {
        'deviceIdentity': deviceIdentity,
        'installationIdentity': installationIdentity,
        'profileReference': profileReference
      };
  factory LinkVerifiedTarget.fromJson(Map<String, dynamic> value) {
    linkFields(
        value, {'deviceIdentity', 'installationIdentity', 'profileReference'});
    return LinkVerifiedTarget(
        linkToken(value['deviceIdentity'], digest: true),
        linkToken(value['installationIdentity']),
        linkToken(value['profileReference']));
  }
}

final class LinkLease {
  const LinkLease(
      {required this.connectorRunId,
      required this.selectionRevision,
      required this.routeGeneration,
      required this.targetRef,
      required this.target,
      required this.frontendPeerIdentity,
      required this.frontendConnectionId,
      required this.leaseId});
  final String connectorRunId,
      targetRef,
      frontendPeerIdentity,
      frontendConnectionId,
      leaseId;
  final int selectionRevision, routeGeneration;
  final LinkVerifiedTarget target;
  static const capabilitySet = 'shiroha.profile3.base11';
  Map<String, Object?> toJson() => {
        'connectorRunId': connectorRunId,
        'selectionRevision': selectionRevision,
        'routeGeneration': routeGeneration,
        'targetRef': targetRef,
        'target': target.toJson(),
        'frontendPeerIdentity': frontendPeerIdentity,
        'frontendConnectionId': frontendConnectionId,
        'capabilitySet': capabilitySet,
        'leaseId': leaseId
      };
  factory LinkLease.fromJson(Map<String, dynamic> value) {
    linkFields(value, {
      'connectorRunId',
      'selectionRevision',
      'routeGeneration',
      'targetRef',
      'target',
      'frontendPeerIdentity',
      'frontendConnectionId',
      'capabilitySet',
      'leaseId'
    });
    if (value['capabilitySet'] != capabilitySet ||
        value['target'] is! Map<String, dynamic>) {
      linkFail('invalid_state');
    }
    return LinkLease(
        connectorRunId: linkToken(value['connectorRunId']),
        selectionRevision: linkRevision(value['selectionRevision']),
        routeGeneration: linkRevision(value['routeGeneration']),
        targetRef: linkToken(value['targetRef']),
        target: LinkVerifiedTarget.fromJson(
            value['target'] as Map<String, dynamic>),
        frontendPeerIdentity: linkToken(value['frontendPeerIdentity']),
        frontendConnectionId: linkToken(value['frontendConnectionId']),
        leaseId: linkToken(value['leaseId']));
  }
}

final class LinkState {
  const LinkState(
      {required this.connectorInstanceId,
      this.revision = 0,
      this.targetRef,
      this.selectionRevision = 0,
      this.routeGeneration = 0,
      this.owner,
      this.lease,
      this.dirtyPhase = LinkDirtyPhase.clean,
      this.handoffId,
      this.diagnostic = 'none',
      this.delivery = LinkDelivery.none,
      this.businessResult = LinkBusinessResult.notStarted,
      this.settlement = LinkSettlement.clean});
  final String connectorInstanceId;
  final int revision, selectionRevision, routeGeneration;
  final String? targetRef, handoffId;
  final LinkOwnerReference? owner;
  final LinkLease? lease;
  final LinkDirtyPhase dirtyPhase;
  final String diagnostic;
  final LinkDelivery delivery;
  final LinkBusinessResult businessResult;
  final LinkSettlement settlement;

  Map<String, Object?> toJson() => {
        'formatVersion': 1,
        'connectorInstanceId': connectorInstanceId,
        'revision': revision,
        'targetRef': targetRef,
        'selectionRevision': selectionRevision,
        'routeGeneration': routeGeneration,
        'owner': owner?.toJson(),
        'lease': lease?.toJson(),
        'dirtyPhase': dirtyPhase.name,
        'handoffId': handoffId,
        'diagnostic': diagnostic,
        'delivery': delivery.name,
        'businessResult': businessResult.name,
        'settlement': settlement.name
      };

  factory LinkState.fromJson(Map<String, dynamic> value) {
    linkFields(value, {
      'formatVersion',
      'connectorInstanceId',
      'revision',
      'targetRef',
      'selectionRevision',
      'routeGeneration',
      'owner',
      'lease',
      'dirtyPhase',
      'handoffId',
      'diagnostic',
      'delivery',
      'businessResult',
      'settlement'
    });
    if (value['formatVersion'] != 1 ||
        !const {
          'none',
          'owner_unsettled',
          'adapter_unavailable',
          'target_unavailable',
          'handoff_required',
          'handoff_pending',
          'invalid_state',
          'peer_lost',
          'output_unavailable'
        }.contains(value['diagnostic'])) {
      linkFail('invalid_state');
    }
    try {
      final state = LinkState(
          connectorInstanceId: linkToken(value['connectorInstanceId']),
          revision: linkRevision(value['revision']),
          targetRef:
              value['targetRef'] == null ? null : linkToken(value['targetRef']),
          selectionRevision: linkRevision(value['selectionRevision']),
          routeGeneration: linkRevision(value['routeGeneration']),
          owner: value['owner'] == null
              ? null
              : LinkOwnerReference.fromJson(
                  value['owner'] as Map<String, dynamic>),
          lease: value['lease'] == null
              ? null
              : LinkLease.fromJson(value['lease'] as Map<String, dynamic>),
          dirtyPhase:
              LinkDirtyPhase.values.byName(value['dirtyPhase'] as String),
          handoffId:
              value['handoffId'] == null ? null : linkToken(value['handoffId']),
          diagnostic: value['diagnostic'] as String,
          delivery: LinkDelivery.values.byName(value['delivery'] as String),
          businessResult: LinkBusinessResult.values
              .byName(value['businessResult'] as String),
          settlement:
              LinkSettlement.values.byName(value['settlement'] as String));
      if (state.dirtyPhase == LinkDirtyPhase.clean &&
              (state.owner != null ||
                  state.lease != null ||
                  state.settlement != LinkSettlement.clean) ||
          state.dirtyPhase == LinkDirtyPhase.claimPending &&
              state.handoffId == null ||
          state.lease != null &&
              (state.lease!.targetRef != state.targetRef ||
                  state.lease!.selectionRevision != state.selectionRevision ||
                  state.lease!.routeGeneration != state.routeGeneration ||
                  state.owner == null ||
                  state.lease!.connectorRunId != state.owner!.runId)) {
        linkFail('invalid_state');
      }
      return state;
    } catch (_) {
      linkFail('invalid_state');
    }
  }

  /// Exact-field reconstruction keeps nullable transitions explicit.
  LinkState change(Map<String, Object?> fields) =>
      LinkState.fromJson(Map<String, dynamic>.from(
          {...toJson(), ...fields, 'revision': revision + 1}));
}
