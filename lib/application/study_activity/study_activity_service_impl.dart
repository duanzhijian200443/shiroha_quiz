import 'dart:async';

import '../../domain/study_activity/study_activity_time.dart';
import '../home_training_result.dart';
import 'study_activity_contracts.dart';
import 'study_activity_persistence.dart';
import 'study_activity_transition_engine.dart';

/// Startup-only admission; composition calls it before the first begin. Query
/// never repairs sessions, and recovery never restores a runtime owner.
abstract interface class StudyActivityStartupRecovery {
  Future<HomeTrainingResult<int>> recoverAtStartup();
}

/// Serial P4a proposal -> durable port -> publish. No scheduling or route wiring.
/// A recording failure stops that session's attribution, rather than recomputing
/// a longer unknown interval. Exit can still release the process-local owner;
/// any durable residue is closed by future startup recovery at its last checkpoint.
final class PersistentStudyActivityService
    implements
        StudyActivityService,
        StudyActivityQuery,
        StudyActivityStartupRecovery {
  PersistentStudyActivityService(
      {required StudyActivityTransitionEngine engine,
      required StudyActivityPersistence persistence,
      required String Function() currentLocalDate})
      : _engine = engine,
        _persistence = persistence,
        _currentLocalDate = currentLocalDate;
  final StudyActivityTransitionEngine _engine;
  final StudyActivityPersistence _persistence;
  final String Function() _currentLocalDate;
  Future<void> _tail = Future.value();
  StudyActivityRuntimeState? _state;
  bool _startupReady = false;
  bool _stopped = false;
  bool _partial = false;

  Future<HomeTrainingResult<T>> _serial<T>(
      Future<HomeTrainingResult<T>> Function() action) {
    final done = Completer<HomeTrainingResult<T>>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await action());
      } catch (_) {
        _partial = true;
        _stopped = _state?.owner != null;
        done.complete(
            const HomeTrainingFailed(HomeTrainingFailure.unavailable));
      }
    });
    return done.future;
  }

  bool _owns(StudyActivityOwner owner) =>
      _state?.owner?.sessionId == owner.sessionId &&
      _state?.owner?.ownerToken == owner.ownerToken;
  HomeTrainingResult<T> _failure<T>(HomeTrainingFailure code) =>
      HomeTrainingFailed(code);

  // Capture the event instant before waiting for another durable proposal.
  // State admission/preparation still happens strictly inside serialization.
  StudyActivityTransitionEngine? _observe() {
    try {
      return StudyActivityTransitionEngine(
          timeSource: _ObservedActivityTime(_engine.timeSource.sample()),
          sessionIdFactory: _engine.sessionIdFactory);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<HomeTrainingResult<int>> recoverAtStartup() => _serial(() async {
        if (_state?.owner != null) {
          return _failure(HomeTrainingFailure.conflict);
        }
        if (_startupReady) return const HomeTrainingSuccess(0);
        final result = await _persistence.recoverInterruptedSessions();
        if (result is HomeTrainingSuccess<int>) {
          _startupReady = true;
        } else {
          _partial = true;
        }
        return result;
      });

  @override
  Future<HomeTrainingResult<StudyActivityOwner>> begin(
      StudyActivityBeginRequest request) {
    final observed = _startupReady ? _observe() : null;
    return _serial(() async {
      if (!_startupReady) return _failure(HomeTrainingFailure.unavailable);
      if (_state?.owner != null) {
        return _failure(HomeTrainingFailure.conflict);
      }
      if (observed == null) return _failure(HomeTrainingFailure.unavailable);
      final result = observed.begin(_state, request);
      if (result is HomeTrainingFailed<StudyActivityTransition>) {
        return _failure(result.failure);
      }
      final proposal =
          (result as HomeTrainingSuccess<StudyActivityTransition>).value;
      final written = await _persistence.createSession(proposal);
      if (written is HomeTrainingFailed<StudyActivitySnapshot>) {
        _partial = true;
        return _failure(written.failure);
      }
      _state = proposal.state;
      _stopped = false;
      return HomeTrainingSuccess(proposal.state.owner!);
    });
  }

  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> pause(
          StudyActivityOwner owner) =>
      _event(owner, (engine) => engine.pause(_state, owner));
  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> resume(
          StudyActivityOwner owner) =>
      _event(owner, (engine) => engine.resume(_state, owner));
  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> checkpoint(
          StudyActivityOwner owner) =>
      _event(owner, (engine) => engine.checkpoint(_state, owner));
  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> end(
          StudyActivityEndRequest request) =>
      _event(request.owner, (engine) => engine.end(_state, request),
          release: true);

  Future<HomeTrainingResult<StudyActivitySnapshot>> _event(
      StudyActivityOwner owner,
      HomeTrainingResult<StudyActivityTransition> Function(
              StudyActivityTransitionEngine)
          prepare,
      {bool release = false}) {
    if (!_owns(owner)) {
      return _serial(() async => _failure(HomeTrainingFailure.stale));
    }
    final observed = _stopped ? null : _observe();
    return _serial(() async {
      if (!_owns(owner)) return _failure(HomeTrainingFailure.stale);
      if (_stopped) {
        if (release) _state = null;
        return _failure(HomeTrainingFailure.unavailable);
      }
      if (observed == null) {
        _partial = true;
        _stopped = true;
        if (release) _state = null;
        return _failure(HomeTrainingFailure.unavailable);
      }
      final prepared = prepare(observed);
      if (prepared is HomeTrainingFailed<StudyActivityTransition>) {
        _partial = true;
        _stopped = true;
        if (release) _state = null;
        return _failure(prepared.failure);
      }
      final proposal =
          (prepared as HomeTrainingSuccess<StudyActivityTransition>).value;
      if (!identical(proposal.state, _state)) {
        HomeTrainingResult<StudyActivitySnapshot> written;
        try {
          written = await _persistence.commitTransition(_state!, proposal);
        } catch (_) {
          written = const HomeTrainingFailed(HomeTrainingFailure.unavailable);
        }
        if (written is HomeTrainingFailed<StudyActivitySnapshot>) {
          _partial = true;
          _stopped = true;
          if (release) _state = null;
          return _failure(written.failure);
        }
        _state = proposal.state;
      }
      final snapshot = proposal.snapshot;
      return HomeTrainingSuccess(StudyActivitySnapshot(
          sessionId: snapshot.sessionId,
          scene: snapshot.scene,
          lifecycle: snapshot.lifecycle,
          lastCheckpointAtUtcMs: snapshot.lastCheckpointAtUtcMs,
          checkpointSequence: snapshot.checkpointSequence,
          revision: snapshot.revision,
          recordingQuality: _partial
              ? StudyActivityRecordingQuality.partial
              : StudyActivityRecordingQuality.recordedOnly));
    });
  }

  @override
  Future<HomeTrainingResult<StudyActivityWeekSnapshot>>
      readCurrentWeek() async {
    try {
      final local = _currentLocalDate();
      if (!isStudyActivityLocalDate(local)) {
        return _failure(HomeTrainingFailure.unavailable);
      }
      final day = DateTime.parse('${local}T00:00:00Z');
      final monday =
          DateTime.utc(day.year, day.month, day.day - day.weekday + 1)
              .toIso8601String()
              .substring(0, 10);
      final result = await _persistence.readWeek(monday);
      if (result is HomeTrainingFailed<StudyActivityWeekSnapshot>) {
        return result;
      }
      final week =
          (result as HomeTrainingSuccess<StudyActivityWeekSnapshot>).value;
      return HomeTrainingSuccess(StudyActivityWeekSnapshot(
          mondayLocalDate: week.mondayLocalDate,
          days: week.days,
          recordingQuality: _partial
              ? StudyActivityRecordingQuality.partial
              : week.recordingQuality));
    } catch (_) {
      return _failure(HomeTrainingFailure.unavailable);
    }
  }
}

final class _ObservedActivityTime implements StudyActivityTimeSource {
  const _ObservedActivityTime(this.observation);
  final StudyActivityTimeSample observation;
  @override
  StudyActivityTimeSample sample() => observation;
}
