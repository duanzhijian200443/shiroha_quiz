import 'train_c_evidence_probe.dart';
import 'train_c_review_authorization.dart';

const trainCL1BApprovedBaseEnvironment = 'TRAIN_C_APPROVED_BASE';

/// Independent out-of-band review identity for the execution-capable L1B
/// harness.
///
/// L1A used a source-frozen branch base because it was itself the first
/// harness activation. L1B may be executed on an independently reviewed PR
/// head before merge or on an independently reviewed merged head afterwards,
/// so both the harness HEAD and the contemporaneous base/master identity are
/// supplied out of band. The production baseline remains frozen at TRAIN B;
/// therefore any `lib/**` change still fails the production-diff gate.
final class TrainCL1BReviewAuthorization {
  const TrainCL1BReviewAuthorization._();

  static TrainCReviewedIdentity requireFromEnvironment({
    Map<String, String>? environment,
  }) {
    final values = environment ?? const <String, String>{};
    final head = values[trainCApprovedHarnessHeadEnvironment]?.trim() ?? '';
    final base = values[trainCL1BApprovedBaseEnvironment]?.trim() ?? '';
    if (!_isCommitSha(head) || !_isCommitSha(base)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    return TrainCReviewedIdentity(
      approvedHarnessHead: head,
      approvedBase: base,
      approvedProductionBase: trainCApprovedProductionBase,
    );
  }

  static bool _isCommitSha(String value) =>
      RegExp(r'^[0-9a-f]{40}$').hasMatch(value);
}
