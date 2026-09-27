import 'package:flutter/widgets.dart';
import '../../application/answer_completion/answer_completion_query.dart';
import '../../application/answer_completion/answer_completion_supplemental.dart';
import '../../application/answers/ai_answer_commit_command.dart';
import '../../application/answers/ai_answer_generation.dart';
import '../../application/supplemental_answers/supplemental_answer_command.dart';
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
      required super.child});

  final AnswerCompletionQuery query;
  final AnswerCompletionSupplementalService? supplemental;
  final SupplementalAnswerConfirmCommand? confirmCommand;
  final AiAnswerGenerationService? generationService;
  final AiAnswerCommitCommand? aiCommitCommand;
  final SupplementalAnswerFilePicker? pickFile;

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
      pickFile != oldWidget.pickFile;
}
