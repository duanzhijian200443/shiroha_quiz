import '../../application/home_training_result.dart';
import '../../application/study_query/study_query_time_zone.dart';
import '../../application/study_query/study_query_dtos.dart';
import '../../application/training/today_training_contracts.dart';
import '../../data/repositories/training_configuration_repository.dart';

/// Captures the clock once; configuration and counts share one repository read.
final class TodayTrainingQueryAdapter implements TodayTrainingQuery {
  TodayTrainingQueryAdapter({
    required this.configuration,
    required this.timeZone,
    required this.zoneName,
    DateTime Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().toUtc());

  final TrainingConfigurationRepository configuration;
  final StudyQueryTimeZone timeZone;
  final String zoneName;
  final DateTime Function() _clock;

  @override
  Future<HomeTrainingResult<TodayTrainingSnapshot>> readCurrent() async {
    try {
      final now = _clock().toUtc();
      final local = timeZone.localDateOf(now, zoneName);
      final start = timeZone.utcInstantOfLocalMidnight(local, zoneName);
      final next = DateTime.utc(local.year, local.month, local.day + 1);
      final end = timeZone.utcInstantOfLocalMidnight(
          StudyLocalDate(year: next.year, month: next.month, day: next.day),
          zoneName);
      return await configuration.readTodayTraining(
          capturedNow: now, dayStartUtc: start, dayEndUtc: end);
    } catch (_) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }
}
