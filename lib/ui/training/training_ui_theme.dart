import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Training layout uses the active appearance rather than a grayscale override.
class TrainingUiTheme extends StatelessWidget {
  const TrainingUiTheme({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = AppTheme.withPresetFallback(Theme.of(context));
    return Theme(
      data: base.copyWith(
        sliderTheme: base.sliderTheme.copyWith(
          thumbColor: base.colorScheme.surface,
          trackHeight: 7,
          showValueIndicator: ShowValueIndicator.onlyForDiscrete,
        ),
      ),
      child: child,
    );
  }
}
