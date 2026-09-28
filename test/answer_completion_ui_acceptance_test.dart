import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answer_completion/answer_completion_query.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_generation.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/domain/answer_completion/imported_question_set.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/ui/dependencies/answer_completion_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/pages/answer_completion_ai_review.dart';
import 'package:shiroha_quiz/ui/pages/answer_completion_screen.dart';
import 'package:shiroha_quiz/ui/pages/bank_detail_screen.dart';

const _id = '22222222-2222-4222-8222-222222222222';
const _setId = '11111111-1111-4111-8111-111111111111';
RichContent _text(String s) => RichContent(nodes: [TextNode(s)]);
QuestionDraftV2 _draft({QuestionAnswer? answer}) => QuestionDraftV2(
    questionId: 'draft-id',
    kind: QuestionKind.shortAnswer,
    stem: _text('Synthetic missing stem'),
    answer: answer);
AnswerCompletionMember _typed({QuestionAnswer? answer}) =>
    AnswerCompletionMember.typed(
        storageId: _id, typedDraft: _draft(answer: answer));
AnswerCompletionSet _set(String name, List<AnswerCompletionMember> members,
        {String id = _setId,
        AnswerCompletionProvenance provenance =
            AnswerCompletionProvenance.none}) =>
    AnswerCompletionSet(
        set: ImportedQuestionSet(
            setId: id,
            bankName: 'bank',
            displayName: name,
            createdAt: 1,
            sourceFileId: provenance == AnswerCompletionProvenance.none
                ? null
                : 'source'),
        provenance: provenance,
        members: members);

class _Query implements AnswerCompletionQuery {
  _Query(this.result);
  AnswerCompletionRead result;
  int calls = 0;
  @override
  Future<AnswerCompletionRead> readBank(String bankName) async {
    calls++;
    return result;
  }
}

class _Study extends Fake implements StudyQuestionQueryPort {
  _Study(this.draft);
  QuestionDraftV2 draft;
  final ids = <String>[];
  @override
  Future<StudyQuestionRead?> getStudyQuestionDetail(String questionId,
      {required int nowUnixSeconds}) async {
    ids.add(questionId);
    return TypedStudyQuestionRead(
        questionId: questionId,
        bankName: 'bank',
        createdAt: 1,
        draft: draft,
        review: const StudyQuestionReviewState(
            due: false, lapseCount: 0, difficulty: 5, lastLapseTime: null));
  }
}

class _Provider implements AiAnswerProviderPort {
  int calls = 0;
  Completer<void>? gate;
  @override
  Future<AiAnswerProviderResult> generateAnswer(
      AiAnswerProviderRequest request) async {
    calls++;
    await gate?.future;
    return AiAnswerProviderResult(
        answer: ContentAnswer(content: _text('generated')),
        providerProfileId: 'synthetic-provider');
  }
}

class _Commit implements AiAnswerCommitPersistencePort {
  final candidates = <AnswerCandidate>[];
  void Function(AnswerCandidate)? onCommit;
  @override
  Future<void> commitAnswer(AnswerCandidate candidate) async {
    candidates.add(candidate);
    onCommit?.call(candidate);
  }
}

void main() {
  Future<void> pump(WidgetTester tester, _Query query,
      {Widget? home,
      AiAnswerGenerationService? generation,
      AiAnswerCommitCommand? commit,
      void Function()? picker}) async {
    await tester.pumpWidget(AnswerCompletionDependenciesScope(
        query: query,
        generationService: generation,
        aiCommitCommand: commit,
        pickFile: () async {
          picker?.call();
          return null;
        },
        child: MaterialApp(
            home: home ?? const AnswerCompletionScreen(bankName: 'bank'))));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'BankDetail opens queue with four categories and never invokes picker',
      (tester) async {
    final query = _Query(AnswerCompletionSnapshot(sets: [
      _set('pending set', [_typed()]),
      _set('unsupported set', [const AnswerCompletionMember.legacy('legacy')],
          id: '11111111-1111-4111-8111-111111111112'),
      _set('completed set', [_typed(answer: ContentAnswer(content: _text('')))],
          id: '11111111-1111-4111-8111-111111111113'),
    ], ungrouped: [
      _typed()
    ]));
    var picks = 0;
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, query,
        home: const BankDetailScreen(bankName: 'bank'), picker: () => picks++);
    expect(find.text('补充答案'), findsOneWidget);
    expect(find.text('从文件补充答案'), findsNothing);
    await tester.tap(find.text('补充答案'));
    await tester.pumpAndSettle();
    for (final title in [
      '待处理',
      '未分组题目',
      '暂不支持 / 数据异常',
      '已完成',
      'pending set',
      'unsupported set',
      'completed set'
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('待补答案'), findsWidgets);
    expect(picks, 0);
    expect(find.text('添加答案文件'), findsNothing);
  });

  testWidgets(
      'detail missing default, show all, truthful counts and provenance',
      (tester) async {
    final query = _Query(AnswerCompletionSnapshot(sets: [
      _set('mixed set', [
        _typed(),
        AnswerCompletionMember.typed(
            storageId: 'answered',
            typedDraft: QuestionDraftV2(
                questionId: 'answered',
                kind: QuestionKind.shortAnswer,
                stem: _text('Synthetic answered stem'),
                answer: ContentAnswer(content: _text('')))),
        const AnswerCompletionMember.legacy('legacy'),
        const AnswerCompletionMember.corrupt('corrupt'),
      ])
    ], ungrouped: []));
    await pump(tester, query,
        home: const AnswerCompletionScreen(bankName: 'bank', setId: _setId));
    expect(find.text('共 4 · 待补 1 · 已答 1 · 暂不支持/异常 2'), findsOneWidget);
    expect(find.text('Synthetic missing stem'), findsOneWidget);
    expect(find.text('Synthetic answered stem'), findsNothing);
    expect(find.text('未关联源文件'), findsOneWidget);
    expect(find.textContaining('已删除'), findsNothing);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic answered stem'), findsOneWidget);
    expect(find.text('暂不支持：旧版题目'), findsOneWidget);
    expect(find.text('数据异常：无法安全读取题目'), findsOneWidget);
    expect(find.text('AI补答案'), findsNWidgets(2));
    final button = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '从答案文件补充'));
    expect(button.onPressed, isNull);
    query.result = AnswerCompletionSnapshot(sets: [
      _set('mixed set', [_typed()],
          provenance: AnswerCompletionProvenance.unavailable)
    ], ungrouped: []);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('源文件不可用或已删除，题组仍保留'), findsOneWidget);
    expect(find.text('mixed set'), findsOneWidget);
  });

  testWidgets('query unavailable never presents fabricated counts',
      (tester) async {
    await pump(tester, _Query(const AnswerCompletionQueryUnavailable()));
    expect(find.text('暂时无法读取待补答案，请重试。'), findsOneWidget);
    expect(find.textContaining('共 0'), findsNothing);
  });

  for (final initial in [null, 'previous', 'generated']) {
    testWidgets(
        'existing P7 $initial uses real storageId and explicit shared review',
        (tester) async {
      final value =
          initial == null ? null : ContentAnswer(content: _text(initial));
      final query = _Query(AnswerCompletionSnapshot(sets: [
        _set('typed set', [_typed(answer: value)])
      ], ungrouped: []));
      final study = _Study(_draft(answer: value));
      final provider = _Provider();
      final commit = _Commit();
      final generation = AiAnswerGenerationService(
          questionPort: study,
          providerPort: provider,
          idFactory: () => 'generation',
          clock: () => DateTime.utc(2026));
      await pump(tester, query,
          home: const AnswerCompletionScreen(bankName: 'bank', setId: _setId),
          generation: generation,
          commit: AiAnswerCommitCommand(persistencePort: commit));
      if (initial != null) {
        await tester.tap(find.byType(SwitchListTile));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('AI补答案'));
      await tester.pumpAndSettle();
      expect(provider.calls, 1);
      expect(study.ids.toSet(), {_id});
      expect(find.byType(AiAnswerReviewDialog), findsOneWidget);
      expect(commit.candidates, isEmpty);
      if (initial == 'previous') {
        await tester.tap(find.text('确认替换'));
        await tester.pumpAndSettle();
        expect(commit.candidates, isEmpty);
        await tester.tap(find.text('二次确认替换'));
        await tester.pumpAndSettle();
        expect(
            commit.candidates.single.writeIntent, CandidateWriteIntent.replace);
      } else if (initial == null) {
        await tester.tap(find.text('采用答案'));
        await tester.pumpAndSettle();
        expect(commit.candidates.single.writeIntent, CandidateWriteIntent.fill);
        expect(query.calls, 2);
      } else {
        expect(find.text('采用答案'), findsNothing);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(commit.candidates, isEmpty);
      }
    });
  }

  testWidgets(
      'legacy/corrupt never execute P7; disposing generation discards late result',
      (tester) async {
    final query = _Query(AnswerCompletionSnapshot(sets: [
      _set('mixed set', [
        _typed(),
        const AnswerCompletionMember.legacy('legacy'),
        const AnswerCompletionMember.corrupt('corrupt')
      ])
    ], ungrouped: []));
    final study = _Study(_draft());
    final provider = _Provider()..gate = Completer<void>();
    final commit = _Commit();
    final generation = AiAnswerGenerationService(
        questionPort: study,
        providerPort: provider,
        idFactory: () => 'generation',
        clock: () => DateTime.utc(2026));
    await pump(tester, query,
        home: const AnswerCompletionScreen(bankName: 'bank', setId: _setId),
        generation: generation,
        commit: AiAnswerCommitCommand(persistencePort: commit));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(find.text('AI补答案'), findsOneWidget);
    expect(provider.calls, 0);
    await tester.tap(find.text('AI补答案'));
    await tester.pump();
    await tester.pump();
    expect(provider.calls, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    provider.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AiAnswerReviewDialog), findsNothing);
    expect(commit.candidates, isEmpty);
    expect(study.ids, [_id]);
  });

  testWidgets('ungrouped fill refreshes persisted projection and disappears',
      (tester) async {
    final query =
        _Query(AnswerCompletionSnapshot(sets: [], ungrouped: [_typed()]));
    final study = _Study(_draft());
    final provider = _Provider();
    final commit = _Commit()
      ..onCommit = (_) =>
          query.result = AnswerCompletionSnapshot(sets: [], ungrouped: []);
    await pump(tester, query,
        generation: AiAnswerGenerationService(
            questionPort: study,
            providerPort: provider,
            idFactory: () => 'generation',
            clock: () => DateTime.utc(2026)),
        commit: AiAnswerCommitCommand(persistencePort: commit));
    await tester.tap(find.text('AI补答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('采用答案'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic missing stem'), findsNothing);
    expect(find.text('AI补答案'), findsNothing);
    expect((query.result as AnswerCompletionSnapshot).sets, isEmpty);
  });
}
