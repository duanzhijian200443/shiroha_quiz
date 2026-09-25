import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';

import '../../application/supplemental_answers/supplemental_answer_activation_service.dart';
import '../../application/supplemental_answers/supplemental_answer_command.dart';
import '../../application/supplemental_answers/supplemental_answer_source_acquisition_service.dart';

/// The system picker seam of the supplemental-answer entry.
///
/// Presentation owns this platform call; a composition may inject a test
/// double instead of the real `FilePicker`.
typedef SupplementalAnswerFilePicker = Future<FilePickerResult?> Function();

/// Presentation dependency carrier for the P6 supplemental-answer activation.
///
/// It exposes only the Application-facing seams: the existing-file activation
/// service, the direct-source acquisition service, and the confirm command.
/// Screens that do not find this scope keep rendering without the P6 entry, so
/// the capability stays off for compositions that do not configure it.
final class SupplementalAnswerDependenciesScope extends InheritedWidget {
  const SupplementalAnswerDependenciesScope({
    super.key,
    required this.activationService,
    required this.sourceAcquisitionService,
    required this.confirmCommand,
    this.pickFile,
    required super.child,
  });

  final SupplementalAnswerActivationService activationService;
  final SupplementalAnswerSourceAcquisitionService sourceAcquisitionService;
  final SupplementalAnswerConfirmCommand confirmCommand;
  final SupplementalAnswerFilePicker? pickFile;

  static SupplementalAnswerDependenciesScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<
        SupplementalAnswerDependenciesScope>();
  }

  @override
  bool updateShouldNotify(SupplementalAnswerDependenciesScope oldWidget) {
    return !identical(activationService, oldWidget.activationService) ||
        !identical(
            sourceAcquisitionService, oldWidget.sourceAcquisitionService) ||
        !identical(confirmCommand, oldWidget.confirmCommand) ||
        !identical(pickFile, oldWidget.pickFile);
  }
}
