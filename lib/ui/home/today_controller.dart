import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../application/study_plan/study_plan_selection_service.dart';
import '../../application/today/today_context_query.dart';

/// Presentation-owned loading/refresh lifecycle for the existing Today UI.
/// Reads are injected from Application seams. Navigation and confirmation
/// remain in the view; candidate selection and mutations remain in services.
final class TodayController extends ChangeNotifier {
  TodayController({
    required Future<TodayContextSnapshot> Function() loadContext,
    required Future<StudyPlanFocusedState> Function() loadFocusedState,
  })  : _loadContext = loadContext,
        _loadFocusedState = loadFocusedState;

  final Future<TodayContextSnapshot> Function() _loadContext;
  final Future<StudyPlanFocusedState> Function() _loadFocusedState;

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
    try {
      await action();
    } finally {
      _focusedStartPending = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
