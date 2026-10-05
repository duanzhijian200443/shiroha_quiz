import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../application/study_plan/study_plan_selection_service.dart';
import '../../application/today/today_context_query.dart';
import '../../application/home_training_result.dart';
import '../../application/training/today_training_contracts.dart';
import '../../application/training/training_contracts.dart';
import '../../application/training/training_configuration_projection.dart';
import '../../application/study_activity/study_activity_contracts.dart';
import '../../domain/training/category_key.dart';
import '../dependencies/home_training_dependencies.dart';

/// Presentation-owned loading/refresh lifecycle for the existing Today UI.
/// Reads are injected from Application seams. Navigation and confirmation
/// remain in the view; candidate selection and mutations remain in services.
final class TodayController extends ChangeNotifier {
  TodayController({
    Future<TodayContextSnapshot> Function()? loadContext,
    required Future<StudyPlanFocusedState> Function() loadFocusedState,
    this.training,
    this.activityQuery,
  })  : _loadContext =
            loadContext ?? (() async => const TodayContextSnapshot()),
        _loadFocusedState = loadFocusedState;

  final Future<TodayContextSnapshot> Function() _loadContext;
  final Future<StudyPlanFocusedState> Function() _loadFocusedState;
  final HomeTrainingDependencies? training;
  final StudyActivityQuery? activityQuery;
  HomeTrainingResult<TodayTrainingSnapshot>? trainingResult;
  HomeTrainingResult<StudyActivityWeekSnapshot>? weekResult;
  TrainingCategorySnapshot? currentCategory;
  bool trainingLoading = true;
  bool weekLoading = true;
  bool selectionBusy = false;
  int _trainingGeneration = 0;
  int _weekGeneration = 0;

  Future<void> loadTraining() async {
    if (_disposed || selectionBusy) return;
    final generation = ++_trainingGeneration;
    trainingLoading = true;
    notifyListeners();
    HomeTrainingResult<TodayTrainingSnapshot> result;
    TrainingCategorySnapshot? category;
    try {
      result = await training!.today.readCurrent();
      if (_disposed || generation != _trainingGeneration) return;
      if (result case HomeTrainingSuccess(:final value)) {
        final key = value.selection.categoryKey;
        if (key != null) {
          final detail = await training!.contentQuery.listByCategory(key);
          if (detail case HomeTrainingSuccess(:final value)) category = value;
        }
      }
    } catch (_) {
      result = const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
    if (_disposed || generation != _trainingGeneration) return;
    trainingResult = result;
    currentCategory = category;
    trainingLoading = false;
    notifyListeners();
  }

  Future<void> loadWeek() async {
    if (_disposed) return;
    final generation = ++_weekGeneration;
    weekLoading = true;
    notifyListeners();
    HomeTrainingResult<StudyActivityWeekSnapshot> result;
    try {
      result = await activityQuery!.readCurrentWeek();
    } catch (_) {
      result = const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
    if (_disposed || generation != _weekGeneration) return;
    weekResult = result;
    weekLoading = false;
    notifyListeners();
  }

  /// Invalidates old reads before the command; no stale command is replayed.
  Future<HomeTrainingFailure?> selectCategory(CategoryKey key) =>
      _select(() async {
        final result = await training!.contentQuery.listByCategory(key);
        return switch (result) {
          HomeTrainingSuccess(:final value) => SelectTrainingContentRequest(
              target: TrainingPreferenceTarget(
                  categoryKey: key,
                  expectedRevision: value.preference.revision),
              contentId: value.preference.currentContentId),
          HomeTrainingFailed(:final failure) =>
            throw HomeTrainingContractException(failure),
        };
      });

  Future<HomeTrainingFailure?> cycleContent() => _select(() async {
        final snapshot =
            (trainingResult as HomeTrainingSuccess<TodayTrainingSnapshot>)
                .value;
        final category = currentCategory!;
        final usable = category.contents.where((c) => c.usable).toList()
          ..sort((a, b) => compareTrainingContents(a.content, b.content));
        if (usable.length <= 1) {
          throw const HomeTrainingContractException(
              HomeTrainingFailure.invalidInput);
        }
        final current = usable.indexWhere((c) =>
            c.content.contentId ==
            snapshot.selection.currentContent?.content.contentId);
        return SelectTrainingContentRequest(
            target: TrainingPreferenceTarget(
                categoryKey: category.categoryKey,
                expectedRevision: snapshot.selection.preference!.revision),
            contentId: usable[(current + 1) % usable.length].content.contentId);
      });

  Future<HomeTrainingFailure?> _select(
      Future<SelectTrainingContentRequest> Function() request) async {
    if (_disposed ||
        selectionBusy ||
        practiceStartPending ||
        training == null) {
      return null;
    }
    selectionBusy = true;
    ++_trainingGeneration;
    notifyListeners();
    HomeTrainingFailure? failure;
    try {
      final target = await request();
      if (_disposed) return null;
      final result = await training!.command.selectCurrent(target);
      if (result case HomeTrainingFailed(:final failure)) {
        return failure;
      }
    } on HomeTrainingContractException catch (error) {
      failure = error.failure;
    } catch (_) {
      failure = HomeTrainingFailure.unavailable;
    } finally {
      selectionBusy = false;
      if (!_disposed) await loadTraining();
    }
    return failure;
  }

  TodayContextSnapshot _context = const TodayContextSnapshot();
  TodayContextSnapshot get contextSnapshot => _context;
  bool _contextLoading = true;
  bool get contextLoading => _contextLoading;
  bool _contextUnavailable = false;
  bool get contextUnavailable => _contextUnavailable;
  int _contextGeneration = 0;
  bool _disposed = false;

  StudyPlanFocusedState? _focusedState;
  StudyPlanFocusedState? get focusedState => _focusedState;
  bool _focusedLoadInFlight = false;
  bool _focusedRefreshPending = false;
  int _focusedLoadGeneration = 0;
  bool _focusedStartPending = false;
  bool get practiceStartPending => _focusedStartPending;

  Future<void> loadContext() async {
    if (_disposed) return;
    final generation = ++_contextGeneration;
    _contextLoading = true;
    _contextUnavailable = false;
    notifyListeners();
    try {
      final snapshot = await _loadContext();
      if (!_disposed && generation == _contextGeneration) {
        _context = snapshot;
      }
    } catch (_) {
      if (!_disposed && generation == _contextGeneration) {
        // Keep the last known snapshot, matching the existing ordinary view.
        // Failure is retained separately; it is never made into a successful 0.
        _contextUnavailable = true;
      }
    } finally {
      if (!_disposed && generation == _contextGeneration) {
        _contextLoading = false;
        notifyListeners();
      }
    }
  }

  /// Serial reads, queued refresh and latest-wins publication preserve the
  /// existing focused refresh coordinator, independent of frame production.
  Future<void> loadFocusedState() async {
    if (_disposed) return;
    if (_focusedLoadInFlight) {
      _focusedRefreshPending = true;
      _focusedLoadGeneration++;
      return;
    }
    _focusedLoadInFlight = true;
    final generation = ++_focusedLoadGeneration;
    try {
      final state = await _loadFocusedState();
      if (!_disposed && generation == _focusedLoadGeneration) {
        publishFocusedState(state);
      }
    } catch (_) {
      if (!_disposed && generation == _focusedLoadGeneration) {
        publishFocusedState(const StudyPlanFocusedFailure(
          StudyPlanFocusedFailureKind.internalError,
        ));
      }
    } finally {
      _focusedLoadInFlight = false;
      if (_focusedRefreshPending) {
        _focusedRefreshPending = false;
        scheduleMicrotask(() {
          if (!_disposed) loadFocusedState();
        });
      }
    }
  }

  void publishFocusedState(StudyPlanFocusedState state) {
    if (_disposed) return;
    _focusedState = state;
    notifyListeners();
  }

  /// The guard spans preparation AND the opened Practice route, exactly as
  /// before extraction. A pending second click must never open another route.
  Future<void> runFocusedStart(Future<void> Function() action) async {
    if (_disposed || _focusedStartPending) return;
    _focusedStartPending = true;
    notifyListeners();
    try {
      await action();
    } finally {
      _focusedStartPending = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
