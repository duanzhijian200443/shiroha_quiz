import 'package:flutter/widgets.dart';

import '../../application/generated_question/generated_local_authority.dart';
import '../../application/generated_question/generated_question_service.dart';
import '../../application/modules/module_composition.dart';

/// Explicit first-party dependencies; no Agent/MCP authority projection.
final class GeneratedQuestionDependenciesScope extends InheritedWidget {
  const GeneratedQuestionDependenciesScope(
      {super.key,
      required this.authority,
      required this.service,
      this.contributions = const [],
      this.onCommitted,
      required super.child});
  final GeneratedLocalAuthorityFactory authority;
  final GeneratedQuestionService service;
  final List<ModuleUiContribution> contributions;
  final VoidCallback? onCommitted;

  static GeneratedQuestionDependenciesScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<
          GeneratedQuestionDependenciesScope>();

  @override
  bool updateShouldNotify(GeneratedQuestionDependenciesScope oldWidget) =>
      authority != oldWidget.authority ||
      service != oldWidget.service ||
      contributions != oldWidget.contributions ||
      onCommitted != oldWidget.onCommitted;
}
