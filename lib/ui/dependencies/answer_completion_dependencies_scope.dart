import 'package:flutter/widgets.dart';
import '../../application/answer_completion/answer_completion_query.dart';
import '../../application/answer_completion/answer_completion_supplemental.dart';
import '../../application/answers/ai_answer_commit_command.dart';
import '../../application/answers/ai_answer_generation.dart';
import '../../application/supplemental_answers/supplemental_answer_command.dart';
import '../../application/supplemental_answers/supplemental_source_inspection.dart';
import 'supplemental_answer_dependencies_scope.dart';

final class AnswerCompletionDependenciesScope extends InheritedWidget {
  const AnswerCompletionDependenciesScope(
      {super.key,
      required this.query,
      this.supplemental,
      this.confirmCommand,
      this.generationService,
      this.aiCommitCommand,
      this.pickFile,
      this.sourceInspectionService,
      required super.child});

  final AnswerCompletionQuery query;
  final AnswerCompletionSupplementalService? supplemental;
  final SupplementalAnswerConfirmCommand? confirmCommand;
  final AiAnswerGenerationService? generationService;
  final AiAnswerCommitCommand? aiCommitCommand;
  final SupplementalAnswerFilePicker? pickFile;

  /// SV-C1 original-source inspection capability for the P6 review flow.
  /// Null keeps the review readable but the source-verification flow
  /// unavailable and every write closed; it is never a service locator.
  final SupplementalSourceInspectionService? sourceInspectionService;

  static AnswerCompletionDependenciesScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<
          AnswerCompletionDependenciesScope>();

  @override
  bool updateShouldNotify(AnswerCompletionDependenciesScope oldWidget) =>
      query != oldWidget.query ||
      supplemental != oldWidget.supplemental ||
      confirmCommand != oldWidget.confirmCommand ||
      generationService != oldWidget.generationService ||
      aiCommitCommand != oldWidget.aiCommitCommand ||
      pickFile != oldWidget.pickFile ||
      sourceInspectionService != oldWidget.sourceInspectionService;
}
