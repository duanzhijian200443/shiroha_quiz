import '../../application/training/today_training_contracts.dart';
import '../../application/training/training_configuration_contracts.dart';
import '../../application/training/training_contracts.dart';
import '../../application/training/training_session_contracts.dart';

/// Composition supplies Application ports only, shared with the B2 config UI.
final class HomeTrainingDependencies {
  const HomeTrainingDependencies(
      {required this.today,
      required this.contentQuery,
      required this.command,
      required this.configurationQuery,
      required this.orderCommand,
      required this.session});
  final TodayTrainingQuery today;
  final TrainingContentQuery contentQuery;
  final TrainingContentCommand command;
  final TrainingConfigurationQuery configurationQuery;
  final TrainingContentOrderCommand orderCommand;
  final TrainingSessionApplicationService session;
}
