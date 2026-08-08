// Test-only stdio subprocess fixture for the mcp.study.v0 server lifecycle.
//
// This fixture is the child process driven by study_mcp_server_test.dart. It
// assembles the production StudyMcpServer and StudyMcpAdapter over the real
// T0 StudyQueryService with offline fake ports and serves the frozen surface
// over the process stdin/stdout through the production serveStdio API. It
// never touches a database, the filesystem, a network, a provider, or the
// production composition root, and it lives only under test/ (never lib/).
library;

import 'package:shiroha_quiz/application/study_query/study_query_clock.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/mcp/study_mcp_adapter.dart';
import 'package:shiroha_quiz/mcp/study_mcp_server.dart';

final DateTime _fixedNow = DateTime.utc(2026, 8, 8, 17);

final class _FixedClock implements StudyClock {
  const _FixedClock();

  @override
  DateTime nowUtc() => _fixedNow;
}

/// Offline question port returning empty pages: lifecycle acceptance drives
/// protocol behavior, not T0 data. T0 data semantics are covered by
/// mcp_contract_test.dart against the real repositories.
final class _EmptyQuestionQuery implements StudyQuestionQueryPort {
  const _EmptyQuestionQuery();

  @override
  Future<StudyPage<QuestionBankSummary>> listStudyQuestionBanks({
    required int nowUnixSeconds,
    required int limit,
    String? afterBankName,
  }) async {
    return const StudyPage<QuestionBankSummary>(
      items: <QuestionBankSummary>[],
      hasMore: false,
    );
  }

  @override
  Future<StudyPage<StudyQuestionRead>> searchStudyQuestions({
    required String bankName,
    required String query,
    required int nowUnixSeconds,
    required int limit,
    int? afterCreatedAt,
    String? afterId,
  }) async {
    return const StudyPage<StudyQuestionRead>(
      items: <StudyQuestionRead>[],
      hasMore: false,
    );
  }

  @override
  Future<StudyQuestionRead?> getStudyQuestionDetail(
    String questionId, {
    required int nowUnixSeconds,
  }) async {
    return null;
  }

  @override
  Future<StudyPage<StudyQuestionRead>> listStudyWeakQuestions({
    required int nowUnixSeconds,
    required int limit,
    String? bankName,
    int? afterLastLapseTime,
    String? afterId,
  }) async {
    return const StudyPage<StudyQuestionRead>(
      items: <StudyQuestionRead>[],
      hasMore: false,
    );
  }
}

/// Offline metrics port returning zeroed counts and no scheduled instants.
final class _EmptyMetricsQuery implements StudyMetricsQueryPort {
  const _EmptyMetricsQuery();

  @override
  Future<StudyOverviewCounts> getStudyOverviewCounts({
    String? bankName,
    required int nowUnixSeconds,
    required int todayStartUnixSeconds,
  }) async {
    return const StudyOverviewCounts(
      questionCount: 0,
      masteredCount: 0,
      dueCount: 0,
      todayPracticeCount: 0,
      wrongQuestionCount: 0,
    );
  }

  @override
  Future<List<int>> getStudyScheduledReviewTimestamps({
    String? bankName,
    required int fromUnixSeconds,
    required int toUnixSeconds,
  }) async {
    return const <int>[];
  }

  @override
  Future<int> countStudyDueNow({
    String? bankName,
    required int nowUnixSeconds,
  }) async {
    return 0;
  }
}

/// Assembles the exact server-under-test for the stdio lifecycle acceptance:
/// the production server and adapter over the real T0 service with offline
/// fake ports and a fixed clock.
StudyMcpServer buildStdioFixtureServer() {
  return StudyMcpServer(
    adapter: StudyMcpAdapter(
      service: StudyQueryService(
        questionQuery: const _EmptyQuestionQuery(),
        metricsQuery: const _EmptyMetricsQuery(),
        clock: const _FixedClock(),
      ),
      clock: const _FixedClock(),
    ),
  );
}

/// Serves the frozen mcp.study.v0 surface over the process stdin/stdout.
/// The isolate stays alive on the stdio subscription and exits when the
/// client closes the connection.
Future<void> main(List<String> arguments) async {
  await buildStdioFixtureServer().serveStdio();
}
