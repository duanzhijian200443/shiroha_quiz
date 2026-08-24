import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_evidence_collector.dart';
import '../../tool/train_c_evidence_probe.dart';
import '../../tool/train_c_l1_preflight.dart';
import '../../tool/train_c_review_authorization.dart';

final class _CleanState implements TrainCExecutionStateGate {
  const _CleanState();

  @override
  void verify() {}
}

final class _DirtyState implements TrainCExecutionStateGate {
  const _DirtyState();

  @override
  void verify() {
    throw const TrainCEvidenceProbeException('TRAIN_C_DIRTY_WORKTREE');
  }
}

TrainCReviewedIdentity _reviewed(String head) {
  return TrainCReviewedIdentity(
    approvedHarnessHead: head,
    approvedBase: 'f1d58a278180eff38686338c28f26e4d1d7b8b7a',
    approvedProductionBase: '711fd33f564b9fb6bb3c992d6458b0075990646c',
  );
}

void main() {
  test('out-of-band review authorization requires an explicit HEAD', () {
    expect(
      () => TrainCReviewAuthorization.requireFromEnvironment(
        environment: const <String, String>{},
      ),
      throwsA(
        isA<TrainCEvidenceProbeException>().having(
          (error) => error.code,
          'code',
          'TRAIN_C_CODE_IDENTITY_MISMATCH',
        ),
      ),
    );
  });

  test('out-of-band review authorization carries the reviewed HEAD', () {
    final reviewed = TrainCReviewAuthorization.requireFromEnvironment(
      environment: <String, String>{
        trainCApprovedHarnessHeadEnvironment: 'a' * 40,
      },
    );

    expect(reviewed.approvedHarnessHead, 'a' * 40);
    expect(reviewed.approvedBase, trainCApprovedBase);
    expect(reviewed.approvedProductionBase, trainCApprovedProductionBase);
  });

  test('approved reviewed HEAD passes after a fresh master fetch', () {
    var fetches = 0;
    final reviewed = _reviewed('a' * 40);
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: const _CleanState(),
      reviewedIdentity: reviewed,
      currentHeadReader: () => reviewed.approvedHarnessHead,
      fetchMaster: () => fetches++,
      masterReader: () => reviewed.approvedBase,
      productionDiffReader: () => 0,
    );

    expect(gate.verify, returnsNormally);
    expect(fetches, 1);
  });

  test('wrong current HEAD fails against the frozen review artifact', () {
    final reviewed = _reviewed('a' * 40);
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: const _CleanState(),
      reviewedIdentity: reviewed,
      currentHeadReader: () => 'b' * 40,
      fetchMaster: () {},
      masterReader: () => reviewed.approvedBase,
      productionDiffReader: () => 0,
    );

    expect(
      gate.verify,
      throwsA(
        isA<TrainCEvidenceProbeException>().having(
          (error) => error.code,
          'code',
          'TRAIN_C_HEAD_DRIFT',
        ),
      ),
    );
  });

  test('dirty worktree blocks before a wrong HEAD can authorize execution', () {
    final reviewed = _reviewed('a' * 40);
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: const _DirtyState(),
      reviewedIdentity: reviewed,
      currentHeadReader: () => 'b' * 40,
      fetchMaster: () {},
      masterReader: () => reviewed.approvedBase,
      productionDiffReader: () => 0,
    );

    expect(
      gate.verify,
      throwsA(
        isA<TrainCEvidenceProbeException>().having(
          (error) => error.code,
          'code',
          'TRAIN_C_DIRTY_WORKTREE',
        ),
      ),
    );
  });

  test('fetch failure never falls back to a stale tracking ref', () {
    final reviewed = _reviewed('a' * 40);
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: const _CleanState(),
      reviewedIdentity: reviewed,
      currentHeadReader: () => reviewed.approvedHarnessHead,
      fetchMaster: () {
        throw StateError('remote unavailable');
      },
      masterReader: () => reviewed.approvedBase,
      productionDiffReader: () => 0,
    );

    expect(
      gate.verify,
      throwsA(
        isA<TrainCEvidenceProbeException>().having(
          (error) => error.code,
          'code',
          'TRAIN_C_REMOTE_STATE_UNAVAILABLE',
        ),
      ),
    );
  });

  test('stale origin/master after fetch is rejected', () {
    final reviewed = _reviewed('a' * 40);
    final gate = TrainCPreExecutionGitGate(
      executionStateGate: const _CleanState(),
      reviewedIdentity: reviewed,
      currentHeadReader: () => reviewed.approvedHarnessHead,
      fetchMaster: () {},
      masterReader: () => 'c' * 40,
      productionDiffReader: () => 0,
    );

    expect(
      gate.verify,
      throwsA(
        isA<TrainCEvidenceProbeException>().having(
          (error) => error.code,
          'code',
          'TRAIN_C_HEAD_DRIFT',
        ),
      ),
    );
  });

  test('execution runtime source requires reviewed identity explicitly', () {
    final source = File(
      'tool/train_c_runtime_evidence_source.dart',
    ).readAsStringSync();
    final collector = File(
      'tool/train_c_evidence_collector.dart',
    ).readAsStringSync();

    expect(source, contains('required this.reviewedIdentity'));
    expect(source, contains('sealed class TrainCTrustedEvidenceSource'));
    expect(
      source,
      isNot(contains('this.reviewedIdentity = TrainCReviewedIdentity.l1a')),
    );
    expect(collector, isNot(contains('source as dynamic')));
    expect(collector, isNot(contains('processRestartVerified')));
  });
}
