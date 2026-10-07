library;

import '../../domain/conversations/conversation.dart';
import '../capabilities/capability.dart';
import 'study_query_dtos.dart';
import 'study_query_error.dart';
import 'study_query_service.dart';

final class ListQuestionBanksInput {
  const ListQuestionBanksInput({this.cursor, this.limit = 50});
  final OpaqueCursor? cursor;
  final int limit;
}

final class GetStudyOverviewInput {
  const GetStudyOverviewInput({this.bankName, required this.timezone});
  final String? bankName;
  final String timezone;
}

final class GetDueReviewSummaryInput {
  const GetDueReviewSummaryInput(
      {this.bankName, this.timezone, required this.from, required this.to});
  final String? bankName;
  final String? timezone;
  final DateTime from;
  final DateTime to;
}

final class SearchQuestionsInput {
  const SearchQuestionsInput(
      {required this.bankName,
      required this.query,
      this.cursor,
      this.limit = 50});
  final String bankName;
  final String query;
  final OpaqueCursor? cursor;
  final int limit;
}

final class GetQuestionDetailInput {
  const GetQuestionDetailInput({required this.questionId});
  final String questionId;
}

final class GetWeakQuestionsInput {
  const GetWeakQuestionsInput({this.bankName, this.cursor, this.limit = 50});
  final String? bankName;
  final OpaqueCursor? cursor;
  final int limit;
}

final class StudyCapabilities {
  const StudyCapabilities();
  static const listQuestionBanks =
      CapabilityId<ListQuestionBanksInput, BankListPage>('list_question_banks');
  static const getStudyOverview =
      CapabilityId<GetStudyOverviewInput, StudyOverview>('get_study_overview');
  static const getDueReviewSummary =
      CapabilityId<GetDueReviewSummaryInput, DueReviewSummary>(
          'get_due_review_summary');
  static const searchQuestions =
      CapabilityId<SearchQuestionsInput, QuestionSearchPage>(
          'search_questions');
  static const getQuestionDetail =
      CapabilityId<GetQuestionDetailInput, QuestionDetail>(
          'get_question_detail');
  static const getWeakQuestions =
      CapabilityId<GetWeakQuestionsInput, WeakQuestionPage>(
          'get_weak_questions');
  static final List<CapabilityId> ids = List.unmodifiable([
    listQuestionBanks,
    getStudyOverview,
    getDueReviewSummary,
    searchQuestions,
    getQuestionDetail,
    getWeakQuestions
  ]);
  static List<CapabilityDefinition> definitions(StudyQueryService service) => [
        _read<ListQuestionBanksInput, BankListPage>(
            listQuestionBanks,
            (ListQuestionBanksInput input) => service.listQuestionBanks(
                cursor: input.cursor, limit: input.limit)),
        _read<GetStudyOverviewInput, StudyOverview>(
            getStudyOverview,
            (GetStudyOverviewInput input) => service.getStudyOverview(
                bankName: input.bankName, timezone: input.timezone)),
        _read<GetDueReviewSummaryInput, DueReviewSummary>(
            getDueReviewSummary,
            (GetDueReviewSummaryInput input) => service.getDueReviewSummary(
                bankName: input.bankName,
                timezone: input.timezone,
                from: input.from,
                to: input.to)),
        _read<SearchQuestionsInput, QuestionSearchPage>(
            searchQuestions,
            (SearchQuestionsInput input) => service.searchQuestions(
                bankName: input.bankName,
                query: input.query,
                cursor: input.cursor,
                limit: input.limit)),
        _read<GetQuestionDetailInput, QuestionDetail>(
            getQuestionDetail,
            (GetQuestionDetailInput input) =>
                service.getQuestionDetail(input.questionId)),
        _read<GetWeakQuestionsInput, WeakQuestionPage>(
            getWeakQuestions,
            (GetWeakQuestionsInput input) => service.getWeakQuestions(
                bankName: input.bankName,
                cursor: input.cursor,
                limit: input.limit)),
      ];
}

CapabilityDefinition<I, O> _read<I, O>(
        CapabilityId<I, O> id, Future<O> Function(I) query) =>
    CapabilityDefinition(
      id: id, permission: CapabilityPermission.read,
      permittedEffects: const [CapabilityEffect.none],
      semantics: CapabilityExecutionSemantics.repeatableRead,
      // Existing six tools are local-user global study reads, not Project-filtered
      // queries. Reject a claimed restricted scope instead of querying globally.
      authorize: (_, context) async =>
          context.scope.kind == ConversationScopeKind.global,
      handler: CapabilityHandler((input, _, confirmed) async {
        try {
          return CapabilityEvidence.completed(
              await query(input), CapabilityEffect.none);
        } on StudyQueryException catch (error) {
          // The owning StudyQueryService is strictly non-mutating on all paths.
          return CapabilityEvidence.zeroEffectFailure(
              studyCapabilityFailure(error.failure));
        }
      }),
    );

CapabilityFailure studyCapabilityFailure(StudyQueryFailure failure) =>
    switch (failure) {
      StudyQueryFailure.invalidRequest => CapabilityFailure.invalidRequest,
      StudyQueryFailure.notFound => CapabilityFailure.notFound,
      StudyQueryFailure.accessDenied => CapabilityFailure.accessDenied,
      StudyQueryFailure.dataCorrupt => CapabilityFailure.dataCorrupt,
      StudyQueryFailure.temporarilyUnavailable =>
        CapabilityFailure.temporarilyUnavailable,
      StudyQueryFailure.internalError => CapabilityFailure.internalError,
    };
StudyQueryFailure studyQueryFailure(CapabilityFailure failure) =>
    switch (failure) {
      CapabilityFailure.invalidRequest ||
      CapabilityFailure.unknownCapability =>
        StudyQueryFailure.invalidRequest,
      CapabilityFailure.notFound => StudyQueryFailure.notFound,
      CapabilityFailure.accessDenied => StudyQueryFailure.accessDenied,
      CapabilityFailure.dataCorrupt => StudyQueryFailure.dataCorrupt,
      CapabilityFailure.temporarilyUnavailable =>
        StudyQueryFailure.temporarilyUnavailable,
      _ => StudyQueryFailure.internalError,
    };

CapabilityContext studyCapabilityContext(CapabilityPrincipal principal) =>
    CapabilityContext(
        principal: principal,
        capabilities: StudyCapabilities.ids,
        permissions: const [CapabilityPermission.read],
        scope: ConversationScope.global(),
        authorizedScope: ConversationScope.global());
