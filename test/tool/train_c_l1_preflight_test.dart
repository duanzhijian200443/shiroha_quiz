import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_evidence_collector.dart';
import '../../tool/train_c_evidence_probe.dart';
import '../../tool/train_c_l1_preflight.dart';

final class _NoopGate implements TrainCExecutionStateGate {
  const _NoopGate();

  @override
  void verify() {}
}

final class _FailureGate implements TrainCExecutionStateGate {
  const _FailureGate(this.code);

  final String code;

  @override
  void verify() {
    throw TrainCEvidenceProbeException(code);
  }
}

void main() {
  test('clean pre-execution state passes before runtime creation', () {
    final reviewed = _reviewedForTest();
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: _NoopGate(),
      reviewedIdentity: reviewed,
      currentHeadReader: () => reviewed.approvedHarnessHead,
      fetchMaster: () {},
      masterReader: () => trainCL1BaseMaster,
      productionDiffReader: () => 0,
    );

    expect(gate.verify, returnsNormally);
  });

  for (final dirtyState in const <String>[
    'tracked',
    'staged',
    'untracked',
  ]) {
    test('$dirtyState dirty worktree is blocked', () {
      final reviewed = _reviewedForTest();
      final gate = TrainCPreExecutionGitGate(
        executionStateGate: _FailureGate('TRAIN_C_DIRTY_WORKTREE'),
        reviewedIdentity: reviewed,
        currentHeadReader: () => reviewed.approvedHarnessHead,
        fetchMaster: () {},
        masterReader: () => trainCL1BaseMaster,
        productionDiffReader: () => 0,
      );

      expect(
        gate.verify,
        throwsA(
          predicate<TrainCEvidenceProbeException>(
            (error) => error.code == 'TRAIN_C_DIRTY_WORKTREE',
          ),
        ),
      );
    });
  }

  test('unreadable Git state is blocked with safe identity code', () {
    final reviewed = _reviewedForTest();
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: _FailureGate('TRAIN_C_CODE_IDENTITY_MISMATCH'),
      reviewedIdentity: reviewed,
      currentHeadReader: () => reviewed.approvedHarnessHead,
      fetchMaster: () {},
      masterReader: () => trainCL1BaseMaster,
      productionDiffReader: () => 0,
    );

    expect(
      gate.verify,
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_CODE_IDENTITY_MISMATCH',
        ),
      ),
    );
  });

  test('production lib diff is blocked before any runtime boundary', () {
    final reviewed = _reviewedForTest();
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: const _NoopGate(),
      reviewedIdentity: reviewed,
      currentHeadReader: () => reviewed.approvedHarnessHead,
      fetchMaster: () {},
      masterReader: () => trainCL1BaseMaster,
      productionDiffReader: () => 1,
    );

    expect(
      gate.verify,
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_HEAD_DRIFT',
        ),
      ),
    );
  });

  test('unexpected origin master is blocked', () {
    final reviewed = _reviewedForTest();
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: const _NoopGate(),
      reviewedIdentity: reviewed,
      currentHeadReader: () => reviewed.approvedHarnessHead,
      fetchMaster: () {},
      masterReader: () => '0000000000000000000000000000000000000000',
      productionDiffReader: () => 0,
    );

    expect(
      gate.verify,
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_HEAD_DRIFT',
        ),
      ),
    );
  });
}

TrainCReviewedIdentity _reviewedForTest() {
  return const TrainCReviewedIdentity(
    approvedHarnessHead: 'a000000000000000000000000000000000000000',
    approvedBase: trainCL1BaseMaster,
    approvedProductionBase: trainCL1TrainBMerge,
  );
}
