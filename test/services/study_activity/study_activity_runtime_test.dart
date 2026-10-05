import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_contracts.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_persistence.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_transition_engine.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_service_impl.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';
import 'package:shiroha_quiz/services/study_activity/study_activity_runtime.dart';
import 'package:shiroha_quiz/services/study_activity/system_study_activity_time_source.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/ui/dependencies/study_activity_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/pages/practice_page.dart';
import 'package:shiroha_quiz/ui/pages/mock_exam_screen.dart';
import 'package:shiroha_quiz/ui/study_activity/study_activity_route_binding.dart';
import '../../support/activity_widget_dependencies.dart';
import '../../support/study_activity_time_fakes.dart';

class _Persistence extends Fake implements StudyActivityPersistence {
  final admissions = <StudyActivityTransition>[];
  final commits = <StudyActivityTransition>[];
  int recoveries = 0;
  final events = <String>[];
  Completer<HomeTrainingResult<int>>? hold;
  @override
  Future<HomeTrainingResult<int>> recoverInterruptedSessions() async {
    recoveries++;
    events.add('recover');
    return await hold?.future ?? const HomeTrainingSuccess(0);
  }

  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> createSession(
      StudyActivityTransition proposal) async {
    events.add('begin');
    admissions.add(proposal);
    return HomeTrainingSuccess(proposal.snapshot);
  }

  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> commitTransition(
      StudyActivityRuntimeState previous,
      StudyActivityTransition proposal) async {
    commits.add(proposal);
    return HomeTrainingSuccess(proposal.snapshot);
  }
}

class _Exam extends Fake implements ExamMutationPersistencePort {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  StudyActivityBeginRequest request() => StudyActivityBeginRequest(
      scene: StudyActivityScene.ordinaryPractice,
      ownerToken: 'route',
      context: const StudyActivityContext());
  final time = FakeActivityTimeSource(StudyActivityTimeSample(
      monotonicMs: 0,
      utcMs: utcMs('2026-10-05T10:00:00Z'),
      mapping: FakeActivityMapping(0)));
  for (final jitter in [1, 15, 156, 1000, 1001, -1000, -1001]) {
    test('system source jitter $jitter preserves durable recording', () async {
      var monotonic = 0;
      final start = DateTime.utc(2026, 10, 5, 12).millisecondsSinceEpoch;
      var wall = start;
      final source = SystemStudyActivityTimeSource(
          monotonicMs: () => monotonic,
          utcNow: () => DateTime.fromMillisecondsSinceEpoch(wall, isUtc: true),
          localAt: (instant) => (
                localDate:
                    DateTime.fromMillisecondsSinceEpoch(instant, isUtc: true)
                        .toIso8601String()
                        .substring(0, 10),
                offsetMinutes: 0
              ));
      final persistence = _Persistence();
      final service = await createStudyActivityRuntime(
          persistence: persistence,
          timeSource: source,
          sessionIdFactory: () => 'session');
      final admitted = await service.begin(request());
      final owner = (admitted as HomeTrainingSuccess<StudyActivityOwner>).value;
      final originalMapping =
          persistence.admissions.single.state.lastSample.mapping;
      monotonic += 30000;
      wall += 30000 + jitter;
      final observed = source.sample();
      final jumped = jitter.abs() > 1000;
      expect(observed.mappingRevision, jumped ? 1 : 0);
      expect(observed.utcMs - start, jumped ? 30000 + jitter : 30000);
      if (!jumped) expect(identical(observed.mapping, originalMapping), isTrue);
      final checkpoint = await service.checkpoint(owner);
      expect(checkpoint, isA<HomeTrainingSuccess<StudyActivitySnapshot>>());
      expect(
          persistence.commits.single.segments
              .fold<int>(0, (n, s) => n + s.durationMs),
          30000);
      monotonic += 30000;
      wall += 30000;
      final continued = await service.checkpoint(owner);
      expect(continued, isA<HomeTrainingSuccess<StudyActivitySnapshot>>());
      final snapshot =
          (continued as HomeTrainingSuccess<StudyActivitySnapshot>).value;
      expect(snapshot.lifecycle.status, StudyActivityLifecycleStatus.active);
      expect(snapshot.recordingQuality,
          StudyActivityRecordingQuality.recordedOnly);
      expect(snapshot.checkpointSequence, 2);
      expect(persistence.commits, hasLength(2));
      expect(
          persistence.commits
              .expand((t) => t.segments)
              .fold<int>(0, (n, s) => n + s.durationMs),
          60000);
    });
  }
  testWidgets(
      'one production runtime injects Practice and Exam after one startup recovery',
      (tester) async {
    const channel =
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(channel,
        (_) async => const StandardMessageCodec().encodeMessage([null]));
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMessageHandler(channel, null));
    final persistence = _Persistence();
    var ids = 0;
    final service = await createStudyActivityRuntime(
        persistence: persistence,
        timeSource: time,
        sessionIdFactory: () => 'session-${++ids}');
    final dependencies =
        StudyActivityDependencies(service: service, query: service);
    Widget composed(Widget page) => StudyActivityDependenciesScope(
        dependencies: dependencies,
        child: activityWidgetDependencies(
            exam: _Exam(), child: MaterialApp(home: page)));
    ReviewEngineService().initPreparedStudySession(const [
      LegacyPersistedQuestion(
          question: Question(
              id: 'q',
              type: 0,
              content: 'Composed Practice',
              options: '["A. one"]',
              answer: 'A',
              createdAt: 1,
              bankName: 'synthetic'))
    ]);
    await tester.pumpWidget(composed(const PracticePage(
        usePreparedStudySession: true,
        studyActivity: StudyActivityRouteDescriptor(
            scene: StudyActivityScene.ordinaryPractice,
            context: StudyActivityContext(bankName: 'synthetic')))));
    await tester.pumpAndSettle();
    expect(persistence.admissions.single.snapshot.scene,
        StudyActivityScene.ordinaryPractice);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(composed(
        const MockExamScreen(paperId: 'paper', durationMinutes: 1, questions: [
      {'content': 'Composed Exam', 'type': 0, 'options': '[]'}
    ])));
    await tester.pumpAndSettle();
    expect(persistence.admissions, hasLength(2));
    expect(persistence.admissions.last.snapshot.scene,
        StudyActivityScene.mockExam);
    expect(persistence.admissions.last.state.context.paperId, 'paper');
    expect(persistence.recoveries, 1);
    expect(identical(dependencies.service, dependencies.query), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  test('composition waits for one recovery before exposing durable runtime',
      () async {
    final persistence = _Persistence()..hold = Completer();
    var exposed = false;
    final pending = createStudyActivityRuntime(
        persistence: persistence,
        timeSource: time,
        currentLocalDate: () => '2026-10-05',
        sessionIdFactory: () => 'fresh').then((s) {
      exposed = true;
      return s;
    });
    await Future<void>.delayed(Duration.zero);
    expect(exposed, isFalse);
    persistence.hold!.complete(const HomeTrainingSuccess(2));
    final service = await pending;
    expect(service, isA<PersistentStudyActivityService>());
    expect(await service.begin(request()),
        isA<HomeTrainingSuccess<StudyActivityOwner>>());
    expect(persistence.events, ['recover', 'begin']);
    expect(persistence.recoveries, 1);
  });
  test('failed startup recovery exposes unavailable Activity without throwing',
      () async {
    final persistence = _Persistence()..hold = Completer();
    persistence.hold!
        .complete(const HomeTrainingFailed(HomeTrainingFailure.unavailable));
    final service = await createStudyActivityRuntime(
        persistence: persistence, timeSource: time);
    expect(await service.begin(request()),
        isA<HomeTrainingFailed<StudyActivityOwner>>());
    expect(persistence.events, ['recover']);
    final next = await createStudyActivityRuntime(
        persistence: _Persistence(), timeSource: time);
    expect(identical(service, next), isFalse);
  });
}
