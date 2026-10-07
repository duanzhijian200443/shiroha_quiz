import 'package:flutter/material.dart';
import '../../application/training/training_contracts.dart';
import '../training/training_visuals.dart';
import '../theme/app_theme.dart';
import '../theme/shiroha_theme_tokens.dart';

/// Decorative category art; an explicit saved preference always wins.
class TodayCategoryVisual extends StatelessWidget {
  const TodayCategoryVisual({super.key, this.visualKey, required this.label});
  final CategoryVisualKey? visualKey;
  final String label;

  @override
  Widget build(BuildContext context) {
    final inferred = RegExp(r'数学|高数|线代|math', caseSensitive: false)
            .hasMatch(label)
        ? CategoryVisualKey.math
        : RegExp(r'英语|英文|english', caseSensitive: false).hasMatch(label)
            ? CategoryVisualKey.english
            : RegExp(r'计算机|编程|computer', caseSensitive: false).hasMatch(label)
                ? CategoryVisualKey.computerScience
                : CategoryVisualKey.genericLearning;
    final visual = visualKey ?? inferred;
    final colors = Theme.of(context).colorScheme;
    final tokens = AppTheme.withPresetFallback(Theme.of(context))
        .extension<ShirohaThemeTokens>()!;
    final colorful = tokens.appearance == ShirohaAppearance.colorful;
    final dark = tokens.appearance == ShirohaAppearance.dark;
    final asset = switch (visual) {
      CategoryVisualKey.math => 'assets/images/today/category-math-v3.png',
      CategoryVisualKey.english => 'assets/images/today/category-english.png',
      _ => 'assets/images/today/paper-pencil.png',
    };
    return Semantics(
      image: true,
      label: '$label分类视觉：${trainingVisualLabel(visual)}',
      child: ExcludeSemantics(
          child: Stack(fit: StackFit.expand, children: [
        Align(
          alignment: Alignment.bottomRight,
          child: FractionallySizedBox(
            widthFactor: 1,
            heightFactor: 1,
            child: Builder(builder: (_) {
              final image = Image.asset(asset,
                  fit: BoxFit.cover,
                  alignment: Alignment.bottomRight,
                  color: dark ? tokens.categoryArtworkTint : null,
                  colorBlendMode: dark ? BlendMode.modulate : null);
              return colorful
                  ? ColorFiltered(
                      colorFilter: tokens.illustrationFilter, child: image)
                  : image;
            }),
          ),
        ),
        DecoratedBox(
            decoration: BoxDecoration(
                gradient: LinearGradient(
          colors: [
            colors.surfaceContainerHighest.withValues(alpha: .95),
            colors.surfaceContainerHighest.withValues(alpha: .8),
            colors.surfaceContainerHighest.withValues(alpha: 0)
          ],
          stops: const [0, .30, .76],
        ))),
        if (visual == CategoryVisualKey.computerScience)
          Align(
              alignment: const Alignment(.65, -.25),
              child: Icon(Icons.code_rounded,
                  size: 48, color: colors.onSurfaceVariant)),
      ])),
    );
  }
}
