import 'package:flutter/widgets.dart';

import '../../application/supplemental_answers/supplemental_answer_activation_service.dart';
import '../../application/supplemental_answers/supplemental_answer_command.dart';

/// Presentation dependency carrier for the P6 supplemental-answer activation.
///
/// It exposes only the Application-facing activation service and confirm
/// command. Screens that do not find this scope keep rendering without the P6
/// entry, so the capability stays off for compositions that do not configure
/// it.
final class SupplementalAnswerDependenciesScope extends InheritedWidget {
  const SupplementalAnswerDependenciesScope({
    super.key,
    required this.activationService,
    required this.confirmCommand,
    required super.child,
  });

  final SupplementalAnswerActivationService activationService;
  final SupplementalAnswerConfirmCommand confirmCommand;

  static SupplementalAnswerDependenciesScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<
        SupplementalAnswerDependenciesScope>();
  }

  @override
  bool updateShouldNotify(SupplementalAnswerDependenciesScope oldWidget) {
    return !identical(activationService, oldWidget.activationService) ||
        !identical(confirmCommand, oldWidget.confirmCommand);
  }
}
