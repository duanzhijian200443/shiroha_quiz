import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../application/home_training_result.dart';
import '../../application/task_center/task_center_contracts.dart';
import '../../application/task_center/retry_file_selection.dart';
import '../dependencies/task_center_dependencies.dart';

enum TaskCenterLoadPhase { initial, loading, loaded, refreshing, unavailable }

enum TaskCenterAction { cancel, retry, delete, review }

/// Presentation lifecycle only: business eligibility and exact-target admission
/// stay in Application. Automatic reads are bounded and serialized with refresh.
final class TaskCenterController extends ChangeNotifier {
  TaskCenterController(this.dependencies,
      {this.refreshInterval = const Duration(seconds: 3),
      bool Function()? routeVisible})
      : _routeVisible = routeVisible ?? (() => true);
  final TaskCenterDependencies dependencies;
  final Duration refreshInterval;
  final bool Function() _routeVisible;
  TaskCenterSnapshot? snapshot;
  TaskCenterLoadPhase phase = TaskCenterLoadPhase.initial;
  TaskCenterCoarseStatus selected = TaskCenterCoarseStatus.inProgress;
  final Set<String> pendingTaskIds = {};
  bool cleanupBusy = false;
  String? message;
  int messageRevision = 0;
  bool _disposed = false;
  bool _visible = false;
  bool _reading = false;
  bool _readAgain = false;
  int _generation = 0;
  Future<void>? _readFuture;
  Timer? _timer;

  void setVisible(bool visible) {
    if (_disposed) return;
    _visible = visible;
    _timer?.cancel();
    if (visible && refreshInterval > Duration.zero) {
      _timer = Timer.periodic(refreshInterval, (_) {
        if (!_disposed && _visible && _routeVisible() && !_reading) {
          unawaited(load());
        }
      });
    }
  }

  void selectTab(TaskCenterCoarseStatus value) {
    if (_disposed) return;
    selected = value;
    notifyListeners();
  }

  List<TaskCenterItem> get items =>
      snapshot?.items.where((i) => i.coarseStatus == selected).toList() ?? [];
  int count(TaskCenterCoarseStatus status) =>
      snapshot?.items.where((i) => i.coarseStatus == status).length ?? 0;

  Future<void> load() {
    if (_disposed) return Future.value();
    ++_generation;
    if (_reading) {
      _readAgain = true;
      return _readFuture!;
    }
    _reading = true;
    final complete = Completer<void>();
    _readFuture = complete.future;
    unawaited(_drain().whenComplete(() {
      _reading = false;
      complete.complete();
    }));
    return complete.future;
  }

  Future<void> _drain() async {
    do {
      _readAgain = false;
      final generation = _generation;
      phase = snapshot == null
          ? TaskCenterLoadPhase.loading
          : TaskCenterLoadPhase.refreshing;
      notifyListeners();
      HomeTrainingResult<TaskCenterSnapshot> result;
      try {
        result = await dependencies.query.read();
      } catch (_) {
        result = const HomeTrainingFailed(HomeTrainingFailure.unavailable);
      }
      if (_disposed) return;
      if (generation == _generation) {
        switch (result) {
          case HomeTrainingSuccess(:final value):
            snapshot = value;
            phase = TaskCenterLoadPhase.loaded;
          case HomeTrainingFailed():
            phase = TaskCenterLoadPhase.unavailable;
        }
        notifyListeners();
      }
    } while (!_disposed && _readAgain);
  }

  String _failure(HomeTrainingFailure failure) => switch (failure) {
        HomeTrainingFailure.stale ||
        HomeTrainingFailure.notFound =>
          '任务状态已变化，请刷新',
        HomeTrainingFailure.conflict => '当前状态无法执行此操作',
        _ => '操作暂不可用',
      };
  void _announce(String text) {
    if (_disposed) return;
    message = text;
    ++messageRevision;
    notifyListeners();
  }

  Future<void> act(TaskCenterItem item, TaskCenterAction action,
      {Future<HomeTrainingResult<HomeTrainingUnit>> Function(
              TaskCenterReviewNavigationRequest)?
          present}) async {
    if (_disposed || cleanupBusy || !pendingTaskIds.add(item.target.taskId)) {
      return;
    }
    notifyListeners();
    try {
      HomeTrainingResult<HomeTrainingUnit>? result;
      switch (action) {
        case TaskCenterAction.cancel:
          result = await dependencies.command.cancel(item.target);
        case TaskCenterAction.delete:
          result = await dependencies.command.delete(item.target);
        case TaskCenterAction.retry:
          final retry = await dependencies.command.retry(item.target);
          if (_disposed) return;
          switch (retry) {
            case TaskCenterRetryAccepted():
              result = const HomeTrainingSuccess(HomeTrainingUnit());
            case TaskCenterRetryFailed(:final failure):
              result = HomeTrainingFailed(failure);
            case TaskCenterRetryNeedsFileSelection(:final request):
              final picked = await dependencies.fileSelection.select(request);
              if (_disposed) return;
              if (picked is RetryFileSelectionSelected) {
                result = await dependencies.selectedSourceRetry
                    .retryWithSelectedSource(picked);
              }
          }
        case TaskCenterAction.review:
          final request = await dependencies.command.requestReview(item.target);
          if (_disposed) return;
          result = switch (request) {
            HomeTrainingSuccess(:final value) => present == null
                ? const HomeTrainingFailed(HomeTrainingFailure.unavailable)
                : await present(value),
            HomeTrainingFailed(:final failure) => HomeTrainingFailed(failure),
          };
      }
      if (!_disposed && result is HomeTrainingFailed<HomeTrainingUnit>) {
        _announce(_failure(result.failure));
      }
    } catch (_) {
      _announce('操作暂不可用');
    } finally {
      pendingTaskIds.remove(item.target.taskId);
      if (!_disposed) {
        notifyListeners();
        await load();
      }
    }
  }

  Future<void> cleanup(Future<bool> Function(int) confirm) async {
    if (_disposed || cleanupBusy) return;
    cleanupBusy = true;
    notifyListeners();
    try {
      final result = await dependencies.query.snapshotCompletedForCleanup();
      if (_disposed) return;
      if (result case HomeTrainingFailed(:final failure)) {
        _announce(_failure(failure));
        return;
      }
      final captured =
          (result as HomeTrainingSuccess<TaskCenterCompletedSnapshot>).value;
      if (captured.targets.isEmpty) {
        _announce('没有可清理的已完成记录');
        return;
      }
      if (!await confirm(captured.targets.length) || _disposed) return;
      final cleared = await dependencies.command.clearCompleted(captured);
      switch (cleared) {
        case HomeTrainingSuccess(:final value):
          _announce('已清理 ${value.deletedCount} 条，保留 ${value.retainedCount} 条');
        case HomeTrainingFailed(:final failure):
          _announce(_failure(failure));
      }
    } catch (_) {
      _announce('操作暂不可用');
    } finally {
      cleanupBusy = false;
      if (!_disposed) {
        notifyListeners();
        await load();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    super.dispose();
  }
}
