import 'dart:convert';

import '../content/content_node.dart';
import '../content/rich_content.dart';
import '../content/rich_content_privacy_admission.dart';
import '../question/question_draft_v2.dart';
import '../question/question_draft_v2_codec.dart';
import '../source/source_ref.dart';

part 'external_proposal_origin.dart';

enum GeneratedFailure {
  invalidSubmission('invalid_submission'),
  unsupportedContent('unsupported_content'),
  unsafePayload('unsafe_payload'),
  resourceLimit('resource_limit'),
  invalidEvidence('invalid_evidence'),
  unauthorized('unauthorized'),
  targetChanged('target_changed'),
  proposalUnavailable('proposal_unavailable'),
  staleRevision('stale_revision'),
  terminalConflict('terminal_conflict'),
  idempotencyConflict('idempotency_conflict'),
  duplicateContent('duplicate_content'),
  reviewIncomplete('review_incomplete'),
  qualityBlocked('quality_blocked'),
  staleEvidence('stale_evidence'),
  invalidEdit('invalid_edit'),
  corruptState('corrupt_state'),
  persistenceFailed('persistence_failed');

  const GeneratedFailure(this.code);
  final String code;
}

final class GeneratedQuestionException implements Exception {
  const GeneratedQuestionException(this.failure);
  final GeneratedFailure failure;
  @override
  String toString() => 'GeneratedQuestionException(${failure.code})';
}

Never generatedFail(GeneratedFailure failure) =>
    throw GeneratedQuestionException(failure);

abstract final class GeneratedLimits {
  static const submissionBytes = 1024 * 1024;
  static const batchBytes = 4 * 1024 * 1024;
  static const itemBytes = 128 * 1024;
  static const flushBytes = 128 * 1024;
  static const receiptBytes = 32 * 1024;
  static const externalOriginBytes = 32 * 1024;
}

Map<String, Object?> generatedObject(Object? value, Iterable<String> keys) {
  if (value is! Map ||
      value.keys.any((k) => k is! String) ||
      value.length != keys.length ||
      keys.any((k) => !value.containsKey(k))) {
    generatedFail(GeneratedFailure.invalidSubmission);
  }
  return Map<String, Object?>.from(value);
}

List<Object?> generatedList(Object? value, {int max = 50}) {
  if (value is! List || value.length > max) {
    generatedFail(GeneratedFailure.resourceLimit);
  }
  return List<Object?>.from(value);
}

String generatedToken(Object? value, {bool uuid = false}) {
  final pattern = uuid
      ? RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
      : RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
  if (value is! String || !pattern.hasMatch(value)) {
    generatedFail(GeneratedFailure.invalidSubmission);
  }
  return value;
}

int generatedInt(Object? value, {int min = 0, int? max}) {
  if (value is! int || value < min || (max != null && value > max)) {
    generatedFail(GeneratedFailure.invalidSubmission);
  }
  return value;
}

String generatedDigest(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    generatedFail(GeneratedFailure.invalidSubmission);
  }
  return value;
}

void generatedSize(Object? value, int max) {
  if (utf8.encode(jsonEncode(value)).length > max) {
    generatedFail(GeneratedFailure.resourceLimit);
  }
}

/// Bounded lexical pass rejects duplicate JSON keys BEFORE Map decoding.
Object? generatedDecode(String text,
    {int maxBytes = GeneratedLimits.submissionBytes}) {
  if (utf8.encode(text).length > maxBytes) {
    generatedFail(GeneratedFailure.resourceLimit);
  }
  final stack = <Set<String>?>[];
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '"') {
      final start = i;
      i++;
      while (i < text.length && text[i] != '"') {
        if (text[i] == r'\') i++;
        i++;
      }
      if (i >= text.length) generatedFail(GeneratedFailure.invalidSubmission);
      var next = i + 1;
      while (next < text.length && ' \r\n\t'.contains(text[next])) {
        next++;
      }
      if (next < text.length && text[next] == ':') {
        if (stack.isEmpty || stack.last == null) {
          generatedFail(GeneratedFailure.invalidSubmission);
        }
        final String key;
        try {
          key = jsonDecode(text.substring(start, i + 1)) as String;
        } on FormatException {
          generatedFail(GeneratedFailure.invalidSubmission);
        }
        if (!stack.last!.add(key)) {
          generatedFail(GeneratedFailure.invalidSubmission);
        }
      }
    } else if (c == '{' || c == '[') {
      stack.add(c == '{' ? <String>{} : null);
      if (stack.length > 16) generatedFail(GeneratedFailure.resourceLimit);
    } else if (c == '}' || c == ']') {
      if (stack.isEmpty || (c == '}') != (stack.last != null)) {
        generatedFail(GeneratedFailure.invalidSubmission);
      }
      stack.removeLast();
    }
  }
  try {
    return jsonDecode(text);
  } on FormatException {
    generatedFail(GeneratedFailure.invalidSubmission);
  }
}

String generatedCanonical(Object? value) => jsonEncode(_canonical(value));
Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

final class GeneratedTarget {
  GeneratedTarget(
      {required this.bankName,
      required this.folderName,
      required this.projectId,
      required Iterable<String> projectBankNames})
      : projectBankNames = List.unmodifiable(projectBankNames);
  final String bankName;
  final String? folderName;
  final String? projectId;
  final List<String> projectBankNames;
  Map<String, Object?> toJson() => {
        'bankName': bankName,
        'folderName': folderName,
        'projectId': projectId,
        'projectBankNames': projectBankNames
      };
  static GeneratedTarget fromJson(Object? value) {
    try {
      return _decode(value);
    } on GeneratedQuestionException {
      rethrow;
    } catch (_) {
      generatedFail(GeneratedFailure.corruptState);
    }
  }

  static GeneratedTarget _decode(Object? value) {
    final m = generatedObject(
        value, ['bankName', 'folderName', 'projectId', 'projectBankNames']);
    String name(Object? v) {
      if (v is! String ||
          v.isEmpty ||
          v != v.trim() ||
          v.runes.length > 256 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(v)) {
        generatedFail(GeneratedFailure.invalidSubmission);
      }
      return v;
    }

    final names =
        generatedList(m['projectBankNames'], max: 256).map(name).toList();
    final sorted = names.toSet().toList()..sort();
    if (generatedCanonical(names) != generatedCanonical(sorted)) {
      generatedFail(GeneratedFailure.invalidSubmission);
    }
    final project =
        m['projectId'] == null ? null : generatedToken(m['projectId']);
    final bank = name(m['bankName']);
    if ((project == null && names.isNotEmpty) ||
        (project != null && !names.contains(bank))) {
      generatedFail(GeneratedFailure.invalidSubmission);
    }
    return GeneratedTarget(
        bankName: bank,
        folderName: m['folderName'] == null ? null : name(m['folderName']),
        projectId: project,
        projectBankNames: names);
  }
}

final class GeneratedEvidence {
  const GeneratedEvidence(
      {required this.evidenceKey,
      required this.sourceRef,
      required this.fileId,
      required this.artifactRevision,
      required this.artifactDigest});
  final String evidenceKey;
  final SourceRef sourceRef;
  final String fileId;
  final int artifactRevision;
  final String artifactDigest;
  Map<String, Object?> toJson() => {
        'evidenceKey': evidenceKey,
        'sourceRef': _sourceJson(sourceRef),
        'fileId': fileId,
        'artifactRevision': artifactRevision,
        'artifactDigest': artifactDigest
      };
  static GeneratedEvidence fromJson(Object? v) {
    try {
      return _decode(v);
    } on GeneratedQuestionException {
      rethrow;
    } catch (_) {
      generatedFail(GeneratedFailure.corruptState);
    }
  }

  static GeneratedEvidence _decode(Object? v) {
    generatedSize(v, 2048);
    final m = generatedObject(v, [
      'evidenceKey',
      'sourceRef',
      'fileId',
      'artifactRevision',
      'artifactDigest'
    ]);
    // Use the retained strict SourceRef codec, without accepting client draft identities.
    final shell = QuestionDraftV2Codec().encode(QuestionDraftV2(
        questionId: 'codec',
        kind: QuestionKind.shortAnswer,
        stem: RichContent(nodes: const [])));
    shell['sourceRefs'] = [m['sourceRef']];
    final ref = const QuestionDraftV2Codec().decode(shell).sourceRefs.single;
    generatedToken(ref.sourceId, uuid: true);
    return GeneratedEvidence(
        evidenceKey: generatedToken(m['evidenceKey']),
        sourceRef: ref,
        fileId: generatedToken(m['fileId']),
        artifactRevision: generatedInt(m['artifactRevision'], min: 1),
        artifactDigest: generatedDigest(m['artifactDigest']));
  }
}

Object? _sourceJson(SourceRef ref) {
  final encoded = const QuestionDraftV2Codec().encode(QuestionDraftV2(
      questionId: 'codec',
      kind: QuestionKind.shortAnswer,
      stem: RichContent(nodes: const []),
      sourceRefs: [ref]));
  return (encoded['sourceRefs'] as List).single;
}

enum GeneratedDecision { unreviewed, accepted, rejected, deferred }

enum GeneratedStatus {
  pendingReview('pending_review'),
  committed('committed'),
  rejected('rejected');

  const GeneratedStatus(this.code);
  final String code;
}

final class GeneratedItem {
  GeneratedItem(
      {required this.itemId,
      required this.itemKey,
      required this.position,
      required this.original,
      required this.working,
      required Iterable<GeneratedEvidence> evidence,
      required this.decision,
      required this.evidenceAcknowledgement})
      : evidence = List.unmodifiable(evidence);
  final String itemId, itemKey;
  final int position;
  final QuestionDraftV2 original, working;
  final List<GeneratedEvidence> evidence;
  final GeneratedDecision decision;

  /// Canonical strict evidence-state JSON; null never means acknowledged.
  final String? evidenceAcknowledgement;
  GeneratedItem reviewed(
          QuestionDraftV2 draft, GeneratedDecision next, String? ack) =>
      GeneratedItem(
          itemId: itemId,
          itemKey: itemKey,
          position: position,
          original: original,
          working: draft,
          evidence: evidence,
          decision: next,
          evidenceAcknowledgement: ack);
  Map<String, Object?> toJson() => {
        'itemId': itemId,
        'itemKey': itemKey,
        'position': position,
        'original': const QuestionDraftV2Codec().encode(original),
        'working': const QuestionDraftV2Codec().encode(working),
        'evidence': evidence.map((e) => e.toJson()).toList(),
        'decision': decision.name,
        'evidenceAcknowledgement': evidenceAcknowledgement == null
            ? null
            : generatedDecode(evidenceAcknowledgement!)
      };
  static GeneratedItem fromJson(Object? v) {
    try {
      return _decode(v);
    } on GeneratedQuestionException {
      rethrow;
    } catch (_) {
      generatedFail(GeneratedFailure.corruptState);
    }
  }

  static GeneratedItem _decode(Object? v) {
    final m = generatedObject(v, [
      'itemId',
      'itemKey',
      'position',
      'original',
      'working',
      'evidence',
      'decision',
      'evidenceAcknowledgement'
    ]);
    final original = const QuestionDraftV2Codec().decode(m['original']);
    final working = const QuestionDraftV2Codec().decode(m['working']);
    validateGeneratedDraft(original);
    validateGeneratedDraft(working);
    final e = generatedList(m['evidence'], max: 8)
        .map(GeneratedEvidence.fromJson)
        .toList();
    if (e.map((e) => e.evidenceKey).toSet().length != e.length ||
        generatedCanonical(original.sourceRefs.map(_sourceJson).toList()) !=
            generatedCanonical(
                e.map((e) => _sourceJson(e.sourceRef)).toList()) ||
        !generatedSameStructure(original, working)) {
      generatedFail(GeneratedFailure.corruptState);
    }
    String? ack;
    if (m['evidenceAcknowledgement'] != null) {
      validateEvidenceState(m['evidenceAcknowledgement'], e);
      ack = generatedCanonical(m['evidenceAcknowledgement']);
    }
    return GeneratedItem(
        itemId: generatedToken(m['itemId'], uuid: true),
        itemKey: generatedToken(m['itemKey']),
        position: generatedInt(m['position'], max: 49),
        original: original,
        working: working,
        evidence: e,
        decision: GeneratedDecision.values.firstWhere(
            (d) => d.name == m['decision'],
            orElse: () => generatedFail(GeneratedFailure.corruptState)),
        evidenceAcknowledgement: ack);
  }
}

void validateEvidenceState(Object? v, List<GeneratedEvidence> evidence) {
  final states = generatedList(v, max: 8);
  if (states.length != evidence.length) {
    generatedFail(GeneratedFailure.invalidEvidence);
  }
  for (var i = 0; i < states.length; i++) {
    final m = generatedObject(states[i],
        ['evidenceKey', 'status', 'currentRevision', 'currentDigest']);
    if (m['evidenceKey'] != evidence[i].evidenceKey ||
        !['authorized', 'stale', 'unavailable'].contains(m['status'])) {
      generatedFail(GeneratedFailure.invalidEvidence);
    }
    if ((m['currentRevision'] == null) != (m['currentDigest'] == null)) {
      generatedFail(GeneratedFailure.invalidEvidence);
    }
    if (m['currentRevision'] != null) {
      generatedInt(m['currentRevision'], min: 1);
      generatedDigest(m['currentDigest']);
    }
    final same = m['currentRevision'] == evidence[i].artifactRevision &&
        m['currentDigest'] == evidence[i].artifactDigest;
    if ((m['status'] == 'authorized' && !same) ||
        (m['status'] == 'unavailable' && m['currentRevision'] != null) ||
        (m['status'] == 'stale' && (m['currentRevision'] == null || same))) {
      generatedFail(GeneratedFailure.invalidEvidence);
    }
  }
}

final class GeneratedReceipt {
  GeneratedReceipt(
      {required this.proposalId,
      required this.committedAtUtcMs,
      required this.reviewRevision,
      required Map<String, String> itemMappings})
      : itemMappings = Map.unmodifiable(itemMappings);
  final String proposalId;
  final int committedAtUtcMs, reviewRevision;
  final Map<String, String> itemMappings;
  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'proposalId': proposalId,
        'committedAtUtcMs': committedAtUtcMs,
        'reviewRevision': reviewRevision,
        'approvedItemIds': itemMappings.keys.toList(),
        'itemMappings': itemMappings.entries
            .map((e) => {'itemId': e.key, 'persistedQuestionId': e.value})
            .toList(),
        'finalStatus': 'committed'
      };
  static GeneratedReceipt fromJson(Object? v) {
    try {
      return _decode(v);
    } on GeneratedQuestionException {
      rethrow;
    } catch (_) {
      generatedFail(GeneratedFailure.corruptState);
    }
  }

  static GeneratedReceipt _decode(Object? v) {
    generatedSize(v, GeneratedLimits.receiptBytes);
    final m = generatedObject(v, [
      'schemaVersion',
      'proposalId',
      'committedAtUtcMs',
      'reviewRevision',
      'approvedItemIds',
      'itemMappings',
      'finalStatus'
    ]);
    if (m['schemaVersion'] is! int ||
        m['schemaVersion'] != 1 ||
        m['finalStatus'] != 'committed') {
      generatedFail(GeneratedFailure.corruptState);
    }
    final ids = generatedList(m['approvedItemIds'])
        .map((v) => generatedToken(v, uuid: true))
        .toList();
    final mappings = <String, String>{};
    for (final v in generatedList(m['itemMappings'])) {
      final row = generatedObject(v, ['itemId', 'persistedQuestionId']);
      final id = generatedToken(row['itemId'], uuid: true);
      if (mappings.containsKey(id)) {
        generatedFail(GeneratedFailure.corruptState);
      }
      mappings[id] = generatedToken(row['persistedQuestionId'], uuid: true);
    }
    if (ids.isEmpty ||
        generatedCanonical(ids) != generatedCanonical(mappings.keys.toList()) ||
        mappings.values.toSet().length != mappings.length) {
      generatedFail(GeneratedFailure.corruptState);
    }
    return GeneratedReceipt(
        proposalId: generatedToken(m['proposalId'], uuid: true),
        committedAtUtcMs: generatedInt(m['committedAtUtcMs']),
        reviewRevision: generatedInt(m['reviewRevision']),
        itemMappings: mappings);
  }
}

final class GeneratedQuestionProposal {
  GeneratedQuestionProposal(
      {required this.proposalId,
      required this.createdAtUtcMs,
      required this.updatedAtUtcMs,
      required this.localOwner,
      required this.originKind,
      required this.clientProfileId,
      required this.submissionKey,
      required this.semanticFingerprint,
      required this.requestedCount,
      required this.originalTarget,
      required this.target,
      required this.reviewRevision,
      required this.lifecycleStatus,
      required Iterable<GeneratedItem> items,
      required this.commitReceipt,
      this.externalOrigin})
      : items = List.unmodifiable(items) {
    if (originKind == 'external') {
      final origin = externalOrigin;
      if (origin == null ||
          origin.clientProfileId != clientProfileId ||
          origin.submissionKey != submissionKey ||
          generatedCanonical(origin.originalTarget.toJson()) !=
              generatedCanonical(originalTarget.toJson())) {
        generatedFail(GeneratedFailure.corruptState);
      }
    } else if (externalOrigin != null) {
      generatedFail(GeneratedFailure.corruptState);
    }
  }
  final String proposalId,
      localOwner,
      originKind,
      clientProfileId,
      submissionKey,
      semanticFingerprint;
  final int createdAtUtcMs, updatedAtUtcMs, requestedCount, reviewRevision;
  final GeneratedTarget originalTarget, target;
  final GeneratedStatus lifecycleStatus;
  final List<GeneratedItem> items;
  final GeneratedReceipt? commitReceipt;
  final ExternalProposalOrigin? externalOrigin;
  int get actualCount => items.length;
  bool get countMismatchWarning => actualCount != requestedCount;
  Map<String, Object?> toJson() => {
        'schemaVersion': originKind == 'external' ? 2 : 1,
        'proposalId': proposalId,
        'createdAtUtcMs': createdAtUtcMs,
        'updatedAtUtcMs': updatedAtUtcMs,
        'localOwner': localOwner,
        'originKind': originKind,
        'clientProfileId': clientProfileId,
        'submissionKey': submissionKey,
        'semanticFingerprint': semanticFingerprint,
        'requestedCount': requestedCount,
        'actualCount': actualCount,
        'countMismatchWarning': countMismatchWarning,
        'originalTarget': originalTarget.toJson(),
        'target': target.toJson(),
        'reviewRevision': reviewRevision,
        'lifecycleStatus': lifecycleStatus.code,
        'items': items.map((i) => i.toJson()).toList(),
        'commitReceipt': commitReceipt?.toJson(),
        if (originKind == 'external')
          'externalOrigin': externalOrigin?.toPersistedPayload()
      };
  static GeneratedQuestionProposal fromJson(Object? v) {
    try {
      return _decode(v);
    } on GeneratedQuestionException {
      rethrow;
    } catch (_) {
      generatedFail(GeneratedFailure.corruptState);
    }
  }

  static GeneratedQuestionProposal _decode(Object? v) {
    final external =
        v is Map && v['schemaVersion'] is int && v['schemaVersion'] == 2;
    final m = generatedObject(v, [
      'schemaVersion',
      'proposalId',
      'createdAtUtcMs',
      'updatedAtUtcMs',
      'localOwner',
      'originKind',
      'clientProfileId',
      'submissionKey',
      'semanticFingerprint',
      'requestedCount',
      'actualCount',
      'countMismatchWarning',
      'originalTarget',
      'target',
      'reviewRevision',
      'lifecycleStatus',
      'items',
      'commitReceipt',
      if (external) 'externalOrigin'
    ]);
    if (m['schemaVersion'] is! int ||
        (external
            ? m['originKind'] != 'external'
            : m['schemaVersion'] != 1 ||
                !['local', 'synthetic'].contains(m['originKind']))) {
      generatedFail(GeneratedFailure.corruptState);
    }
    final items =
        generatedList(m['items']).map(GeneratedItem.fromJson).toList();
    final requested = generatedInt(m['requestedCount'], min: 1, max: 50);
    final id = generatedToken(m['proposalId'], uuid: true);
    final created = generatedInt(m['createdAtUtcMs']);
    final updated = generatedInt(m['updatedAtUtcMs'], min: created);
    final revision = generatedInt(m['reviewRevision']);
    final status = GeneratedStatus.values.firstWhere(
        (v) => v.code == m['lifecycleStatus'],
        orElse: () => generatedFail(GeneratedFailure.corruptState));
    final receipt = m['commitReceipt'] == null
        ? null
        : GeneratedReceipt.fromJson(m['commitReceipt']);
    if (items.isEmpty ||
        m['actualCount'] is! int ||
        m['actualCount'] != items.length ||
        m['countMismatchWarning'] is! bool ||
        m['countMismatchWarning'] != (requested != items.length) ||
        items.map((i) => i.itemId).toSet().length != items.length ||
        items.map((i) => i.itemKey).toSet().length != items.length ||
        items.map((i) => i.original.questionId).toSet().length !=
            items.length ||
        (status == GeneratedStatus.committed) != (receipt != null)) {
      generatedFail(GeneratedFailure.corruptState);
    }
    for (var i = 0; i < items.length; i++) {
      if (items[i].position != i) generatedFail(GeneratedFailure.corruptState);
    }
    if (status == GeneratedStatus.rejected &&
        items.any((i) => i.decision != GeneratedDecision.rejected)) {
      generatedFail(GeneratedFailure.corruptState);
    }
    if (receipt != null &&
        (receipt.proposalId != id ||
            receipt.reviewRevision != revision ||
            receipt.committedAtUtcMs != updated ||
            generatedCanonical(receipt.itemMappings.keys.toList()) !=
                generatedCanonical(items
                    .where((i) => i.decision == GeneratedDecision.accepted)
                    .map((i) => i.itemId)
                    .toList()) ||
            items.any((i) =>
                i.decision == GeneratedDecision.unreviewed ||
                i.decision == GeneratedDecision.deferred))) {
      generatedFail(GeneratedFailure.corruptState);
    }
    generatedSize(
        items
            .map((i) => {
                  'draft': const QuestionDraftV2Codec().encode(i.original),
                  'evidence': i.evidence.map((e) => e.toJson()).toList()
                })
            .toList(),
        GeneratedLimits.batchBytes);
    generatedSize(
        items
            .map((i) => {
                  'draft': const QuestionDraftV2Codec().encode(i.working),
                  'decision': i.decision.name,
                  'evidenceAcknowledgement': i.evidenceAcknowledgement,
                  'evidence': i.evidence.map((e) => e.toJson()).toList()
                })
            .toList(),
        GeneratedLimits.batchBytes);
    final originalTarget = GeneratedTarget.fromJson(m['originalTarget']);
    final profileId = generatedToken(m['clientProfileId'], uuid: external);
    final key = generatedToken(m['submissionKey']);
    final origin = external
        ? ExternalProposalOrigin.fromPersistedPayload(m['externalOrigin'],
            clientProfileId: profileId,
            submissionKey: key,
            originalTarget: originalTarget)
        : null;
    origin?.validateOriginalEvidence(items);
    return GeneratedQuestionProposal(
        proposalId: id,
        createdAtUtcMs: created,
        updatedAtUtcMs: updated,
        localOwner: generatedToken(m['localOwner']),
        originKind: m['originKind'] as String,
        clientProfileId: profileId,
        submissionKey: key,
        semanticFingerprint: generatedDigest(m['semanticFingerprint']),
        requestedCount: requested,
        originalTarget: originalTarget,
        target: GeneratedTarget.fromJson(m['target']),
        reviewRevision: revision,
        lifecycleStatus: status,
        items: items,
        commitReceipt: receipt,
        externalOrigin: origin);
  }
}

RichContent generatedContent(Object? v, {bool nonempty = false}) {
  generatedSize(v, 32 * 1024);
  final nodes = <ContentNode>[];
  for (final value in generatedList(v, max: 256)) {
    if (value is! Map) generatedFail(GeneratedFailure.invalidSubmission);
    final type = value['type'];
    if (!['text', 'inline_math', 'block_math'].contains(type)) {
      generatedFail(GeneratedFailure.unsupportedContent);
    }
    final key = type == 'text' ? 'text' : 'latex';
    final m = generatedObject(value, ['type', key]);
    final text = m[key];
    if (text is! String) generatedFail(GeneratedFailure.invalidSubmission);
    if (text.runes.length > 4096 || utf8.encode(text).length > 16384) {
      generatedFail(GeneratedFailure.resourceLimit);
    }
    if (RichContentPrivacyAdmission.isUnsafeFallbackString(text) ||
        RegExp(r'https?://|\bdata:|\bfile:|<\/?[A-Za-z][^>]*>|[A-Za-z]:[\\/]|\\\\|[A-Za-z0-9+/]{128,}={0,2}',
                caseSensitive: false)
            .hasMatch(text)) {
      generatedFail(GeneratedFailure.unsafePayload);
    }
    nodes.add(switch (type) {
      'text' => TextNode(text),
      'inline_math' => InlineMathNode(text),
      _ => BlockMathNode(text)
    });
  }
  final content = RichContent(nodes: nodes);
  try {
    const RichContentPrivacyAdmission().validate(content);
  } on FormatException {
    generatedFail(GeneratedFailure.resourceLimit);
  }
  if (nonempty &&
      nodes.every((n) => switch (n) {
            TextNode(:final text) => text.trim().isEmpty,
            InlineMathNode(:final latex) ||
            BlockMathNode(:final latex) =>
              latex.trim().isEmpty,
            _ => true
          })) {
    generatedFail(GeneratedFailure.qualityBlocked);
  }
  return content;
}

List<Object?> generatedContentJson(RichContent c) => c.nodes
    .map<Object?>((n) => switch (n) {
          TextNode(:final text) => {'type': 'text', 'text': text},
          InlineMathNode(:final latex) => {
              'type': 'inline_math',
              'latex': latex
            },
          BlockMathNode(:final latex) => {'type': 'block_math', 'latex': latex},
          _ => generatedFail(GeneratedFailure.unsupportedContent)
        })
    .toList();

void validateGeneratedDraft(QuestionDraftV2 d) {
  generatedToken(d.questionId, uuid: true);
  generatedContent(generatedContentJson(d.stem), nonempty: true);
  if (d.assetRefs.isNotEmpty ||
      d.issues.isNotEmpty ||
      d.questionNumber != null) {
    generatedFail(GeneratedFailure.invalidSubmission);
  }
  for (final ref in d.sourceRefs) {
    generatedToken(ref.sourceId, uuid: true);
  }
  final labels = <String>{};
  for (final option in d.options) {
    generatedToken(option.optionId, uuid: true);
    if (option.label.isEmpty ||
        !labels.add(option.label) ||
        option.sourceRef != null) {
      generatedFail(GeneratedFailure.invalidSubmission);
    }
    generatedContent(generatedContentJson(option.content), nonempty: true);
  }
  if (d.kind == QuestionKind.singleChoice) {
    if (d.options.length < 2 ||
        d.options.length > 26 ||
        d.answer is! ChoiceAnswer ||
        (d.answer as ChoiceAnswer).optionIds.length != 1 ||
        !d.options.any(
            (o) => o.optionId == (d.answer as ChoiceAnswer).optionIds.single)) {
      generatedFail(GeneratedFailure.invalidSubmission);
    }
  } else {
    if (d.options.isNotEmpty || d.answer is! ContentAnswer) {
      generatedFail(GeneratedFailure.invalidSubmission);
    }
    generatedContent(generatedContentJson((d.answer as ContentAnswer).content),
        nonempty: true);
  }
  if (d.explanation != null) {
    generatedContent(generatedContentJson(d.explanation!));
  }
  generatedSize(
      const QuestionDraftV2Codec().encode(d), GeneratedLimits.itemBytes);
}

bool generatedSameStructure(QuestionDraftV2 a, QuestionDraftV2 b) =>
    a.questionId == b.questionId &&
    a.kind == b.kind &&
    a.questionNumber == b.questionNumber &&
    generatedCanonical(a.sourceRefs.map(_sourceJson).toList()) ==
        generatedCanonical(b.sourceRefs.map(_sourceJson).toList()) &&
    a.options.length == b.options.length &&
    List.generate(
        a.options.length,
        (i) =>
            a.options[i].optionId == b.options[i].optionId &&
            a.options[i].label == b.options[i].label &&
            a.options[i].sourceRef == b.options[i].sourceRef).every((v) => v);

/// Structural signature intentionally works for retained image/table/legacy typed bank rows too.
Object? generatedSemantics(QuestionDraftV2 d) {
  final m = const QuestionDraftV2Codec().encode(d);
  m.remove('questionId');
  m.remove('sourceRefs');
  m.remove('assetRefs');
  m.remove('issues');
  m.remove('questionNumber');
  m['options'] = [
    for (final o in (m['options'] as List))
      {'label': o['label'], 'content': o['content']}
  ];
  if (d.answer case ChoiceAnswer(:final optionIds)) {
    m['answer'] = {
      'type': 'choice',
      'optionPositions': optionIds
          .map((id) => d.options.indexWhere((o) => o.optionId == id))
          .toList()
    };
  }
  return m;
}

Object? generatedSubmissionSemantics(
        GeneratedTarget target, List<GeneratedItem> items) =>
    {
      'target': target.toJson(),
      'items': [
        for (final i in items)
          {
            'content': generatedSemantics(i.original),
            'evidence': i.evidence
                .map((e) => Map<String, Object?>.from(e.toJson())
                  ..remove('evidenceKey'))
                .toList()
          }
      ]
    };
