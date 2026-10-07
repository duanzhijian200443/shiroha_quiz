import 'package:shiroha_quiz/application/study_query/study_query_clock.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';

final class CapabilityClock implements StudyClock {
  const CapabilityClock();

  @override
  DateTime nowUtc() => DateTime.utc(2026, 8, 10, 12);
}

final class CapabilityQuestionPort implements StudyQuestionQueryPort {
  CapabilityQuestionPort({this.failure, this.bankName = 'Synthetic'});

  final StudyQueryRepositoryFailure? failure;
  final String bankName;
  final List<String> calls = <String>[];

  void _throwIfNeeded() {
    final selected = failure;
    if (selected != null) throw StudyQueryRepositoryException(selected);
  }

  StudyQuestionRead get _question => TypedStudyQuestionRead(
        questionId: 'q1',
        bankName: bankName,
        createdAt: 1,
        draft: QuestionDraftV2(
          questionId: 'q1',
          kind: QuestionKind.shortAnswer,
          stem: RichContent(
            nodes: <ContentNode>[
              const TextNode('Safe stem'),
              RawFallbackNode(<String, Object?>{
                'type': 'raw_fallback',
                'payload': <String, Object?>{'private': 'private-marker'},
              }),
            ],
          ),
        ),
        review: const StudyQuestionReviewState(
          due: true,
          lapseCount: 2,
          difficulty: 6.5,
          lastLapseTime: 1786363200,
        ),
      );

  @override
  Future<StudyPage<QuestionBankSummary>> listStudyQuestionBanks({
    required int nowUnixSeconds,
    required int limit,
    String? afterBankName,
  }) async {
    calls.add('banks');
    _throwIfNeeded();
    return StudyPage<QuestionBankSummary>(
      items: <QuestionBankSummary>[
        QuestionBankSummary(
          bankName: bankName,
          folderName: 'Folder',
          questionCount: 1,
          dueCount: 1,
          masteredCount: 0,
        ),
      ],
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
    calls.add('search');
    _throwIfNeeded();
    return StudyPage<StudyQuestionRead>(
      items: <StudyQuestionRead>[_question],
      hasMore: false,
    );
  }

  @override
  Future<StudyQuestionRead?> getStudyQuestionDetail(
    String questionId, {
    required int nowUnixSeconds,
  }) async {
    calls.add('detail');
    _throwIfNeeded();
    return _question;
  }

  @override
  Future<StudyPage<StudyQuestionRead>> listStudyWeakQuestions({
    required int nowUnixSeconds,
    required int limit,
    String? bankName,
    int? afterLastLapseTime,
    String? afterId,
  }) async {
    calls.add('weak');
    _throwIfNeeded();
    return StudyPage<StudyQuestionRead>(
      items: <StudyQuestionRead>[_question],
      hasMore: false,
    );
  }
}

final class CapabilityMetricsPort implements StudyMetricsQueryPort {
  final List<String> calls = <String>[];

  @override
  Future<StudyOverviewCounts> getStudyOverviewCounts({
    String? bankName,
    required int nowUnixSeconds,
    required int todayStartUnixSeconds,
  }) async {
    calls.add('overview');
    return const StudyOverviewCounts(
      questionCount: 1,
      masteredCount: 0,
      dueCount: 1,
      todayPracticeCount: 0,
      wrongQuestionCount: 1,
    );
  }

  @override
  Future<int> countStudyDueNow({
    String? bankName,
    required int nowUnixSeconds,
  }) async {
    calls.add('due_now');
    return 1;
  }

  @override
  Future<List<int>> getStudyScheduledReviewTimestamps({
    String? bankName,
    required int fromUnixSeconds,
    required int toUnixSeconds,
  }) async {
    calls.add('scheduled');
    return <int>[1786363200];
  }
}
