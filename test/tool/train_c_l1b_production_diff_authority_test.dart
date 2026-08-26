import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_l1b_production_diff_authority.dart';

void main() {
  test('current reviewed L1B seam is the only production diff', () {
    final head =
        (Process.runSync('git', ['rev-parse', 'HEAD']).stdout as String).trim();
    final base = (Process.runSync('git', ['rev-parse', 'origin/master']).stdout
            as String)
        .trim();
    final authority = TrainCL1BProductionDiffAuthority(
      approvedHarnessHead: head,
      approvedBase:
          base.isNotEmpty ? base : '03e8fc6d0d65ef906e4cd306d37c166a0e55cd35',
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
