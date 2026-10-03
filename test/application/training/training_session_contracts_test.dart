import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/application/training/training_session_contracts.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';

final class _SessionFake implements TrainingSessionApplicationService {
  _SessionFake(this.result);
  final TrainingSessionLaunchResult result;
  TrainingContentTarget? newTarget;
  CategoryKey? reviewCategory;
  @override
  Future<TrainingSessionLaunchResult> startNew(
      TrainingContentTarget target) async {
    newTarget = target;
    return result;
  }

  @override
  Future<TrainingSessionLaunchResult> startCategoryReview(
      CategoryKey categoryKey) async {
    reviewCategory = categoryKey;
    return result;
  }
}

String _kind(TrainingSessionLaunchResult result) => switch (result) {
      TrainingSessionReady() => 'ready',
      TrainingSessionEmpty() => 'empty',
      TrainingSessionStaleConfiguration() => 'staleConfiguration',
      TrainingSessionUnavailable() => 'unavailable',
    };

void main() {
  test('sealed launch results distinguish ready, empty, stale and unavailable',
      () async {
    final results = [
      TrainingSessionReady(20),
      const TrainingSessionEmpty(),
      const TrainingSessionStaleConfiguration(),
      const TrainingSessionUnavailable()
    ];
    expect(results.map(_kind),
        ['ready', 'empty', 'staleConfiguration', 'unavailable']);
    for (final result in results) {
      final fake = _SessionFake(result);
      final target =
          TrainingContentTarget(contentId: 'content-a', expectedRevision: 4);
      expect(await fake.startNew(target), same(result));
      expect(fake.newTarget!.expectedRevision, 4);
      const category = UncategorizedCategoryKey();
      expect(await fake.startCategoryReview(category), same(result));
      expect(fake.reviewCategory, category);
    }
  });

  test('ready has a bounded nonempty count and never carries question content',
      () {
    expect(TrainingSessionReady(1).questionCount, 1);
    expect(TrainingSessionReady(100).questionCount, 100);
    for (final count in [0, 101]) {
      expect(() => TrainingSessionReady(count),
          throwsA(isA<HomeTrainingContractException>()));
    }
  });
}
