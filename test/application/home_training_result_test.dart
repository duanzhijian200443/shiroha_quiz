import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';

void main() {
  test('safe failures remain distinct and have no raw cause/message input', () {
    expect(HomeTrainingFailure.values.toSet(), {
      HomeTrainingFailure.notFound,
      HomeTrainingFailure.unavailable,
      HomeTrainingFailure.stale,
      HomeTrainingFailure.invalidInput,
      HomeTrainingFailure.conflict,
    });
    for (final failure in HomeTrainingFailure.values) {
      final result = HomeTrainingFailed<int>(failure);
      expect(result.failure, failure);
      expect(HomeTrainingContractException(failure).toString(),
          'HomeTrainingContractException(${failure.name})');
    }
  });

  test('success, including real zero, is separate from failure', () {
    const HomeTrainingResult<int> zero = HomeTrainingSuccess(0);
    const HomeTrainingResult<int> unavailable =
        HomeTrainingFailed(HomeTrainingFailure.unavailable);
    expect(zero, isA<HomeTrainingSuccess<int>>());
    expect((zero as HomeTrainingSuccess<int>).value, 0);
    expect(unavailable, isA<HomeTrainingFailed<int>>());
    expect(const HomeTrainingSuccess(HomeTrainingUnit()).value,
        isA<HomeTrainingUnit>());
    expect(
        () => requireHomeTrainingInput(false),
        throwsA(isA<HomeTrainingContractException>().having(
            (error) => error.failure,
            'code',
            HomeTrainingFailure.invalidInput)));
  });
}
