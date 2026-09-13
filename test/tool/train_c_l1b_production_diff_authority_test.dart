import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_evidence_probe.dart';
import '../../tool/train_c_l1b_production_diff_authority.dart';
import '../../tool/train_c_l1b_review_authorization.dart';
import '../../tool/train_c_production_authority_token.dart';
import '../../tool/train_c_review_authorization.dart';

void main() {
  const head = 'a000000000000000000000000000000000000000';
  const base = 'b000000000000000000000000000000000000000';
  const productionBase = 'c000000000000000000000000000000000000000';
  const seamBlob = 'd000000000000000000000000000000000000000';
  const libTree = 'e000000000000000000000000000000000000000';

  test('historical L1B still admits exactly one reviewed seam blob', () {
    final authority = TrainCL1BProductionDiffAuthority(
      approvedHarnessHead: head,
      approvedBase: base,
      approvedProductionBase: productionBase,
      approvedProductionSeamBlobSha: seamBlob,
      currentHeadReader: () => head,
      masterReader: () => base,
      changedPathsReader: (value) {
        expect(value, productionBase);
        return const <String>[trainCL1BApprovedProductionPath];
      },
      blobReader: (valueHead, path) {
        expect(valueHead, head);
        expect(path, trainCL1BApprovedProductionPath);
        return seamBlob;
      },
    );

    final result = authority.verify();
    expect(result.totalProductionDiffCount, 1);
    expect(result.approvedProductionDiffCount, 1);
    expect(result.unexpectedProductionDiffCount, 0);
    expect(result.approvedSeamMatched, isTrue);
  });

  test('historical L1B still rejects an unrelated production path', () {
    final authority = TrainCL1BProductionDiffAuthority(
      approvedHarnessHead: head,
      approvedBase: base,
      approvedProductionBase: productionBase,
      approvedProductionSeamBlobSha: seamBlob,
      currentHeadReader: () => head,
      masterReader: () => base,
      changedPathsReader: (_) => const <String>[
        trainCL1BApprovedProductionPath,
        'lib/core/database/database_helper.dart',
      ],
      blobReader: (_, __) => seamBlob,
    );

    expect(
      authority.verify,
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_HEAD_DRIFT',
        ),
      ),
    );
  });

  test('final Package-B authority pins the complete reviewed lib tree', () {
    final token = trainCFinalLibTreeAuthorityToken(libTree);
    final authority = TrainCL1BProductionDiffAuthority(
      approvedHarnessHead: head,
      approvedBase: base,
      approvedProductionBase: base,
      approvedProductionSeamBlobSha: token,
      currentHeadReader: () => head,
      masterReader: () => base,
      changedPathsReader: (value) {
        expect(value, base);
        return const <String>[
          'lib/domain/source/source_document_codec.dart',
          'lib/domain/source/source_part.dart',
          'lib/services/import_pipeline/ocr_table_projection.dart',
          'lib/services/import_pipeline/question_draft_v2_legacy_projection.dart',
          'lib/services/import_pipeline/typed_question_assembler.dart',
          'lib/services/llm_providers/zhipu_ocr_client.dart',
        ];
      },
      blobReader: (_, __) => throw StateError('unused'),
      libTreeReader: (valueHead) {
        expect(valueHead, head);
        return libTree;
      },
    );

    final result = authority.verify();
    expect(result.totalProductionDiffCount, 6);
    expect(result.approvedProductionDiffCount, 6);
    expect(result.unexpectedProductionDiffCount, 0);
    expect(result.approvedSeamMatched, isTrue);
  });

  test('final Package-B authority rejects any lib tree drift', () {
    final authority = TrainCL1BProductionDiffAuthority(
      approvedHarnessHead: head,
      approvedBase: base,
      approvedProductionBase: base,
      approvedProductionSeamBlobSha: trainCFinalLibTreeAuthorityToken(libTree),
      currentHeadReader: () => head,
      masterReader: () => base,
      changedPathsReader: (_) => const <String>[
        'lib/services/llm_providers/zhipu_ocr_client.dart',
      ],
      blobReader: (_, __) => throw StateError('unused'),
      libTreeReader: (_) => 'f000000000000000000000000000000000000000',
    );

    expect(
      authority.verify,
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_HEAD_DRIFT',
        ),
      ),
    );
  });

  test('final Package-B review identity uses reviewed master as baseline', () {
    final token = trainCFinalLibTreeAuthorityToken(libTree);
    final reviewed = TrainCL1BReviewAuthorization.requireFromEnvironment(
      environment: <String, String>{
        trainCApprovedHarnessHeadEnvironment: head,
        trainCL1BApprovedBaseEnvironment: base,
        trainCL1BApprovedProductionSeamBlobEnvironment: token,
      },
    );

    expect(reviewed.approvedHarnessHead, head);
    expect(reviewed.approvedBase, base);
    expect(reviewed.approvedProductionBase, base);
    expect(reviewed.approvedProductionSeamBlobSha, token);
  });

  test('historical review identity keeps frozen TRAIN-B production base', () {
    final reviewed = TrainCL1BReviewAuthorization.requireFromEnvironment(
      environment: const <String, String>{
        trainCApprovedHarnessHeadEnvironment: head,
        trainCL1BApprovedBaseEnvironment: base,
        trainCL1BApprovedProductionSeamBlobEnvironment: seamBlob,
      },
    );

    expect(reviewed.approvedProductionBase, trainCApprovedProductionBase);
    expect(reviewed.approvedProductionSeamBlobSha, seamBlob);
  });

  test('malformed final authority token fails closed', () {
    expect(
      () => TrainCL1BReviewAuthorization.requireFromEnvironment(
        environment: const <String, String>{
          trainCApprovedHarnessHeadEnvironment: head,
          trainCL1BApprovedBaseEnvironment: base,
          trainCL1BApprovedProductionSeamBlobEnvironment: 'lib_tree:not-a-sha',
        },
      ),
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_CODE_IDENTITY_MISMATCH',
        ),
      ),
    );
  });
}
