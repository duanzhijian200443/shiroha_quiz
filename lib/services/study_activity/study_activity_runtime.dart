import 'package:uuid/uuid.dart';

import '../../application/study_activity/study_activity_persistence.dart';
import '../../application/study_activity/study_activity_service_impl.dart';
import '../../application/study_activity/study_activity_transition_engine.dart';
import 'system_study_activity_time_source.dart';

/// Called once per composition, after B0 recovery and DB readiness. A failed
/// recovery leaves Activity unavailable; core learning can still start.
Future<PersistentStudyActivityService> createStudyActivityRuntime({
  required StudyActivityPersistence persistence,
  StudyActivityTimeSource? timeSource,
  String Function()? currentLocalDate,
  String Function()? sessionIdFactory,
}) async {
  final system = SystemStudyActivityTimeSource();
  final service = PersistentStudyActivityService(
      engine: StudyActivityTransitionEngine(
          timeSource: timeSource ?? system,
          sessionIdFactory: sessionIdFactory ?? const Uuid().v4),
      persistence: persistence,
      currentLocalDate: currentLocalDate ?? system.currentLocalDate);
  await service.recoverAtStartup();
  return service;
}
