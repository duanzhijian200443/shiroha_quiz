import '../../domain/study_activity/study_activity_values.dart';
import '../../domain/training/category_key.dart';
import '../home_training_result.dart';

/// Soft historical context only. No Question/queue payload or live FK ownership.
final class StudyActivityContext {
  const StudyActivityContext(
      {this.categoryKey,
      this.contentId,
      this.bankName,
      this.planId,
      this.paperId});
  final CategoryKey? categoryKey;
  final String? contentId;
  final String? bankName;
  final String? planId;
  final String? paperId;
}

final class StudyActivityBeginRequest {
  StudyActivityBeginRequest(
      {required this.scene, required this.ownerToken, required this.context}) {
    requireHomeTrainingInput(ownerToken.trim().isNotEmpty &&
        scene != StudyActivityScene.singleQuestionStudy);
  }
  final StudyActivityScene scene;

  /// Transient route-owner identity, not a widget/platform object.
  final String ownerToken;
  final StudyActivityContext context;
}

/// Session identity alone cannot resume an owner after process death/restore.
/// Future services must validate the full current runtime owner handle.
final class StudyActivityOwner {
  StudyActivityOwner({required this.sessionId, required this.ownerToken}) {
    requireHomeTrainingInput(
        sessionId.trim().isNotEmpty && ownerToken.trim().isNotEmpty);
  }
  final String sessionId;
  final String ownerToken;
}

enum StudyActivityRecordingQuality { recordedOnly, partial }

final class StudyActivitySnapshot {
  StudyActivitySnapshot({
    required this.sessionId,
    required this.scene,
    required this.lifecycle,
    required this.lastCheckpointAtUtcMs,
    required this.checkpointSequence,
    required this.revision,
    required this.recordingQuality,
  }) {
    requireHomeTrainingInput(sessionId.trim().isNotEmpty &&
        lastCheckpointAtUtcMs >= 0 &&
        checkpointSequence >= 0 &&
        revision > 0);
    requireHomeTrainingInput(lifecycle.endedAtUtcMs == null ||
        lifecycle.endedAtUtcMs! >= lastCheckpointAtUtcMs);
  }
  final String sessionId;
  final StudyActivityScene scene;
  final StudyActivityLifecycle lifecycle;
  final int lastCheckpointAtUtcMs;
  final int checkpointSequence;
  final int revision;
  final StudyActivityRecordingQuality recordingQuality;
}

final class StudyActivityEndRequest {
  StudyActivityEndRequest({required this.owner, required this.reason}) {
    requireHomeTrainingInput(reason == StudyActivityEndReason.exited ||
        reason == StudyActivityEndReason.queueFinished ||
        reason == StudyActivityEndReason.submitted);
  }
  final StudyActivityOwner owner;
  final StudyActivityEndReason reason;
}

/// Sole runtime owner authority. Begin follows successful non-preview route
/// admission. Temporary cover/background pauses; same owner resumes; true
/// pop/replace/release ends. Submitted follows successful Exam submission only.
/// The service owns injectable elapsed/wall clocks, sequences and serialization;
/// callers never supply guessed durations. Checkpoints are atomic/idempotent,
/// terminal sessions reject append, stale owners fail, and failures do not block
/// answer/grading/exit. No timer, transition engine or storage exists here.
abstract interface class StudyActivityService {
  Future<HomeTrainingResult<StudyActivityOwner>> begin(
      StudyActivityBeginRequest request);
  Future<HomeTrainingResult<StudyActivitySnapshot>> pause(
      StudyActivityOwner owner);
  Future<HomeTrainingResult<StudyActivitySnapshot>> resume(
      StudyActivityOwner owner);
  Future<HomeTrainingResult<StudyActivitySnapshot>> checkpoint(
      StudyActivityOwner owner);
  Future<HomeTrainingResult<StudyActivitySnapshot>> end(
      StudyActivityEndRequest request);
}

final class StudyActivityDaySummary {
  StudyActivityDaySummary({required this.localDate, required this.durationMs}) {
    requireHomeTrainingInput(_validLocalDate(localDate) && durationMs >= 0);
  }
  final String localDate;
  final int durationMs;
}

/// Segment-derived current local Monday-Sunday week, integer milliseconds.
/// This is recorded data, never extrapolated from Questions, ReviewLog or
/// an open interval. Failed queries have no fabricated zero-valued snapshot.
final class StudyActivityWeekSnapshot {
  StudyActivityWeekSnapshot(
      {required this.mondayLocalDate,
      required Iterable<StudyActivityDaySummary> days,
      required this.recordingQuality})
      : days = List.unmodifiable(days) {
    requireHomeTrainingInput(_validLocalDate(mondayLocalDate));
    final monday = DateTime.parse(mondayLocalDate);
    requireHomeTrainingInput(
        monday.weekday == DateTime.monday && this.days.length == 7);
    for (var index = 0; index < this.days.length; index++) {
      // UTC here represents date arithmetic only, not a timezone/day resolver.
      final expected =
          DateTime.utc(monday.year, monday.month, monday.day + index);
      requireHomeTrainingInput(this.days[index].localDate ==
          '${expected.year.toString().padLeft(4, '0')}-${expected.month.toString().padLeft(2, '0')}-${expected.day.toString().padLeft(2, '0')}');
    }
  }
  final String mondayLocalDate;
  final List<StudyActivityDaySummary> days;
  final StudyActivityRecordingQuality recordingQuality;
  int get totalDurationMs =>
      days.fold(0, (total, day) => total + day.durationMs);
  int get learningDayCount => days.where((day) => day.durationMs > 0).length;
}

abstract interface class StudyActivityQuery {
  /// Uses injectable local-day resolution; no historical backfill or queue
  /// recovery. Partial/recorded-only and unavailable remain distinct.
  Future<HomeTrainingResult<StudyActivityWeekSnapshot>> readCurrentWeek();
}

bool _validLocalDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final date = DateTime.tryParse(value);
  return date != null &&
      date.year == int.parse(value.substring(0, 4)) &&
      date.month == int.parse(value.substring(5, 7)) &&
      date.day == int.parse(value.substring(8, 10));
}
