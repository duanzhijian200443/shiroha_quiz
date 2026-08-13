import '../../data/models/persisted_question.dart';
import '../../domain/supplemental_answers/answer_match_record.dart';
import '../../domain/supplemental_answers/supplemental_answer_scope.dart';
import 'supplemental_answer_target_port.dart';

/// One report item for the target-scope resolution.
///
/// `missingTarget` and `duplicateTarget` apply to an explicit subset;
/// `legacyIneligible` marks a visible but non-typed target that cannot
/// receive a supplemental answer in P6.
enum TargetScopeReportCode {
  missingTarget,
  duplicateTarget,
  legacyIneligible,
}

final class TargetScopeReport {
  const TargetScopeReport({
    required this.code,
    required this.storageId,
    this.bankName,
  });

  final TargetScopeReportCode code;
  final String storageId;
  final String? bankName;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TargetScopeReport &&
            code == other.code &&
            storageId == other.storageId &&
            bankName == other.bankName;
  }

  @override
  int get hashCode => Object.hash(code, storageId, bankName);
}

/// Frozen typed target snapshot for one P6 session.
///
/// Project is resolved here at session start into a complete typed-question
/// snapshot; later Project relation drift does not change the session.
final class TargetQuestionSnapshot {
  const TargetQuestionSnapshot({
    required this.targets,
    required this.reports,
  });

  final List<AnswerTargetReference> targets;
  final List<TargetScopeReport> reports;

  bool get isEmpty => targets.isEmpty;
}

/// Resolves one explicit target scope into a typed-question snapshot.
///
/// Legacy questions remain visible-but-ineligible and are reported, never
/// silently dropped. An explicit subset preserves caller order and reports
/// missing and duplicate ids explicitly.
final class TargetQuestionSnapshotService {
  const TargetQuestionSnapshotService({required this.port});

  final SupplementalAnswerTargetPort port;

  Future<TargetQuestionSnapshot> resolve(
    SupplementalAnswerTargetScope scope,
  ) async {
    switch (scope) {
      case QuestionBankScope(:final bankName):
        final questions = await port.listTypedQuestionsByBank(bankName);
        return _snapshotFromQuestions(questions);
      case ProjectScope(:final projectId):
        final bankNames = await port.listProjectBankNames(projectId);
        final questions = <PersistedQuestion>[];
        for (final bankName in bankNames) {
          questions.addAll(await port.listTypedQuestionsByBank(bankName));
        }
        return _snapshotFromQuestions(questions);
      case ExplicitQuestionScope(:final storageIds):
        final questions = await port.listTypedQuestionsByIds(storageIds);
        return _snapshotFromExplicit(storageIds, questions);
    }
  }

  TargetQuestionSnapshot _snapshotFromQuestions(
    List<PersistedQuestion> questions,
  ) {
    final targets = <AnswerTargetReference>[];
    final reports = <TargetScopeReport>[];
    for (final question in questions) {
      if (question is TypedPersistedQuestion) {
        targets.add(
          AnswerTargetReference(
            storageId: question.storageId,
            bankName: question.bankName,
            draft: question.draft,
          ),
        );
      } else {
        reports.add(
          TargetScopeReport(
            code: TargetScopeReportCode.legacyIneligible,
            storageId: question.storageId,
            bankName: question.bankName,
          ),
        );
      }
    }
    return TargetQuestionSnapshot(
      targets: List<AnswerTargetReference>.unmodifiable(targets),
      reports: List<TargetScopeReport>.unmodifiable(reports),
    );
  }

  TargetQuestionSnapshot _snapshotFromExplicit(
    List<String> storageIds,
    List<PersistedQuestion> questions,
  ) {
    final byId = <String, PersistedQuestion>{
      for (final question in questions) question.storageId: question,
    };
    final seen = <String>{};
    final targets = <AnswerTargetReference>[];
    final reports = <TargetScopeReport>[];
    for (final id in storageIds) {
      if (!seen.add(id)) {
        reports.add(
          TargetScopeReport(
            code: TargetScopeReportCode.duplicateTarget,
            storageId: id,
          ),
        );
        continue;
      }
      final question = byId[id];
      if (question == null) {
        reports.add(
          TargetScopeReport(
            code: TargetScopeReportCode.missingTarget,
            storageId: id,
          ),
        );
        continue;
      }
      if (question is TypedPersistedQuestion) {
        targets.add(
          AnswerTargetReference(
            storageId: question.storageId,
            bankName: question.bankName,
            draft: question.draft,
          ),
        );
      } else {
        reports.add(
          TargetScopeReport(
            code: TargetScopeReportCode.legacyIneligible,
            storageId: question.storageId,
            bankName: question.bankName,
          ),
        );
      }
    }
    return TargetQuestionSnapshot(
      targets: List<AnswerTargetReference>.unmodifiable(targets),
      reports: List<TargetScopeReport>.unmodifiable(reports),
    );
  }
}
