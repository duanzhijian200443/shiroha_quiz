import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../../application/home_training_result.dart';
import '../../application/study_activity/study_activity_contracts.dart';
import '../../domain/study_activity/study_activity_values.dart';

final class StudyActivityRouteDescriptor {
  const StudyActivityRouteDescriptor(
      {required this.scene, required this.context});
  final StudyActivityScene scene;
  final StudyActivityContext context;
}

/// Route orchestration only; Application owns all lifecycle and time facts.
final class StudyActivityRouteBinding with WidgetsBindingObserver {
  StudyActivityRouteBinding({
    required StudyActivityService service,
    required StudyActivityRouteDescriptor descriptor,
    Duration checkpointInterval = const Duration(seconds: 30),
  })  : _service = service,
        _descriptor = descriptor,
        _checkpointInterval = checkpointInterval,
        _foreground = WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed {
    WidgetsBinding.instance.addObserver(this);
  }

  final StudyActivityService _service;
  final StudyActivityRouteDescriptor _descriptor;
  final Duration _checkpointInterval;
  final String _token = const Uuid().v4();
  StudyActivityOwner? _owner;
  Future<void>? _beginning;
  Timer? _timer;
  bool _foreground;
  int _covers = 0;
  bool _paused = false;
  bool _recording = true;
  bool _terminal = false;
  bool _syncing = false;
  bool _checkpointPending = false;

  bool get _eligible => _foreground && _covers == 0;

  Future<void> begin() => _beginning ??= _begin();

  Future<void> _begin() async {
    if (_terminal) return;
    try {
      final result = await _service.begin(StudyActivityBeginRequest(
          scene: _descriptor.scene,
          ownerToken: _token,
          context: _descriptor.context));
      if (result is HomeTrainingSuccess<StudyActivityOwner>) {
        _owner = result.value;
        await _syncEligibility();
      } else {
        _stopRecording();
      }
    } catch (_) {
      _stopRecording();
    }
  }

  void _stopRecording() {
    _recording = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _safeEvent(
      Future<HomeTrainingResult<StudyActivitySnapshot>> Function()
          action) async {
    try {
      if (await action() is HomeTrainingFailed<StudyActivitySnapshot>) {
        _stopRecording();
      }
    } catch (_) {
      _stopRecording();
    }
  }

  Future<void> _syncEligibility() async {
    if (_syncing || _terminal || !_recording || _owner == null) return;
    _syncing = true;
    try {
      while (!_terminal && _recording && _paused == _eligible) {
        _paused = !_eligible;
        _timer?.cancel();
        _timer = null;
        await _safeEvent(
            () => _paused ? _service.pause(_owner!) : _service.resume(_owner!));
      }
      if (!_terminal && _recording && !_paused && _timer == null) {
        _timer = Timer.periodic(_checkpointInterval, (_) {
          if (_checkpointPending || _syncing || !_eligible) return;
          _checkpointPending = true;
          unawaited(_safeEvent(() => _service.checkpoint(_owner!))
              .whenComplete(() => _checkpointPending = false));
        });
      }
    } finally {
      _syncing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_eligible) {
      _timer?.cancel();
      _timer = null;
    }
    unawaited(_syncEligibility());
  }

  Future<T> duringTemporaryCover<T>(Future<T> Function() action) async {
    _covers++;
    _timer?.cancel();
    _timer = null;
    unawaited(_syncEligibility());
    try {
      return await action();
    } finally {
      _covers--;
      unawaited(_syncEligibility());
    }
  }

  /// Mark terminal synchronously, before navigation/dispose can race it.
  void end(StudyActivityEndReason reason) {
    if (_terminal) return;
    _terminal = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_release(reason));
  }

  Future<void> _release(StudyActivityEndReason reason) async {
    // Dispatch an established owner's exit immediately, so a replacement
    // learning route's begin follows it in the Application serialization tail.
    if (_owner == null) await _beginning;
    final owner = _owner;
    if (owner != null) {
      await _safeEvent(() =>
          _service.end(StudyActivityEndRequest(owner: owner, reason: reason)));
      _owner = null;
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    end(StudyActivityEndReason.exited);
  }
}
