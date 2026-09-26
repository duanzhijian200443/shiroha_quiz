import '../study_query/study_query_ports.dart';

/// Which AI answer entry one persisted question is allowed to use.
///
/// [unavailable] is the fail-closed route: it is returned for a blank,
/// missing, or unreadable persisted identity and is never a legacy fallback.
enum AiAnswerEntryRoute { legacy, typed, unavailable }

/// ANSWER-ENTRY-GUARD routing decision for the legacy AI answer entry.
///
/// Classifies one persisted question by its real `storageId` through the
/// typed-aware Application read, so a typed question can never reach the
/// legacy `answerSingleQuestion` provider path. Only
/// [AiAnswerEntryRoute.legacy] authorizes a legacy provider call.
///
/// The guard reads and decides; it never generates, writes, persists, or
/// logs, and it never infers a question type from title, folder, filename,
/// or bank name.
final class AiAnswerEntryGuard {
  AiAnswerEntryGuard({
    required StudyQuestionQueryPort questionPort,
    required DateTime Function() clock,
  })  : _questionPort = questionPort,
        _clock = clock;

  final StudyQuestionQueryPort _questionPort;
  final DateTime Function() _clock;

  /// Resolves the AI answer entry permitted for [storageId].
  ///
  /// A corrupt or unsafe typed sidecar hard-fails at the repository boundary;
  /// that failure and a missing row both yield
  /// [AiAnswerEntryRoute.unavailable] rather than degrading to legacy.
  Future<AiAnswerEntryRoute> routeFor({required String storageId}) async {
    final trimmedId = storageId.trim();
    if (trimmedId.isEmpty) return AiAnswerEntryRoute.unavailable;

    final StudyQuestionRead? read;
    try {
      read = await _questionPort.getStudyQuestionDetail(
        trimmedId,
        nowUnixSeconds: _clock().toUtc().millisecondsSinceEpoch ~/ 1000,
      );
    } catch (_) {
      return AiAnswerEntryRoute.unavailable;
    }

    return switch (read) {
      TypedStudyQuestionRead() => AiAnswerEntryRoute.typed,
      LegacyStudyQuestionRead() => AiAnswerEntryRoute.legacy,
      null => AiAnswerEntryRoute.unavailable,
    };
  }
}
