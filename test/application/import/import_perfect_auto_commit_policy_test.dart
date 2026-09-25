import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import/import_perfect_auto_commit_policy.dart';

void main() {
  const policy = ImportPerfectAutoCommitPolicy();
  ImportPerfectAutoCommitFacts facts({
    bool enabled = true,
    bool document = true,
    bool target = true,
    bool pending = true,
    bool ready = true,
    bool typed = true,
    int count = 1,
    int score = 100,
    int errors = 0,
    int warnings = 0,
    bool blocked = false,
    int revision = 1,
    bool committing = false,
    bool snapshotValid = true,
  }) =>
      ImportPerfectAutoCommitFacts(
        enabled: enabled,
        documentImportEntry: document,
        hasFrozenTarget: target,
        pendingReview: pending,
        readyForReview: ready,
        typedCandidateReady: typed,
        itemCount: count,
        qualityScore: score,
        errorCount: errors,
        warningCount: warnings,
        qualityGateBlocked: blocked,
        reviewDraftRevision: revision,
        commitInProgress: committing,
        typedSnapshotValid: snapshotValid,
      );

  test('only clean typed 100 with a durable revision is eligible', () {
    expect(policy.isEligible(facts()), isTrue);
    expect(policy.isEligible(facts(enabled: false)), isFalse);
    expect(policy.isEligible(facts(document: false)), isFalse);
    expect(policy.isEligible(facts(target: false)), isFalse);
    expect(policy.isEligible(facts(pending: false)), isFalse);
    expect(policy.isEligible(facts(ready: false)), isFalse);
    expect(policy.isEligible(facts(typed: false)), isFalse);
    expect(policy.isEligible(facts(count: 0)), isFalse);
    expect(policy.isEligible(facts(score: 99)), isFalse);
    expect(policy.isEligible(facts(errors: 1)), isFalse);
    expect(policy.isEligible(facts(warnings: 1)), isFalse);
    expect(policy.isEligible(facts(blocked: true)), isFalse);
    expect(policy.isEligible(facts(revision: 0)), isFalse);
    expect(policy.isEligible(facts(committing: true)), isFalse);
    expect(policy.isEligible(facts(snapshotValid: false)), isFalse);
  });
}
