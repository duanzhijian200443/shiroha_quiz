import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/home/today_visual_theme.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/ui/theme/shiroha_theme_tokens.dart';
import 'package:shiroha_quiz/ui/training/training_ui_theme.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

void main() {
  for (final name in ['light', 'dark', 'colorful']) {
    test('$name maps to explicit appearance, semantic tokens and components',
        () {
      final theme = AppTheme.getTheme(name);
      final colors = theme.colorScheme;
      final tokens = theme.extension<ShirohaThemeTokens>()!;
      expect(tokens.appearance.name, name);
      expect(theme.brightness,
          name == 'dark' ? Brightness.dark : Brightness.light);
      expect(colors.brightness, theme.brightness);
      expect(tokens.canvas, theme.scaffoldBackgroundColor);
      expect(tokens.colors, colors);
      expect(tokens.surface, colors.surface);
      expect(tokens.textPrimary, colors.onSurface);
      expect(tokens.textSecondary, colors.onSurfaceVariant);
      expect(tokens.primaryAction, theme.primaryColor);
      expect(tokens.divider, theme.dividerTheme.color);
      expect(tokens.border, colors.outline);
      expect(tokens.subtleFill, theme.inputDecorationTheme.fillColor);
      expect(tokens.icon, theme.iconTheme.color);
      expect(tokens.iconBackground, colors.primaryContainer);
      expect(tokens.secondaryAction, colors.secondary);
      expect(tokens.selectedFill, colors.primaryContainer);
      expect(tokens.selectedForeground, colors.onPrimaryContainer);
      expect(tokens.disabledForeground, theme.disabledColor);
      expect(tokens.error, colors.error);
      expect(tokens.correct, tokens.success);
      expect(tokens.incorrect, tokens.error);
      expect(tokens.featureAi, colors.secondary);
      expect(tokens.featureAiFill, colors.secondaryContainer);
      expect(tokens.brandAccent, tokens.featureLibrary);
      expect(tokens.brandFill, tokens.featureLibraryFill);
      expect(tokens.featureNeutral, tokens.textSecondary);
      expect(tokens.featureNeutralFill, tokens.subtleFill);
      expect(
          contrast(tokens.assistantOnAction, tokens.assistantActionBackground),
          greaterThanOrEqualTo(4.5));
      expect(contrast(tokens.textPrimary, tokens.assistantCanvasStart),
          greaterThanOrEqualTo(4.5));
      expect(contrast(tokens.textSecondary, tokens.assistantCanvasEnd),
          greaterThanOrEqualTo(4.5));
      expect(tokens.assistantDrawerScrim.a, lessThan(.3));
      expect(tokens.assistantActionBackground,
          name == 'colorful' ? colors.primary : isNot(colors.primary));
      for (final pair in [
        (tokens.featureAi, tokens.featureAiFill),
        (tokens.featureLibrary, tokens.featureLibraryFill),
        (tokens.featureNeutral, tokens.featureNeutralFill),
      ]) {
        expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(3));
      }
      expect(theme.cardTheme.color, tokens.surface);
      expect(theme.appBarTheme.backgroundColor, tokens.canvas);
      expect(theme.dialogTheme.backgroundColor, tokens.surface);
      expect(theme.bottomSheetTheme.backgroundColor, tokens.surface);
      expect(theme.popupMenuTheme.color, tokens.surface);
      expect(theme.bottomNavigationBarTheme.selectedItemColor,
          tokens.primaryAction);
      expect(theme.bottomNavigationBarTheme.unselectedItemColor,
          tokens.textSecondary);
      expect(theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
          tokens.primaryAction);
      expect(
          theme.filledButtonTheme.style!.backgroundColor!
              .resolve({WidgetState.disabled}),
          tokens.disabledFill);
      for (final pair in [
        (colors.onSurface, colors.surface),
        (colors.onSurfaceVariant, colors.surface),
        (colors.onSurfaceVariant, tokens.canvas),
        (colors.primary, tokens.canvas),
        (colors.onPrimary, colors.primary),
        (colors.onSecondary, colors.secondary),
        (colors.onTertiary, colors.tertiary),
        (colors.onPrimaryContainer, colors.primaryContainer),
        (colors.onSecondaryContainer, colors.secondaryContainer),
        (colors.onTertiaryContainer, colors.tertiaryContainer),
        (colors.onError, colors.error),
        (tokens.success, colors.surface),
        (tokens.warning, colors.surface),
        (tokens.textSecondary, tokens.subtleFill),
      ]) {
        expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
      }
      if (name != 'colorful') {
        expect(colors.primary, colors.tertiary);
      }
      expect(colors.secondary, isNot(colors.primary));
      final local = todayVisualTheme(theme);
      expect(local.colorScheme, colors);
      expect(local.extension<ShirohaThemeTokens>(), tokens);
      expect(local.primaryColor, theme.primaryColor);
    });

    testWidgets('$name survives the training local theme', (tester) async {
      late ThemeData observed;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.getTheme(name),
        home: TrainingUiTheme(child: Builder(builder: (context) {
          observed = Theme.of(context);
          return const SizedBox();
        })),
      ));
      expect(observed.extension<ShirohaThemeTokens>()!.appearance.name, name);
      expect(observed.colorScheme, AppTheme.getTheme(name).colorScheme);
      expect(observed.scaffoldBackgroundColor,
          AppTheme.getTheme(name).scaffoldBackgroundColor);
    });
  }

  test('legacy, empty and invalid values fall back deterministically', () {
    for (final name in [null, '', 'morandi', 'unknown', ' DARK ', '{broken}']) {
      expect(AppTheme.normalizeName(name), 'light');
      expect(
          AppTheme.getTheme(name).colorScheme, AppTheme.lightTheme.colorScheme);
    }
    expect(AppTheme.colorfulTheme.brightness, AppTheme.lightTheme.brightness);
    expect(AppTheme.colorfulTheme.colorScheme,
        isNot(AppTheme.lightTheme.colorScheme));
  });

  test('extension interpolates all colors and preserves endpoints', () {
    final light = AppTheme.lightTheme.extension<ShirohaThemeTokens>()!;
    final dark = AppTheme.darkTheme.extension<ShirohaThemeTokens>()!;
    expect(light.copyWith().colors, light.colors);
    expect(light.lerp(dark, 0).canvas, light.canvas);
    expect(light.lerp(dark, 1).colors, dark.colors);
    expect(light.lerp(dark, 1).success, dark.success);
    expect(light.lerp(dark, 1).warning, dark.warning);
    expect(light.lerp(dark, 1).featureLibrary, dark.featureLibrary);
    expect(light.lerp(dark, 1).featureLibraryFill, dark.featureLibraryFill);
  });
}
