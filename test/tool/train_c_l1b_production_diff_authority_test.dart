import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_l1b_production_diff_authority.dart';

void main() {
  test('current reviewed L1B seam is the only production diff', () {
    final head =
        (Process.runSync('git', ['rev-parse', 'HEAD']).stdout as String).trim();
    final authority = TrainCL1BProductionDiffAuthority(
      approvedHarnessHead: head,
      approvedBase: '2f0aee1a7b81cd7a694b4de10702c6e798b9dd04',
      approvedProductionBase: '711fd33f564b9fb6bb3c992d6458b0075990646c',
      approvedProductionSeamBlobSha:
          TrainCL1BProductionDiffAuthority.readProductionSeamBlobSha(head),
    );
    final result = authority.verify();
    expect(result.totalProductionDiffCount, 1);
    expect(result.approvedProductionDiffCount, 1);
    expect(result.unexpectedProductionDiffCount, 0);
    expect(result.approvedSeamMatched, isTrue);
  });
}
