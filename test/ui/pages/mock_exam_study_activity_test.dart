import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';
import 'package:shiroha_quiz/ui/dependencies/study_activity_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/pages/mock_exam_screen.dart';
import '../../support/activity_widget_dependencies.dart';
import '../../support/study_activity_runtime_fakes.dart';

class _Exam extends Fake implements ExamMutationPersistencePort {
  int calls = 0;
  int graded = 0;
  bool fail = false;
  bool subjective = false;
  Completer<void>? hold;
  @override
  Future<List<Map<String, dynamic>>> submitExamPaper(String id,
      Map<int, dynamic> answers, List<Map<String, dynamic>> questions) async {
    calls++;
    await hold?.future;
    if (fail) throw StateError('synthetic submit failure');
    return subjective
        ? [
            {'qId': 'q', 'question': 'stem', 'sAns': 'answer', 'uAns': 'user'}
          ]
        : [];
  }

  @override
  Future<void> updateExamAiScore(
          String paper, String question, String feedback, double score) async =>
      graded++;
  @override
  Future<void> finishExamGrading(String paper) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const wakeChannel =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakeChannel,
            (_) async => const StandardMessageCodec().encodeMessage([null]));
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakeChannel, null);
  });

  Future<void> pump(WidgetTester tester, RecordingActivity activity, _Exam exam,
      {int minutes = 1, RecordingExamAi? ai}) async {
    await tester.pumpWidget(StudyActivityDependenciesScope(
        dependencies:
            StudyActivityDependencies(service: activity, query: activity),
        child: activityWidgetDependencies(
            exam: exam,
            ai: ai,
            child: MaterialApp(
                home: Builder(
                    builder: (context) => Scaffold(
                        body: TextButton(
                            onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                    builder: (_) => MockExamScreen(
                                            paperId: 'paper',
                                            durationMinutes: minutes,
                                            questions: const [
                                              {
                                                'id': 'q',
                                                'type': 0,
                                                'content': 'Synthetic exam',
                                                'options': '["A. one","B. two"]'
                                              }
                                            ]))),
                            child: const Text('open exam'))))))));
    await tester.tap(find.text('open exam'));
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.text('交卷'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认交卷'));
    await tester.pump();
  }

  testWidgets(
      'mock scene/paper; background pauses Activity and countdown keeps ticking',
      (tester) async {
    final activity = RecordingActivity();
    await pump(tester, activity, _Exam());
    expect(activity.begins.single.scene, StudyActivityScene.mockExam);
    expect(activity.begins.single.context.paperId, 'paper');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('00:58'), findsOneWidget);
    expect(activity.events, ['pause']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(activity.events, ['pause', 'resume']);
    expect(activity.ends, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(activity.ends.single.reason, StudyActivityEndReason.exited);
  });

  testWidgets('confirm cancel resumes same owner and preserves exam',
      (tester) async {
    final activity = RecordingActivity();
    final exam = _Exam();
    await pump(tester, activity, exam);
    await tester.tap(find.text('交卷'));
    await tester.pumpAndSettle();
    expect(activity.events, ['pause']);
    await tester.tap(find.text('继续检查'));
    await tester.pumpAndSettle();
    expect(activity.events, ['pause', 'resume']);
    expect(activity.ends, isEmpty);
    expect(exam.calls, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
      'failed durable submit remains nonterminal; retry succeeds before end',
      (tester) async {
    final activity = RecordingActivity();
    final exam = _Exam()..fail = true;
    await pump(tester, activity, exam);
    await confirm(tester);
    await tester.pumpAndSettle();
    expect(activity.ends, isEmpty);
    expect(activity.events.last, 'resume');
    expect(find.byType(MockExamScreen), findsOneWidget);
    int remaining() {
      final text = tester
          .widget<Text>(find.byWidgetPredicate((widget) =>
              widget is Text &&
              RegExp(r'^\d{2}:\d{2}$').hasMatch(widget.data ?? '')))
          .data!;
      final parts = text.split(':').map(int.parse).toList();
      return parts[0] * 60 + parts[1];
    }

    final before = remaining();
    expect(before, greaterThan(3));
    await tester.pump(const Duration(seconds: 3));
    expect(remaining(), before - 3);
    expect(exam.calls, 1);
    exam.fail = false;
    exam.hold = Completer();
    await confirm(tester);
    await tester.pump();
    expect(activity.ends, isEmpty);
    expect(exam.calls, 2);
    exam.hold!.complete();
    await tester.pumpAndSettle();
    expect(activity.ends.single.reason, StudyActivityEndReason.submitted);
    expect(find.byType(MockExamScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final failure in ['begin', 'end']) {
    testWidgets(
        '$failure Activity failure preserves successful exit and background grading',
        (tester) async {
      final activity = RecordingActivity()..failures.add(failure);
      final exam = _Exam()..subjective = true;
      final ai = RecordingExamAi();
      await pump(tester, activity, exam, ai: ai);
      await confirm(tester);
      await tester.pumpAndSettle();
      expect(find.byType(MockExamScreen), findsNothing);
      expect(exam.calls, 1);
      expect(exam.graded, 1);
      expect(ai.calls, 1);
      expect(activity.ends.length, failure == 'begin' ? 0 : 1);
      if (failure == 'end') {
        expect(activity.ends.single.reason, StudyActivityEndReason.submitted);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final fail in [false, true]) {
    testWidgets(
        'force submit ${fail ? 'failure' : 'success'} uses durable terminal semantics',
        (tester) async {
      final activity = RecordingActivity();
      final exam = _Exam()..fail = fail;
      await pump(tester, activity, exam, minutes: 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(exam.calls, 1);
      if (fail) {
        expect(activity.ends, isEmpty);
        expect(activity.events.last, 'resume');
        expect(find.byType(MockExamScreen), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
        expect(find.text('00:00'), findsOneWidget);
        expect(exam.calls, 1);
        expect(activity.ends, isEmpty);
      } else {
        expect(activity.ends.single.reason, StudyActivityEndReason.submitted);
        expect(find.byType(MockExamScreen), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
