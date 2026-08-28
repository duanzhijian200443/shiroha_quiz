import 'dart:io';

import 'train_c_evidence_probe.dart';
import 'train_c_production_authority_token.dart';
import 'train_c_review_authorization.dart';

const trainCL1BApprovedBaseEnvironment = 'TRAIN_C_APPROVED_BASE';
const trainCL1BApprovedProductionSeamBlobEnvironment =
    'TRAIN_C_APPROVED_PRODUCTION_SEAM_BLOB_SHA';

/// Independent out-of-band review identity for execution-capable TRAIN C.
///
/// Historical L1B continues to accept only the original exact seam blob and
/// keeps the frozen TRAIN-B production baseline. Final Package-B closure uses
/// an out-of-band `lib_tree:<sha>` token. In that mode the contemporaneous
/// independently reviewed master/base becomes the production baseline and the
/// production authority pins the complete `lib/` tree at the approved HEAD.
final class TrainCL1BReviewAuthorization {
  const TrainCL1BReviewAuthorization._();

  static TrainCReviewedIdentity requireFromEnvironment({
    Map<String, String>? environment,
  }) {
    final values = environment ?? Platform.environment;
    final head = values[trainCApprovedHarnessHeadEnvironment]?.trim() ?? '';
    final base = values[trainCL1BApprovedBaseEnvironment]?.trim() ?? '';
    final productionAuthority =
        values[trainCL1BApprovedProductionSeamBlobEnvironment]?.trim() ?? '';
    final finalLibTree =
        trainCFinalLibTreeShaFromAuthorityToken(productionAuthority);
    final validHistoricalBlob = _isCommitSha(productionAuthority);
    if (!_isCommitSha(head) ||
        !_isCommitSha(base) ||
        (!validHistoricalBlob && finalLibTree == null)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    return TrainCReviewedIdentity(
      approvedHarnessHead: head,
      approvedBase: base,
      approvedProductionBase:
          finalLibTree == null ? trainCApprovedProductionBase : base,
      approvedProductionSeamBlobSha: productionAuthority,
    );
  }

  static bool _isCommitSha(String value) =>
      RegExp(r'^[0-9a-f]{40}$').hasMatch(value);
}
