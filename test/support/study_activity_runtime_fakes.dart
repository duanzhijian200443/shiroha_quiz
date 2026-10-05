import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_contracts.dart';
import 'package:shiroha_quiz/domain/study_activity/study_activity_values.dart';

class RecordingActivity extends Fake
    implements StudyActivityService, StudyActivityQuery {
  final begins = <StudyActivityBeginRequest>[];
  final events = <String>[];
  final owners = <StudyActivityOwner>[];
  final ends = <StudyActivityEndRequest>[];
  final failures = <String>{};
  Completer<HomeTrainingResult<StudyActivityOwner>>? beginHold;
  Completer<HomeTrainingResult<StudyActivitySnapshot>>? checkpointHold;

  StudyActivitySnapshot snapshot() => StudyActivitySnapshot(
      sessionId: 'session',
      scene: StudyActivityScene.ordinaryPractice,
      lifecycle: StudyActivityLifecycle(
          status: StudyActivityLifecycleStatus.active,
          endedAtUtcMs: null,
          endReason: null),
      lastCheckpointAtUtcMs: 1,
      checkpointSequence: 0,
      revision: 1,
      recordingQuality: StudyActivityRecordingQuality.recordedOnly);

  Future<HomeTrainingResult<StudyActivitySnapshot>> event(
      String name, StudyActivityOwner owner) async {
    events.add(name);
    owners.add(owner);
    if (failures.contains(name)) throw StateError('synthetic Activity failure');
    return HomeTrainingSuccess(snapshot());
  }

  @override
  Future<HomeTrainingResult<StudyActivityOwner>> begin(
      StudyActivityBeginRequest request) async {
    begins.add(request);
    if (failures.contains('begin')) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
    return await beginHold?.future ??
        HomeTrainingSuccess(StudyActivityOwner(
            sessionId: 'session', ownerToken: request.ownerToken));
  }

  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> pause(
          StudyActivityOwner owner) =>
      event('pause', owner);
  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> resume(
          StudyActivityOwner owner) =>
      event('resume', owner);
  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> checkpoint(
      StudyActivityOwner owner) async {
    final result = await event('checkpoint', owner);
    return await checkpointHold?.future ?? result;
  }

  @override
  Future<HomeTrainingResult<StudyActivitySnapshot>> end(
      StudyActivityEndRequest request) {
    ends.add(request);
    return event('end', request.owner);
  }
}
