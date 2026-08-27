import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';

import '../../tool/train_c_l1b_live_runtime.dart';

void main() {
  test('typed-candidate fallback is classified before candidate image closure',
      () {
    expect(
      trainCL1BPendingReviewClosureFailureCode(
        storageRoute: ImportStorageRoute.legacyV1,
        storageReason: 'typed_candidate_unsupported_structure',
        candidateAssetLeasePresent: false,
      ),
      'TRAIN_C_TYPED_ROUTE_FAILURE',
    );
  });

  test('typed route without a lease keeps the image closure failure', () {
    expect(
      trainCL1BPendingReviewClosureFailureCode(
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: 'typed_candidate_ready',
        candidateAssetLeasePresent: false,
      ),
      'TRAIN_C_IMAGE_CLOSURE_FAILURE',
    );
  });

  test('typed route with a lease proceeds to the original closure path', () {
    expect(
      trainCL1BPendingReviewClosureFailureCode(
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: 'typed_candidate_ready',
        candidateAssetLeasePresent: true,
      ),
      isNull,
    );
  });

  test('unknown legacy reason is not treated as a typed-candidate reason', () {
    expect(
      trainCL1BPendingReviewClosureFailureCode(
        storageRoute: ImportStorageRoute.legacyV1,
        storageReason: 'legacy_import_reason',
        candidateAssetLeasePresent: false,
      ),
      isNull,
    );
  });
}
