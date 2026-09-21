import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import/import_advanced_preferences.dart';
import 'package:shiroha_quiz/application/import/import_completion_navigation_policy.dart';

void main() {
  const policy = ImportCompletionNavigationPolicy();

  test('notifyOnly never opens a review route', () {
    expect(
      policy.shouldOpenReview(
        behavior: ImportCompletionBehavior.notifyOnly,
        singleUserTask: true,
        pendingReview: true,
        foreground: true,
        navigationFree: true,
      ),
      isFalse,
    );
  });

  test('openReview admits one foreground task with a free navigator', () {
    expect(
      policy.shouldOpenReview(
        behavior: ImportCompletionBehavior.openReview,
        singleUserTask: true,
        pendingReview: true,
        foreground: true,
        navigationFree: true,
      ),
      isTrue,
    );
  });

  test('batch, background and active navigation cannot push review', () {
    for (final state in <(bool, bool, bool, bool)>[
      (false, true, true, true),
      (true, false, true, true),
      (true, true, false, true),
      (true, true, true, false),
    ]) {
      expect(
        policy.shouldOpenReview(
          behavior: ImportCompletionBehavior.openReview,
          singleUserTask: state.$1,
          pendingReview: state.$2,
          foreground: state.$3,
          navigationFree: state.$4,
        ),
        isFalse,
      );
    }
  });
}
