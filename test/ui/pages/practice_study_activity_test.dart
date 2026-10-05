import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/application/practice/practice_session_mutation_command.dart';
import 'package:shiroha_quiz/application/practice/record_answer_attempt_command.dart';
import 'package:shiroha_quiz/application/questions/question_mutation_command.dart';
import 'package:shiroha_quiz/application/questions/question_write_mutation_command.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_contracts.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/domain/attempt/answer_attempt.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/ui/dependencies/practice_command_dependencies.dart';
import 'package:shiroha_quiz/ui/dependencies/study_activity_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/pages/practice_page.dart';
import 'package:shiroha_quiz/ui/study_activity/study_activity_route_binding.dart';
import '../../support/study_activity_runtime_fakes.dart';
import '../../support/activity_widget_dependencies.dart';

class _Mutations extends Fake
    implements
        QuestionMutationPersistencePort,
        QuestionWriteMutationPersistencePort,
        PracticeSessionMutationPersistencePort {}

class _Exam extends Fake implements ExamMutationPersistencePort {}

class _Attempts implements AnswerAttemptPersistencePort {
  final attempts = <AnswerAttempt>[];
  @override
  Future<void> recordAttempt(AnswerAttempt attempt) async =>
      attempts.add(attempt);
}

const _question = Question(
    id: 'q',
    type: 0,
    content: 'Activity synthetic question',
    options: '["A. first","B. second"]',
    answer: 'A',
    createdAt: 1,
    bankName: 'synthetic');

void main() {
  const category = UncategorizedCategoryKey();
  Future<void> pump(
    WidgetTester tester,
    RecordingActivity activity, {
    StudyActivityScene scene = StudyActivityScene.ordinaryPractice,
    bool preview = false,
    _Attempts? attempts,
    Future<void> Function(String, int)? grade,
    PhotoAnswerCaptureLauncher? photo,
    Question question = _question,
  }) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    ReviewEngineService().initPreparedStudySession(
        [LegacyPersistedQuestion(question: question)]);
    final mutations = _Mutations();
    await tester.pumpWidget(StudyActivityDependenciesScope(
        dependencies:
            StudyActivityDependencies(service: activity, query: activity),
        child: activityWidgetDependencies(
            exam: _Exam(),
            child: MaterialApp(
                home: PracticePage(
              bankName: 'synthetic',
              usePreparedStudySession: !preview,
              initialQuestions: preview ? [question] : null,
              preparedSessionKind: scene == StudyActivityScene.studyPlanPractice
                  ? AnswerAttemptSessionKind.focused
                  : AnswerAttemptSessionKind.normal,
              studyActivity: StudyActivityRouteDescriptor(
                  scene: scene,
                  context: StudyActivityContext(
                      categoryKey: category,
                      contentId: 'content',
                      planId: 'plan',
                      bankName: 'synthetic')),
              practiceCommands: PracticeCommandDependencies(
                  questionMutation: QuestionMutationCommand(mutations),
                  questionWriteMutation:
                      QuestionWriteMutationCommand(mutations),
                  practiceSessionMutation:
                      PracticeSessionMutationCommand(mutations),
                  recordAttempt:
                      RecordAnswerAttemptCommand(attempts ?? _Attempts())),
              submitReviewOverride: grade ?? (_, __) async {},
              photoAnswerCaptureLauncher: photo,
            )))));
    await tester.pumpAndSettle();
  }

  for (final scene in [
    StudyActivityScene.ordinaryPractice,
    StudyActivityScene.studyPlanPractice,
    StudyActivityScene.categoryReview
  ]) {
    testWidgets('explicit $scene admission keeps soft context and one owner',
        (tester) async {
      final activity = RecordingActivity();
      await pump(tester, activity, scene: scene);
      expect(activity.begins.single.scene, scene);
      expect(activity.begins.single.context.categoryKey, category);
      expect(activity.begins.single.context.planId, 'plan');
      expect(activity.begins.single.context.contentId, 'content');
      expect(activity.begins.single.ownerToken, isNot('synthetic'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(activity.events, ['pause', 'resume']);
      expect(find.text('Activity synthetic question'), findsOneWidget);
      expect(activity.ends, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(activity.ends.single.reason, StudyActivityEndReason.exited);
    });
  }

  testWidgets('preview never begins even with explicit descriptor',
      (tester) async {
    final activity = RecordingActivity();
    await pump(tester, activity, preview: true);
    expect(activity.begins, isEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(activity.ends, isEmpty);
  });

  for (final failure in ['begin', 'checkpoint', 'pause', 'end']) {
    testWidgets('$failure failure preserves attempts/grade/queue completion',
        (tester) async {
      final activity = RecordingActivity()..failures.add(failure);
      final attempts = _Attempts();
      final grades = <int>[];
      await pump(tester, activity,
          attempts: attempts, grade: (_, grade) async => grades.add(grade));
      if (failure == 'checkpoint') {
        await tester.pump(const Duration(seconds: 30));
      }
      if (failure == 'pause') {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
      }
      await tester.tap(find.text('first'));
      await tester.tap(find.text('查看答案'));
      await tester.pumpAndSettle();
      expect(attempts.attempts.single.sessionKind,
          AnswerAttemptSessionKind.normal);
      await tester.tap(find.text('顺利'));
      await tester.pumpAndSettle();
      expect(grades, [3]);
      expect(find.text('🎉 任务完成'), findsOneWidget);
      if (failure != 'begin') {
        expect(
            activity.ends.single.reason, StudyActivityEndReason.queueFinished);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(activity.ends.length, failure == 'begin' ? 0 : 1);
    });
  }

  for (final fail in [false, true]) {
    testWidgets('photo ${fail ? 'error' : 'cancel'} resumes same owner',
        (tester) async {
      final activity = RecordingActivity();
      final cover = Completer<void>();
      await pump(tester, activity,
          question: const Question(
              id: 'q',
              type: 3,
              content: 'Subjective',
              options: '[]',
              answer: 'answer',
              createdAt: 1,
              bankName: 'synthetic'), photo: (_, __, ___) async {
        await cover.future;
        if (fail) throw StateError('synthetic capture failure');
        return null;
      });
      await tester.tap(find.text('拍照作答'));
      await tester.pump();
      expect(activity.events, ['pause']);
      cover.complete();
      await tester.pumpAndSettle();
      expect(activity.events, ['pause', 'resume']);
      expect(activity.begins, hasLength(1));
      expect(activity.ends, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
