import 'dart:io';

import 'train_c_evidence_probe.dart';

const trainCApprovedHarnessHeadEnvironment =
    'TRAIN_C_APPROVED_HARNESS_HEAD';
const trainCApprovedBase =
    'f1d58a278180eff38686338c28f26e4d1d7b8b7a';
const trainCApprovedProductionBase =
    '711fd33f564b9fb6bb3c992d6458b0075990646c';

/// Out-of-band review authorization for any execution-capable TRAIN C gate.
///
/// The reviewed HEAD is intentionally not stored in repository source because
/// doing so creates a self-referential commit SHA. A reviewer/execution wrapper
/// must provide the immutable approved HEAD through the environment.
final class TrainCReviewAuthorization {
  const TrainCReviewAuthorization._();

  static TrainCReviewedIdentity requireFromEnvironment({
    Map<String, String>? environment,
  }) {
    final values = environment ?? Platform.environment;
    final head = values[trainCApprovedHarnessHeadEnvironment]?.trim() ?? '';
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(head)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    return TrainCReviewedIdentity(
      approvedHarnessHead: head,
      approvedBase: trainCApprovedBase,
      approvedProductionBase: trainCApprovedProductionBase,
    );
  }
}
