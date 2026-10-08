import '../../domain/question/question_draft_v2.dart';
import '../../domain/generated_question/generated_question_contract.dart';

/// Only trusted internal Application composition constructs this context.
/// Neither origin, target, ownership nor current authorization comes from JSON.
final class GeneratedOriginContext {
  GeneratedOriginContext(
      {required this.localOwner,
      required this.originKind,
      required this.clientProfileId,
      required this.target,
      required Iterable<GeneratedEvidence> evidence,
      required this.isCurrent})
      : evidence = List.unmodifiable(evidence);
  final String localOwner, originKind, clientProfileId;
  final GeneratedTarget target;
  final List<GeneratedEvidence> evidence;
  final bool Function() isCurrent;
  void validate() {
    if (!isCurrent()) generatedFail(GeneratedFailure.unauthorized);
    generatedToken(localOwner);
    generatedToken(clientProfileId);
    if (!['local', 'synthetic'].contains(originKind)) {
      generatedFail(GeneratedFailure.unauthorized);
    }
    GeneratedTarget.fromJson(target.toJson());
    if (evidence.length > 256 ||
        evidence.map((e) => e.evidenceKey).toSet().length != evidence.length) {
      generatedFail(GeneratedFailure.invalidEvidence);
    }
    for (final e in evidence) {
      GeneratedEvidence.fromJson(e.toJson());
    }
  }
}

/// Current local user confirmation; never a candidate approval flag or receipt.
/// The caller binds confirmation to an explicitly displayed target and owner.
final class GeneratedLocalContext {
  const GeneratedLocalContext(
      {required this.localOwner,
      required this.confirmedTarget,
      required this.isCurrent});
  final String localOwner;
  final GeneratedTarget confirmedTarget;
  final bool Function() isCurrent;
  void validate() {
    if (!isCurrent()) generatedFail(GeneratedFailure.unauthorized);
    generatedToken(localOwner);
    GeneratedTarget.fromJson(confirmedTarget.toJson());
  }
}

final class GeneratedStageInput {
  GeneratedStageInput(
      {required this.submissionKey,
      required this.requestedCount,
      required Iterable<GeneratedItem> items})
      : items = List.unmodifiable(items);
  final String submissionKey;
  final int requestedCount;
  final List<GeneratedItem> items;
}

final class GeneratedStageResult {
  GeneratedStageResult(this.proposal, Iterable<String> duplicateItemIds)
      : duplicateItemIds = List.unmodifiable(duplicateItemIds);
  final GeneratedQuestionProposal proposal;
  final List<String> duplicateItemIds;
}

final class GeneratedReviewFlush {
  factory GeneratedReviewFlush.fromJson(Object? value) {
    generatedSize(value, GeneratedLimits.flushBytes);
    final m = generatedObject(
        value, ['proposalId', 'expectedReviewRevision', 'operations']);
    final ops = generatedList(m['operations']);
    if (ops.isEmpty) generatedFail(GeneratedFailure.invalidEdit);
    for (final v in ops) {
      if (v is! Map) generatedFail(GeneratedFailure.invalidEdit);
      switch (v['type']) {
        case 'edit':
          final op = generatedObject(v, ['type', 'edit']);
          final edit = op['edit'];
          if (edit is! Map) generatedFail(GeneratedFailure.invalidEdit);
          generatedObject(edit, [
            'field',
            'itemId',
            'value',
            if (edit['field'] == 'optionContent') 'optionId'
          ]);
          generatedToken(edit['itemId'], uuid: true);
          if (!['stem', 'answer', 'explanation', 'optionContent']
              .contains(edit['field'])) {
            generatedFail(GeneratedFailure.invalidEdit);
          }
          if (edit['field'] == 'optionContent') {
            generatedToken(edit['optionId'], uuid: true);
          }
        case 'decide':
          final op = generatedObject(v, ['type', 'itemId', 'decision']);
          generatedToken(op['itemId'], uuid: true);
          if (!GeneratedDecision.values.any((d) => d.name == op['decision'])) {
            generatedFail(GeneratedFailure.invalidEdit);
          }
        case 'acknowledge':
          final op = generatedObject(v, ['type', 'itemId', 'evidenceState']);
          generatedToken(op['itemId'], uuid: true);
          generatedList(op['evidenceState'], max: 8);
        case 'rebind':
          final op = generatedObject(v, ['type', 'target']);
          GeneratedTarget.fromJson(op['target']);
        default:
          generatedFail(GeneratedFailure.invalidEdit);
      }
    }
    return GeneratedReviewFlush._(generatedToken(m['proposalId'], uuid: true),
        generatedInt(m['expectedReviewRevision']), generatedCanonical(ops));
  }
  const GeneratedReviewFlush._(
      this.proposalId, this.expectedReviewRevision, this.operationsJson);
  final String proposalId, operationsJson;
  final int expectedReviewRevision;
  List<Object?> get operations => generatedList(
      generatedDecode(operationsJson, maxBytes: GeneratedLimits.flushBytes));
}

final class ApproveGeneratedProposalCommand {
  factory ApproveGeneratedProposalCommand.fromJson(Object? value) {
    final m = generatedObject(
        value, ['proposalId', 'expectedReviewRevision', 'approvedItemIds']);
    final ids = generatedList(m['approvedItemIds'])
        .map((v) => generatedToken(v, uuid: true))
        .toList();
    if (ids.isEmpty || ids.toSet().length != ids.length) {
      generatedFail(GeneratedFailure.reviewIncomplete);
    }
    return ApproveGeneratedProposalCommand._(
        generatedToken(m['proposalId'], uuid: true),
        generatedInt(m['expectedReviewRevision']),
        List.unmodifiable(ids));
  }
  const ApproveGeneratedProposalCommand._(
      this.proposalId, this.expectedReviewRevision, this.approvedItemIds);
  final String proposalId;
  final int expectedReviewRevision;
  final List<String> approvedItemIds;
}

final class RejectGeneratedProposalCommand {
  factory RejectGeneratedProposalCommand.fromJson(Object? value) {
    final m = generatedObject(value, ['proposalId', 'expectedReviewRevision']);
    return RejectGeneratedProposalCommand._(
        generatedToken(m['proposalId'], uuid: true),
        generatedInt(m['expectedReviewRevision']));
  }
  const RejectGeneratedProposalCommand._(
      this.proposalId, this.expectedReviewRevision);
  final String proposalId;
  final int expectedReviewRevision;
}

abstract interface class GeneratedQuestionPersistencePort {
  Future<GeneratedStageResult> stage(
      GeneratedStageInput input, GeneratedOriginContext context);
  Future<GeneratedQuestionProposal> read(
      String proposalId, GeneratedLocalContext context);
  Future<List<GeneratedQuestionProposal>> pending(
      GeneratedLocalContext context);
  Future<GeneratedQuestionProposal> flush(
      GeneratedReviewFlush command, GeneratedLocalContext context);
  Future<GeneratedReceipt> approve(
      ApproveGeneratedProposalCommand command, GeneratedLocalContext context);
  Future<GeneratedQuestionProposal> reject(
      RejectGeneratedProposalCommand command, GeneratedLocalContext context);
  Future<List<Object?>> evidenceState(
      String proposalId, String itemId, GeneratedLocalContext context);
}

final class GeneratedQuestionAdmission {
  GeneratedQuestionAdmission({required String Function() idFactory})
      : _id = idFactory;
  final String Function() _id;
  GeneratedStageInput admit(String json, GeneratedOriginContext context) {
    context.validate();
    try {
      final root = generatedObject(generatedDecode(json),
          ['schemaVersion', 'submissionKey', 'requestedCount', 'items']);
      if (root['schemaVersion'] != 1 || root['schemaVersion'] is! int) {
        generatedFail(GeneratedFailure.invalidSubmission);
      }
      final raw = generatedList(root['items']);
      if (raw.isEmpty) generatedFail(GeneratedFailure.invalidSubmission);
      final localKeys = <String>{};
      final items = <GeneratedItem>[];
      for (final v in raw) {
        generatedSize(v, GeneratedLimits.itemBytes);
        final m = generatedObject(v, [
          'itemKey',
          'kind',
          'stem',
          'options',
          'answer',
          'explanation',
          'evidenceKeys'
        ]);
        final itemKey = generatedToken(m['itemKey']);
        if (!localKeys.add(itemKey)) {
          generatedFail(GeneratedFailure.invalidSubmission);
        }
        final kind = QuestionKind.values.byName(m['kind'] as String);
        final options = <QuestionOption>[];
        final optionKeys = <String, String>{};
        for (final ov in generatedList(m['options'], max: 26)) {
          final om = generatedObject(ov, ['optionKey', 'label', 'content']);
          final key = generatedToken(om['optionKey']);
          if (optionKeys.containsKey(key) || om['label'] is! String) {
            generatedFail(GeneratedFailure.invalidSubmission);
          }
          final id = generatedToken(_id(), uuid: true);
          optionKeys[key] = id;
          options.add(QuestionOption(
              optionId: id,
              label: om['label'] as String,
              content: generatedContent(om['content'], nonempty: true)));
        }
        final answer = _candidateAnswer(m['answer'], kind, optionKeys);
        final keys = generatedList(m['evidenceKeys'], max: 8)
            .map(generatedToken)
            .toList();
        if (keys.toSet().length != keys.length) {
          generatedFail(GeneratedFailure.invalidEvidence);
        }
        final evidence = <GeneratedEvidence>[];
        for (final key in keys) {
          final matches = context.evidence.where((e) => e.evidenceKey == key);
          if (matches.length != 1) {
            generatedFail(GeneratedFailure.invalidEvidence);
          }
          evidence.add(matches.single);
        }
        final draft = QuestionDraftV2(
            questionId: generatedToken(_id(), uuid: true),
            kind: kind,
            stem: generatedContent(m['stem'], nonempty: true),
            options: options,
            answer: answer,
            explanation: m['explanation'] == null
                ? null
                : generatedContent(m['explanation']),
            sourceRefs: evidence.map((e) => e.sourceRef));
        validateGeneratedDraft(draft);
        items.add(GeneratedItem(
            itemId: generatedToken(_id(), uuid: true),
            itemKey: itemKey,
            position: items.length,
            original: draft,
            working: draft,
            evidence: evidence,
            decision: GeneratedDecision.unreviewed,
            evidenceAcknowledgement: null));
      }
      generatedSize(
          items.map((i) => i.toJson()).toList(), GeneratedLimits.batchBytes);
      return GeneratedStageInput(
          submissionKey: generatedToken(root['submissionKey']),
          requestedCount: generatedInt(root['requestedCount'], min: 1, max: 50),
          items: items);
    } on GeneratedQuestionException {
      rethrow;
    } on FormatException {
      generatedFail(GeneratedFailure.invalidSubmission);
    } on ArgumentError {
      generatedFail(GeneratedFailure.invalidSubmission);
    } on TypeError {
      generatedFail(GeneratedFailure.invalidSubmission);
    }
  }
}

QuestionAnswer _candidateAnswer(
    Object? v, QuestionKind kind, Map<String, String> options) {
  if (kind == QuestionKind.singleChoice) {
    final m = generatedObject(v, ['type', 'optionKeys']);
    final keys =
        generatedList(m['optionKeys'], max: 1).map(generatedToken).toList();
    if (m['type'] != 'choice' ||
        keys.length != 1 ||
        !options.containsKey(keys.single)) {
      generatedFail(GeneratedFailure.invalidSubmission);
    }
    return ChoiceAnswer(optionIds: [options[keys.single]!]);
  }
  final m = generatedObject(v, ['type', 'content']);
  if (m['type'] != 'content') {
    generatedFail(GeneratedFailure.invalidSubmission);
  }
  return ContentAnswer(content: generatedContent(m['content'], nonempty: true));
}

QuestionDraftV2 applyGeneratedEdit(
    QuestionDraftV2 old, Map<String, Object?> edit) {
  var stem = old.stem;
  var answer = old.answer;
  var explanation = old.explanation;
  var options = old.options;
  switch (edit['field']) {
    case 'stem':
      stem = generatedContent(edit['value'], nonempty: true);
    case 'explanation':
      explanation =
          edit['value'] == null ? null : generatedContent(edit['value']);
    case 'answer':
      final value = edit['value'];
      if (old.kind == QuestionKind.singleChoice) {
        final m = generatedObject(value, ['type', 'optionIds']);
        final ids = generatedList(m['optionIds'], max: 1)
            .map((v) => generatedToken(v, uuid: true))
            .toList();
        if (m['type'] != 'choice' || ids.length != 1) {
          generatedFail(GeneratedFailure.invalidEdit);
        }
        answer = ChoiceAnswer(optionIds: ids);
      } else {
        final m = generatedObject(value, ['type', 'content']);
        if (m['type'] != 'content') {
          generatedFail(GeneratedFailure.invalidEdit);
        }
        answer = ContentAnswer(
            content: generatedContent(m['content'], nonempty: true));
      }
    case 'optionContent':
      if (!old.options.any((o) => o.optionId == edit['optionId'])) {
        generatedFail(GeneratedFailure.invalidEdit);
      }
      final content = generatedContent(edit['value'], nonempty: true);
      options = [
        for (final o in old.options)
          if (o.optionId == edit['optionId'])
            QuestionOption(
                optionId: o.optionId,
                label: o.label,
                content: content,
                sourceRef: o.sourceRef)
          else
            o
      ];
    default:
      generatedFail(GeneratedFailure.invalidEdit);
  }
  final next = QuestionDraftV2(
      questionId: old.questionId,
      kind: old.kind,
      stem: stem,
      options: options,
      answer: answer,
      explanation: explanation,
      sourceRefs: old.sourceRefs,
      assetRefs: old.assetRefs,
      issues: old.issues,
      questionNumber: old.questionNumber);
  validateGeneratedDraft(next);
  return next;
}

/// No SQL, global resolver, Provider, ImportTask lifecycle or adapter exposure.
final class GeneratedQuestionService {
  GeneratedQuestionService(this.persistence, {required this.admission});
  final GeneratedQuestionPersistencePort persistence;
  final GeneratedQuestionAdmission admission;
  Future<GeneratedStageResult> stage(
          String json, GeneratedOriginContext context) =>
      persistence.stage(admission.admit(json, context), context);
  Future<GeneratedQuestionProposal> flush(
      GeneratedReviewFlush command, GeneratedLocalContext context) {
    context.validate();
    return persistence.flush(command, context);
  }

  Future<GeneratedReceipt> approve(
      ApproveGeneratedProposalCommand command, GeneratedLocalContext context) {
    context.validate();
    return persistence.approve(command, context);
  }

  Future<GeneratedQuestionProposal> reject(
      RejectGeneratedProposalCommand command, GeneratedLocalContext context) {
    context.validate();
    return persistence.reject(command, context);
  }
}
