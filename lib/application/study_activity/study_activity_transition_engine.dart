import '../../domain/study_activity/study_activity_time.dart';
import '../../domain/study_activity/study_activity_values.dart';
import '../home_training_result.dart';
import 'study_activity_contracts.dart';

/// Coherent clock observation. mappingRevision is an ephemeral source marker,
/// not a DB/schema revision: change it on an observed wall/zone discontinuity.
/// A continuous revision reuses the immutable mapping and advances wall time by
/// the confirmed monotonic delta. The source owns detection/sampling policy;
/// this engine has no arbitrary clock-jump threshold or IANA requirement.
final class StudyActivityTimeSample {
  StudyActivityTimeSample({
    required this.monotonicMs,
    required this.utcMs,
    required this.mapping,
    this.mappingRevision = 0,
  }) {
    requireHomeTrainingInput(
        monotonicMs >= 0 && utcMs >= 0 && mappingRevision >= 0);
  }

  final int monotonicMs;
  final int utcMs;
  final StudyActivityLocalTimeMapping mapping;
  final int mappingRevision;
}

abstract interface class StudyActivityTimeSource {
  StudyActivityTimeSample sample();
}

/// One immutable Application owner slot. A terminal state retains session facts
/// but releases its runtime owner and active anchor. No second duration total or
/// segment history is kept here; emitted segment facts own aggregation.
final class StudyActivityRuntimeState {
  const StudyActivityRuntimeState._({
    required this.owner,
    required this.context,
    required this.startedAtUtcMs,
    required this.snapshot,
    required this.lastSample,
    required this.activeAnchor,
    required this.nextSegmentSequence,
  });

  final StudyActivityOwner? owner;
  final StudyActivityContext context;
  final int startedAtUtcMs;
  final StudyActivitySnapshot snapshot;
  final StudyActivityTimeSample lastSample;
  final StudyActivityTimeSample? activeAnchor;
  final int nextSegmentSequence;
}

/// Proposal only: P4b can persist these facts atomically before publishing state.
/// No revision CAS, durable replay, timer, recovery or runtime wiring lives here.
final class StudyActivityTransition {
  StudyActivityTransition(
      this.state, Iterable<StudyActivitySegmentDraft> segments)
      : segments = List.unmodifiable(segments);
  final StudyActivityRuntimeState state;
  final List<StudyActivitySegmentDraft> segments;
  StudyActivitySnapshot get snapshot => state.snapshot;
}

/// Pure transition authority over the sole owner slot supplied by Application.
/// Callers publish only a successful proposal. All rejected transitions leave
/// the input state intact; no mutable singleton or persistence is simulated.
final class StudyActivityTransitionEngine {
  const StudyActivityTransitionEngine({
    required this.timeSource,
    required this.sessionIdFactory,
  });

  final StudyActivityTimeSource timeSource;

  /// Supplies a fresh opaque session identity; durable uniqueness is enforced
  /// by P4b. This engine rejects reuse of the current known terminal identity.
  final String Function() sessionIdFactory;

  HomeTrainingResult<StudyActivityTransition> _safe(
      StudyActivityTransition Function() action) {
    try {
      return HomeTrainingSuccess(action());
    } catch (_) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }

  StudyActivityTimeSample _sample(StudyActivityRuntimeState? old) {
    final sample = timeSource.sample();
    if (old != null) {
      final previous = old.lastSample;
      if (sample.monotonicMs < previous.monotonicMs ||
          (sample.mappingRevision == previous.mappingRevision &&
              (!identical(sample.mapping, previous.mapping) ||
                  sample.utcMs !=
                      previous.utcMs +
                          sample.monotonicMs -
                          previous.monotonicMs))) {
        throw const FormatException('Unavailable StudyActivity clock sample.');
      }
    }
    splitStudyActivityElapsed(
        startUtcMs: sample.utcMs,
        durationMs: 0,
        firstSequence: 1,
        mapping: sample.mapping);
    return sample;
  }

  HomeTrainingResult<StudyActivityTransition> begin(
      StudyActivityRuntimeState? current, StudyActivityBeginRequest request) {
    if (current?.owner != null) {
      return const HomeTrainingFailed(HomeTrainingFailure.conflict);
    }
    if (request.scene == StudyActivityScene.singleQuestionStudy) {
      return const HomeTrainingFailed(HomeTrainingFailure.invalidInput);
    }
    return _safe(() {
      final sample = _sample(null);
      final owner = StudyActivityOwner(
          sessionId: sessionIdFactory(), ownerToken: request.ownerToken);
      if (owner.sessionId == current?.snapshot.sessionId) {
        throw const FormatException(
            'Unavailable StudyActivity session identity.');
      }
      return StudyActivityTransition(
          StudyActivityRuntimeState._(
            owner: owner,
            context: request.context,
            startedAtUtcMs: sample.utcMs,
            snapshot: StudyActivitySnapshot(
              sessionId: owner.sessionId,
              scene: request.scene,
              lifecycle: StudyActivityLifecycle(
                  status: StudyActivityLifecycleStatus.active,
                  endedAtUtcMs: null,
                  endReason: null),
              lastCheckpointAtUtcMs: sample.utcMs,
              checkpointSequence: 0,
              revision: 1,
              recordingQuality: StudyActivityRecordingQuality.recordedOnly,
            ),
            lastSample: sample,
            activeAnchor: sample,
            nextSegmentSequence: 1,
          ),
          const []);
    });
  }

  bool _owns(StudyActivityRuntimeState? state, StudyActivityOwner owner) =>
      state?.owner?.sessionId == owner.sessionId &&
      state?.owner?.ownerToken == owner.ownerToken;

  HomeTrainingResult<StudyActivityTransition> pause(
          StudyActivityRuntimeState? current, StudyActivityOwner owner) =>
      _event(current, owner, StudyActivityLifecycleStatus.paused);

  HomeTrainingResult<StudyActivityTransition> resume(
          StudyActivityRuntimeState? current, StudyActivityOwner owner) =>
      _event(current, owner, StudyActivityLifecycleStatus.active);

  HomeTrainingResult<StudyActivityTransition> checkpoint(
          StudyActivityRuntimeState? current, StudyActivityOwner owner) =>
      _event(current, owner, null);

  HomeTrainingResult<StudyActivityTransition> end(
          StudyActivityRuntimeState? current,
          StudyActivityEndRequest request) =>
      _event(current, request.owner, StudyActivityLifecycleStatus.ended,
          reason: request.reason);

  HomeTrainingResult<StudyActivityTransition> _event(
      StudyActivityRuntimeState? current,
      StudyActivityOwner owner,
      StudyActivityLifecycleStatus? nextStatus,
      {StudyActivityEndReason? reason}) {
    if (!_owns(current, owner)) {
      return const HomeTrainingFailed(HomeTrainingFailure.stale);
    }
    final old = current!;
    final status = old.snapshot.lifecycle.status;
    if (nextStatus == status) {
      // Repeated pause/resume neither confirms a second interval nor consumes
      // another clock sample/sequence. Checkpoint is a distinct explicit event.
      return HomeTrainingSuccess(StudyActivityTransition(old, const []));
    }
    return _safe(() {
      final sample = _sample(old);
      final anchor = old.activeAnchor;
      final segments = anchor == null
          ? <StudyActivitySegmentDraft>[]
          : splitStudyActivityElapsed(
              startUtcMs: anchor.utcMs,
              durationMs: sample.monotonicMs - anchor.monotonicMs,
              firstSequence: old.nextSegmentSequence,
              mapping: anchor.mapping);
      final next = nextStatus ?? status;
      final terminal = next == StudyActivityLifecycleStatus.ended;
      final snapshot = StudyActivitySnapshot(
        sessionId: old.snapshot.sessionId,
        scene: old.snapshot.scene,
        lifecycle: StudyActivityLifecycle(
            status: next,
            endedAtUtcMs: terminal ? sample.utcMs : null,
            endReason: reason),
        // Observed UTC locates this proposal, and may move backwards with wall
        // time. Monotonic duration/segment sequence never does; an end confirms
        // at this same observed instant so the frozen snapshot matrix holds.
        lastCheckpointAtUtcMs: sample.utcMs,
        checkpointSequence: old.snapshot.checkpointSequence + 1,
        revision: old.snapshot.revision + 1,
        recordingQuality: StudyActivityRecordingQuality.recordedOnly,
      );
      return StudyActivityTransition(
          StudyActivityRuntimeState._(
            owner: terminal ? null : old.owner,
            context: old.context,
            startedAtUtcMs: old.startedAtUtcMs,
            snapshot: snapshot,
            lastSample: sample,
            activeAnchor:
                next == StudyActivityLifecycleStatus.active ? sample : null,
            nextSegmentSequence: old.nextSegmentSequence + segments.length,
          ),
          segments);
    });
  }
}
