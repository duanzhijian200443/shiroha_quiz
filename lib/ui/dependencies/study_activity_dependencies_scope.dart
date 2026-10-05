import 'package:flutter/widgets.dart';

import '../../application/study_activity/study_activity_contracts.dart';

final class StudyActivityDependencies {
  const StudyActivityDependencies({required this.service, required this.query});
  final StudyActivityService service;
  final StudyActivityQuery query;
}

class StudyActivityDependenciesScope extends InheritedWidget {
  const StudyActivityDependenciesScope({
    super.key,
    required this.dependencies,
    required super.child,
  });
  final StudyActivityDependencies dependencies;

  static StudyActivityDependencies? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<StudyActivityDependenciesScope>()
      ?.dependencies;

  @override
  bool updateShouldNotify(StudyActivityDependenciesScope oldWidget) =>
      !identical(dependencies, oldWidget.dependencies);
}
