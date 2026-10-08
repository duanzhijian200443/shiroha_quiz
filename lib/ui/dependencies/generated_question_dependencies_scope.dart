import 'package:flutter/widgets.dart';

import '../../application/generated_question/generated_local_authority.dart';
import '../../application/generated_question/generated_question_service.dart';

/// Explicit first-party dependencies; no Agent/MCP authority projection.
final class GeneratedQuestionDependenciesScope extends InheritedWidget {
  const GeneratedQuestionDependenciesScope(
      {super.key,
      required this.authority,
      required this.service,
      required super.child});
  final GeneratedLocalAuthorityFactory authority;
  final GeneratedQuestionService service;

  static GeneratedQuestionDependenciesScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<
          GeneratedQuestionDependenciesScope>();

  @override
  bool updateShouldNotify(GeneratedQuestionDependenciesScope oldWidget) =>
      authority != oldWidget.authority || service != oldWidget.service;
}
