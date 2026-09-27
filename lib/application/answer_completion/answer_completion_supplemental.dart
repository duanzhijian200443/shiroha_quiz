import '../file_library/file_library_ports.dart';
import '../parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../supplemental_answers/supplemental_answer_activation_service.dart';
import '../supplemental_answers/supplemental_answer_failure.dart';
import '../supplemental_answers/supplemental_answer_source_acquisition_service.dart';
import '../supplemental_answers/supplemental_answer_target_port.dart';
import '../supplemental_answers/target_question_snapshot_service.dart';
import '../../domain/supplemental_answers/supplemental_answer_scope.dart';
import 'answer_completion_query.dart';

/// Binds existing P6 services to a complete, selected imported set. The target
/// port rechecks membership at session start, after any file/OCR wait.
final class AnswerCompletionSupplementalService {
  const AnswerCompletionSupplementalService(
      {required this.query,
      required this.fileCatalog,
      required this.artifactPort,
      required this.ingestion});
  final AnswerCompletionQuery query;
  final LibraryFileRepositoryPort fileCatalog;
  final ParsedArtifactLifecyclePort artifactPort;
  final FileIngestionPort ingestion;

  AnswerCompletionSupplementalBinding bind(AnswerCompletionSet selected) {
    if (!selected.canSupplement) {
      throw const SupplementalAnswerException(
          SupplementalAnswerFailure.targetUnavailable);
    }
    final scope = ExplicitQuestionScope(
        storageIds: selected.members.map((m) => m.storageId));
    final activation = SupplementalAnswerActivationService(
      fileCatalog: fileCatalog,
      artifactPort: artifactPort,
      targetSnapshotService: TargetQuestionSnapshotService(
        port: _CompleteSetTarget(query, selected, scope),
      ),
    );
    return AnswerCompletionSupplementalBinding(
      scope: scope,
      activation: activation,
      acquisition: SupplementalAnswerSourceAcquisitionService(
          ingestion: ingestion,
          artifactPort: artifactPort,
          activationService: activation),
    );
  }
}

final class AnswerCompletionSupplementalBinding {
  const AnswerCompletionSupplementalBinding(
      {required this.scope,
      required this.activation,
      required this.acquisition});
  final ExplicitQuestionScope scope;
  final SupplementalAnswerActivationService activation;
  final SupplementalAnswerSourceAcquisitionService acquisition;
}

final class _CompleteSetTarget implements SupplementalAnswerTargetPort {
  const _CompleteSetTarget(this.query, this.selected, this.scope);
  final AnswerCompletionQuery query;
  final AnswerCompletionSet selected;
  final ExplicitQuestionScope scope;

  @override
  Future<List<SupplementalTargetRead>> listTypedQuestionsByIds(
      Iterable<String> storageIds) async {
    final requested = storageIds.toList();
    if (!_sameIds(requested, scope.storageIds)) _unavailable();
    final read = await query.readBank(selected.set.bankName);
    if (read is! AnswerCompletionSnapshot) _unavailable();
    final current = read.findSet(selected.set.setId);
    if (current == null ||
        !current.canSupplement ||
        !_sameIds(current.members.map((m) => m.storageId).toList(),
            scope.storageIds)) {
      _unavailable();
    }
    return [
      for (final member in current.members)
        SupplementalTargetRead(
            storageId: member.storageId,
            bankName: current.set.bankName,
            typedDraft: member.draft)
    ];
  }

  @override
  Future<List<SupplementalTargetRead>> listTypedQuestionsByBank(
          String bankName) async =>
      _unavailable();
  @override
  Future<List<String>> listProjectBankNames(String projectId) async =>
      _unavailable();
}

bool _sameIds(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Never _unavailable() => throw const SupplementalAnswerException(
    SupplementalAnswerFailure.targetUnavailable);
