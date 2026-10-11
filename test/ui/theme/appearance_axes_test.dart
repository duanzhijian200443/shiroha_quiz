import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/ui/theme/shiroha_theme_tokens.dart';
import 'package:shiroha_quiz/ui/home/today_visual_theme.dart';
import 'package:shiroha_quiz/ui/training/training_ui_theme.dart';

void main() {
  for (final style in ShirohaThemeStyle.values) {
    for (final brightness in Brightness.values) {
      final appearance =
          ShirohaAppearance(style: style, mode: ShirohaDisplayMode.system);
      testWidgets('$style / $brightness preserves tokens and local themes',
          (tester) async {
        final theme = AppTheme.themeFor(appearance, brightness);
        final tokens = theme.extension<ShirohaThemeTokens>()!;
        expect(tokens.appearance, appearance);
        expect(tokens.style, style);
        expect(tokens.brightness, brightness);
        expect(tokens.colors, theme.colorScheme);
        expect(tokens.canvas, theme.scaffoldBackgroundColor);
        expect(tokens.textPrimary, theme.textTheme.bodyMedium!.color);
        expect(tokens.surface, theme.cardTheme.color);
        expect(tokens.primaryAction, theme.primaryColor);
        expect(tokens.icon, theme.iconTheme.color);
        expect(tokens.subtleFill, theme.inputDecorationTheme.fillColor);
        expect(tokens.divider, theme.dividerTheme.color);
        expect(tokens.primaryAction,
            theme.bottomNavigationBarTheme.selectedItemColor);
        expect(theme.brightness, brightness);
        expect(todayVisualTheme(theme).extension<ShirohaThemeTokens>(), tokens);
        late ThemeData local;
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          themeMode: ThemeMode.light,
          home: TrainingUiTheme(child: Builder(builder: (context) {
            local = Theme.of(context);
            return const SizedBox();
          })),
        ));
        expect(local.extension<ShirohaThemeTokens>(), tokens);
        expect(local.colorScheme, theme.colorScheme);
        final compatibility = style == ShirohaThemeStyle.colorful &&
                brightness == Brightness.light
            ? AppTheme.colorfulTheme
            : brightness == Brightness.dark
                ? AppTheme.darkTheme
                : AppTheme.lightTheme;
        expect(theme.colorScheme, compatibility.colorScheme);
        expect(
            tokens.assistantActionBackground,
            compatibility
                .extension<ShirohaThemeTokens>()!
                .assistantActionBackground);
      });
    }
  }

  test('mode is independent of style and maps to native ThemeMode', () {
    for (final style in ShirohaThemeStyle.values) {
      for (final mode in ShirohaDisplayMode.values) {
        final appearance = ShirohaAppearance(style: style, mode: mode);
        expect(
            AppTheme.themeMode(appearance), ThemeMode.values.byName(mode.name));
        expect(ShirohaAppearance.fromJson(appearance.toJson()), appearance);
        expect(appearance.copyWith(mode: ShirohaDisplayMode.dark).style, style);
      }
    }
  });
}
