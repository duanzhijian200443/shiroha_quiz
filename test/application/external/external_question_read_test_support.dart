import 'package:uuid/uuid.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_question_read.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/data/repositories/external_question_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_target_read_repository.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'durable_stage_test_support.dart';
import '../study_query/study_query_test_support.dart'
    show makeDraft, textContent, insertTypedQuestion, insertLegacyQuestion;

export 'durable_stage_test_support.dart';
export '../study_query/study_query_test_support.dart'
    show makeDraft, textContent, richContent, rawFallbackPayload;

/// Barriers around the actual scoped SQLite port; never mocked authorization.
final class QuestionReadBarrier implements ExternalQuestionReadPort {
  QuestionReadBarrier(this.inner);
  final ExternalQuestionReadPort inner;
  Future<void> Function()? beforeSearch,
      afterSearch,
      afterDetail,
      beforeRelease;
  int releases = 0;
  @override
  Future<ExternalQuestionCandidates> search(
      ExternalQuestionReadAccess access,
      String query,
      int limit,
      ExternalQuestionKey? after,
      void Function() check) async {
    await beforeSearch?.call();
    final result = await inner.search(access, query, limit, after, check);
    await afterSearch?.call();
    return result;
  }

  @override
  Future<ExternalQuestionDetail> detail(ExternalQuestionReadAccess access,
      ExternalQuestionKey key, void Function() check) async {
    final result = await inner.detail(access, key, check);
    await afterDetail?.call();
    return result;
  }

  @override
  Future<void> release(ExternalQuestionReadAccess access,
      List<ExternalQuestionKey> keys, void Function() check) async {
    releases++;
    await beforeRelease?.call();
    await inner.release(access, keys, check);
  }
}

final class QuestionReadHarness {
  final s = DurableStageHarness();
  late ExternalReadContextService read;
  late QuestionReadBarrier barrier;
  int contentReads = 0;
  Future<void> Function(ExternalQuestionReadCheckpoint)? checkpoint;

  Future<void> open() async {
    await s.open();
    await s.management.replaceGrant(
        s.profile,
        1,
        s.policy(permissions: [
          CapabilityPermission.read,
          CapabilityPermission.stage
        ]));
    compose();
  }

  void compose(
      {int maxResponseBytes = 32768,
      int maxHandles = 256,
      int maxPending = 16,
      Duration timeout = const Duration(seconds: 2)}) {
    barrier = QuestionReadBarrier(SqliteExternalQuestionReadRepository(
        databaseHelper: s.h.helper,
        checkpoint: (point) async {
          if (point == ExternalQuestionReadCheckpoint.beforeContentRead) {
            contentReads++;
          }
          await checkpoint?.call(point);
        }));
    read = ExternalReadContextService(
        admission: s.service.runtimeAdmission,
        targets: SqliteExternalTargetReadRepository(databaseHelper: s.h.helper),
        questions: barrier,
        maxResponseBytes: maxResponseBytes,
        maxActiveHandles: maxHandles,
        maxInFlight: maxPending,
        maxQueryDuration: timeout);
  }

  Future<String> context({String bank = 'bank'}) async {
    final page = await read.listTargets(session: s.session);
    return read.createContext(
        session: s.session,
        targetRef:
            page.items.firstWhere((item) => item.bankName == bank).targetRef);
  }

  Future<String> typed(
      {QuestionDraftV2? draft,
      String? id,
      String bank = 'bank',
      int createdAt = 100}) async {
    id ??= const Uuid().v4();
    await insertTypedQuestion(s.h.db,
        draft: draft ??
            makeDraft('synthetic',
                kind: QuestionKind.shortAnswer,
                stem: textContent('Synthetic needle'),
                answer: ContentAnswer(content: textContent('Safe answer'))),
        storageId: id,
        createdAt: createdAt,
        bankName: bank);
    return id;
  }

  Future<void> legacy(String id,
          {String bank = 'bank',
          int createdAt = 100,
          String stem = 'Legacy needle'}) =>
      insertLegacyQuestion(s.h.db,
          id: id, bankName: bank, createdAt: createdAt, content: stem);
  Future<void> close() async {
    read.close();
    await read.whenIdle;
    await s.close();
  }
}
