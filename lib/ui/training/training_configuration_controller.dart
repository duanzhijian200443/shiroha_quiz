import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../application/home_training_result.dart';
import '../../application/training/training_configuration_contracts.dart';
import '../../application/training/training_contracts.dart';
import '../../domain/training/training_content.dart';
import 'training_content_draft.dart';

enum TrainingConfigurationLoad { loading, loaded, unavailable }

final class TrainingSaveOutcome {
  const TrainingSaveOutcome(
      {this.content, this.failure, this.visualSaved = true});
  final TrainingContent? content;
  final HomeTrainingFailure? failure;
  final bool visualSaved;
}

/// Presentation state only; all configuration admission and CAS live in ports.
final class TrainingConfigurationController extends ChangeNotifier {
  TrainingConfigurationController({
    required this.query,
    required this.command,
    required this.orderCommand,
  });

  final TrainingConfigurationQuery query;
  final TrainingContentCommand command;
  final TrainingContentOrderCommand orderCommand;
  TrainingConfigurationSnapshot? snapshot;
  TrainingConfigurationLoad state = TrainingConfigurationLoad.loading;
  bool busy = false;
  String? message;
  int _generation = 0;
  bool _disposed = false;
  Timer? _messageDismissal;

  void _showMessage(String? value, {bool transient = false}) {
    _messageDismissal?.cancel();
    message = value;
    if (transient) {
      _messageDismissal = Timer(const Duration(seconds: 2), () {
        if (_disposed) return;
        message = null;
        _publish();
      });
    }
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (_disposed) return;
    final generation = ++_generation;
    state = TrainingConfigurationLoad.loading;
    _publish();
    HomeTrainingResult<TrainingConfigurationSnapshot> result;
    try {
      result = await query.readConfiguration();
    } catch (_) {
      result = const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
    if (_disposed || generation != _generation) return;
    switch (result) {
      case HomeTrainingSuccess(:final value):
        snapshot = value;
        state = TrainingConfigurationLoad.loaded;
      case HomeTrainingFailed():
        snapshot = null;
        state = TrainingConfigurationLoad.unavailable;
    }
    _publish();
  }

  bool _begin() {
    if (_disposed || busy) return false;
    busy = true;
    ++_generation; // No pre-mutation read may publish over the result.
    _showMessage(null);
    _publish();
    return true;
  }

  Future<HomeTrainingResult<T>> _call<T>(
      Future<HomeTrainingResult<T>> Function() action) async {
    try {
      return await action();
    } catch (_) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }

  Future<void> _finish() async {
    if (_disposed) return;
    await load();
    busy = false;
    _publish();
  }

  Future<TrainingSaveOutcome> save(TrainingContentDraft draft) async {
    // Freeze fields before the first await; later draft edits cannot join a save.
    final original = draft.original;
    final visual = draft.visualKey;
    final contentChanged = draft.contentChanged;
    final visualChanged = draft.visualChanged;
    final visualUpdate = visualChanged && visual != null;
    final preference = draft.preference;
    if (!contentChanged && !visualUpdate) {
      // An unchanged draft consumes no CAS pair and rewrites no revision.
      return TrainingSaveOutcome(content: original);
    }
    if (!_begin()) {
      return const TrainingSaveOutcome(failure: HomeTrainingFailure.conflict);
    }
    if (!contentChanged) {
      // Visual-only edit: a pure Category preference CAS, independent of the
      // persisted content revision and of content usability.
      final saved = await _call(() => command.updateCategoryVisual(
          UpdateCategoryVisualRequest(
              target: preferenceTarget(preference), visualKey: visual!)));
      switch (saved) {
        case HomeTrainingSuccess():
          _showMessage('分类视觉已保存', transient: true);
          await _finish();
          return TrainingSaveOutcome(content: original);
        case HomeTrainingFailed(:final failure):
          _showMessage(failureMessage(failure));
          await _finish();
          return TrainingSaveOutcome(failure: failure, visualSaved: false);
      }
    }
    final result = await _call(() => original == null
        ? command.create(CreateTrainingContentRequest(
            categoryKey: draft.categoryKey, edit: draft.edit))
        : command.update(UpdateTrainingContentRequest(
            target: target(original), edit: draft.edit)));
    switch (result) {
      case HomeTrainingFailed(:final failure):
        _showMessage(failureMessage(failure));
        await _finish();
        return TrainingSaveOutcome(failure: failure);
      case HomeTrainingSuccess(:final value):
        var visualSaved = !visualChanged;
        HomeTrainingFailure? visualFailure;
        if (visualUpdate && !_disposed) {
          final saved = await _call(() => command.updateCategoryVisual(
              UpdateCategoryVisualRequest(
                  target: preferenceTarget(preference), visualKey: visual)));
          switch (saved) {
            case HomeTrainingSuccess():
              visualSaved = true;
            case HomeTrainingFailed(:final failure):
              visualFailure = failure;
          }
        }
        _showMessage(visualSaved ? '训练内容已保存' : '训练内容已保存，分类视觉未保存，请重新检查分类视觉。',
            transient: visualSaved);
        await _finish();
        return TrainingSaveOutcome(
            content: value, failure: visualFailure, visualSaved: visualSaved);
    }
  }

  Future<HomeTrainingResult<T>> _mutate<T>(
      Future<HomeTrainingResult<T>> Function() action, String success) async {
    if (!_begin()) {
      return const HomeTrainingFailed(HomeTrainingFailure.conflict);
    }
    final result = await _call(action);
    _showMessage(switch (result) {
      HomeTrainingSuccess() => success,
      HomeTrainingFailed(:final failure) => failureMessage(failure),
    });
    await _finish();
    return result;
  }

  Future<HomeTrainingResult<TrainingContent>> rebind(
          TrainingContent content, String bankName) =>
      _mutate(
          () => command.rebindMember(RebindTrainingContentMemberRequest(
              target: target(content), bankName: bankName)),
          '已重新绑定题库');

  Future<HomeTrainingResult<HomeTrainingUnit>> delete(
          TrainingContent content) =>
      _mutate(() => command.delete(target(content)), '已删除训练配置，学习记录保留');

  Future<HomeTrainingResult<TrainingCurrentSelection>> select(
          TrainingCategorySnapshot category, String contentId) =>
      _mutate(
          () => command.selectCurrent(SelectTrainingContentRequest(
              target: preferenceTarget(category.preference),
              contentId: contentId)),
          '已设为当前训练内容');

  Future<HomeTrainingResult<HomeTrainingUnit>> move(
          TrainingCategorySnapshot category,
          String contentId,
          TrainingContentMove direction) =>
      _mutate(
          () => orderCommand.moveContent(MoveTrainingContentRequest(
              categoryKey: category.categoryKey,
              orderedTargets:
                  category.contents.map((view) => target(view.content)),
              contentId: contentId,
              direction: direction)),
          '顺序已更新');

  static TrainingContentTarget target(TrainingContent content) =>
      TrainingContentTarget(
          contentId: content.contentId, expectedRevision: content.revision);

  static TrainingPreferenceTarget preferenceTarget(
          TrainingCategoryPreference preference) =>
      TrainingPreferenceTarget(
          categoryKey: preference.categoryKey,
          expectedRevision: preference.revision);

  static String failureMessage(HomeTrainingFailure failure) =>
      switch (failure) {
        HomeTrainingFailure.stale ||
        HomeTrainingFailure.notFound =>
          '配置已变化，已重新读取，请检查后再操作。',
        HomeTrainingFailure.invalidInput => '请检查名称、题库和比例；失效题库需移除或显式重新绑定。',
        _ => '暂时无法保存配置，请重新检查后再操作。',
      };

  @override
  void dispose() {
    _disposed = true;
    _messageDismissal?.cancel();
    ++_generation;
    super.dispose();
  }
}
