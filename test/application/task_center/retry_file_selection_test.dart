import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/task_center/retry_file_selection.dart';

final class _OpaqueSelection implements RetrySourceSelection {}

final class _PickerFake implements RetryFileSelectionHost {
  _PickerFake(this.result);
  final RetryFileSelectionResult result;
  @override
  Future<RetryFileSelectionResult> select(
          RetryFileSelectionRequest request) async =>
      result;
}

final class _RetryAdapterFake implements TaskCenterSelectedSourceRetry {
  int calls = 0;
  RetryFileSelectionSelected? input;
  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> retryWithSelectedSource(
      RetryFileSelectionSelected selected) async {
    calls++;
    input = selected;
    return const HomeTrainingFailed(HomeTrainingFailure.stale);
  }
}

TaskCenterTaskTarget _target(
        {String? token = 'attempt-2',
        int? number = 2,
        String? trace = 'trace-2',
        int? revision = 0}) =>
    TaskCenterTaskTarget(
        taskId: 'task-a',
        expectedAttemptNumber: number,
        expectedAttemptToken: token,
        expectedTraceId: trace,
        expectedReviewRevision: revision);

void main() {
  test(
      'request contains only the captured task target, preserving authoritative absence',
      () {
    final legacy =
        _target(token: null, number: null, trace: null, revision: null);
    final request = RetryFileSelectionRequest(legacy);
    expect(request.target.expectedAttemptToken, isNull);
    expect(request.target.expectedAttemptNumber, isNull);
    expect(request.target.expectedTraceId, isNull);
    expect(request.target.expectedReviewRevision, isNull);
    expect(_target().expectedReviewRevision, 0);
    expect(() => _target(number: 0),
        throwsA(isA<HomeTrainingContractException>()));
    expect(() => _target(token: r'C:\private\source.pdf'),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test(
      'cancelled picker result provides no selection and causes no adapter call',
      () async {
    final request = RetryFileSelectionRequest(_target());
    final host = _PickerFake(const RetryFileSelectionCancelled());
    final adapter = _RetryAdapterFake();
    final result = await host.select(request);
    // Example host routing: adapter's typed input cannot accept Cancelled.
    if (result is RetryFileSelectionSelected) {
      await adapter.retryWithSelectedSource(result);
    }
    expect(result, isA<RetryFileSelectionCancelled>());
    expect(adapter.calls, 0);
  });

  test(
      'selected handle is ephemeral and retains the pre-picker attempt for stale rejection',
      () async {
    final target = _target();
    final request = RetryFileSelectionRequest(target);
    final selection = _OpaqueSelection();
    final adapter = _RetryAdapterFake();
    final host = _PickerFake(
        RetryFileSelectionSelected(request: request, selection: selection));
    final result = await host.select(request) as RetryFileSelectionSelected;
    final retried = await adapter.retryWithSelectedSource(result);
    expect(adapter.calls, 1);
    expect(adapter.input!.request.target, same(target));
    expect(adapter.input!.selection, same(selection));
    expect((retried as HomeTrainingFailed<HomeTrainingUnit>).failure,
        HomeTrainingFailure.stale);
  });
}
