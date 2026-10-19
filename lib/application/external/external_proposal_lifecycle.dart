import '../../domain/generated_question/generated_question_contract.dart';
import '../generated_question/generated_local_authority.dart';
import 'external_runtime_admission.dart';

/// Metadata only. Counts of review decisions are withheld while still pending.
final class ExternalProposalLifecycle {
  const ExternalProposalLifecycle(
      {required this.submissionKey,
      required this.status,
      required this.requestedCount,
      required this.actualCount,
      required this.committedCount,
      required this.rejectedCount});
  final String submissionKey;
  final GeneratedStatus status;
  final int requestedCount, actualCount, committedCount, rejectedCount;
  Map<String, Object?> toJson() => {
        'submissionKey': submissionKey,
        'lifecycleStatus': status.code,
        'requestedCount': requestedCount,
        'actualCount': actualCount,
        'committedCount': committedCount,
        'rejectedCount': rejectedCount,
      };
}

/// Private runtime proof; independent of STAGE access and historical Origin.
final class ExternalProposalLifecycleAccess {
  ExternalProposalLifecycleAccess._(this.runtime, this._localOwner);
  final ExternalRuntimeAccess runtime;
  final GeneratedLocalAuthoritySession _localOwner;
  String get profileId => runtime.profileId;
  String get localOwner => _localOwner.localOwner;
  int get revision => runtime.grantSnapshot!.revision;
  void validate() {
    runtime.validate();
    if (!_localOwner.isCurrent) generatedFail(GeneratedFailure.unauthorized);
  }
}

abstract interface class ExternalProposalLifecyclePort {
  Future<ExternalProposalLifecycle> queryExternalProposalLifecycle(
      ExternalProposalLifecycleAccess access, String submissionKey);
  Future<void> releaseExternalProposalLifecycle(
      ExternalProposalLifecycleAccess access,
      ExternalProposalLifecycle summary);
}

/// The Gateway supplies READ admission/budgets and performs final release.
/// Persistence and current policy checks remain in the existing Proposal owner.
final class ExternalProposalLifecycleService {
  ExternalProposalLifecycleService(
      {required this.admission,
      required GeneratedLocalAuthoritySession localOwner,
      required ExternalProposalLifecyclePort persistence})
      : _localOwner = localOwner,
        _persistence = persistence;
  final ExternalRuntimeAdmission admission;
  final GeneratedLocalAuthoritySession _localOwner;
  final ExternalProposalLifecyclePort _persistence;
  Future<ExternalProposalLifecycleAccess> _access(
      ExternalRuntimeAccess runtime) async {
    admission.validateSession(runtime.session);
    runtime.validate();
    final access = ExternalProposalLifecycleAccess._(runtime, _localOwner);
    access.validate();
    return access;
  }

  Future<ExternalProposalLifecycle> query(
          ExternalRuntimeAccess runtime, String submissionKey) async =>
      _persistence.queryExternalProposalLifecycle(
          await _access(runtime), generatedToken(submissionKey));
  Future<void> release(ExternalRuntimeAccess runtime,
          ExternalProposalLifecycle summary) async =>
      _persistence.releaseExternalProposalLifecycle(
          await _access(runtime), summary);
}
