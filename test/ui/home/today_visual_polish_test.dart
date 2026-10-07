import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/home/today_category_visual.dart';
import 'package:shiroha_quiz/ui/home/today_visual_theme.dart';
import 'package:shiroha_quiz/ui/home/today_welcome_banner.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/ui/theme/shiroha_theme_tokens.dart';
import 'package:shiroha_quiz/ui/widgets/shiroha_icons.dart';

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return ((a > b ? a : b) + .05) / ((a > b ? b : a) + .05);
}

void main() {
  test('colorful primary is muted blue without a violet or cyan cast', () {
    final tokens = AppTheme.colorfulTheme.extension<ShirohaThemeTokens>()!;
    final accent = HSLColor.fromColor(tokens.icon);
    expect(accent.hue, inInclusiveRange(200, 220));
    expect(accent.saturation, lessThan(.25));
    expect(_contrast(tokens.icon, tokens.surface), greaterThanOrEqualTo(4.5));
    expect(_contrast(tokens.textSecondary, tokens.subtleFill),
        greaterThanOrEqualTo(4.5));
  });

  for (final name in ['light', 'dark', 'colorful']) {
    testWidgets('$name uses one themed glyph color and exact 24-pixel canvas',
        (tester) async {
      final theme = todayVisualTheme(AppTheme.getTheme(name));
      final buttonColor = theme.iconButtonTheme.style!.foregroundColor!
          .resolve(<WidgetState>{})!;
      await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(
              body: Row(children: [
            for (final glyph in ShirohaGlyph.values)
              IconButton(
                onPressed: () {},
                icon: ShirohaIcon(glyph, key: ValueKey(glyph)),
              ),
          ]))));
      for (final glyph in ShirohaGlyph.values) {
        final finder = find.byKey(ValueKey(glyph));
        expect(tester.getSize(finder), const Size(24, 24));
        final paint = tester.widget<CustomPaint>(
            find.descendant(of: finder, matching: find.byType(CustomPaint)));
        expect((paint.painter! as ShirohaIconPainter).color, buttonColor);
        expect(
            tester.renderObject(find.descendant(
                of: finder, matching: find.byType(CustomPaint))),
            paints
              ..path(
                  color: buttonColor,
                  strokeWidth: 1.5,
                  style: PaintingStyle.stroke));
      }
    });

    testWidgets('$name banner and category retain geometry with themed tones',
        (tester) async {
      final theme = todayVisualTheme(AppTheme.getTheme(name));
      final tokens = theme.extension<ShirohaThemeTokens>()!;
      final bannerTokens = name == 'colorful'
          ? tokens
          : AppTheme.lightTheme.extension<ShirohaThemeTokens>()!;
      await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(
              body: Column(children: [
            SizedBox(
                width: 360,
                child: TodayWelcomeBanner(now: DateTime(2026, 10, 7, 15))),
            const SizedBox(
                width: 300,
                height: 180,
                child: TodayCategoryVisual(label: '数学')),
          ]))));
      expect(tester.getSize(find.byKey(const ValueKey('home-welcome-banner'))),
          const Size(360, 151.2));
      expect(tester.getSize(find.byType(TodayCategoryVisual)),
          const Size(300, 180));
      for (final filtered
          in tester.widgetList<ColorFiltered>(find.byType(ColorFiltered))) {
        expect(filtered.colorFilter, tokens.illustrationFilter);
      }
      expect(find.byType(ColorFiltered),
          name == 'colorful' ? findsNWidgets(2) : findsNothing);
      expect(tester.widget<Text>(find.text('下午好')).style!.color,
          bannerTokens.textPrimary);
      expect(tester.widget<Text>(find.text('今天也继续加油吧！')).style!.color,
          bannerTokens.welcomeCaption);
      expect(tester.widget<Text>(find.text('保持学习，慢慢进步')).style!.color,
          bannerTokens.welcomePillText);
      final canvas = todayCardDecoration(theme);
      expect(canvas.border, isNull,
          reason: 'outline must not add layout padding');
      expect(todayCardOutline(theme).border,
          Border.all(color: tokens.cardOutline));
      expect(canvas.boxShadow!.isEmpty, name == 'dark');
      expect(tester.takeException(), isNull);
    });
  }

  test('neutral themes retain original colors and native interaction styles',
      () {
    for (final name in ['light', 'dark']) {
      final base = AppTheme.getTheme(name);
      final local = todayVisualTheme(base);
      expect(local.colorScheme, base.colorScheme);
      expect(local.scaffoldBackgroundColor, base.scaffoldBackgroundColor);
      expect(local.hoverColor, base.hoverColor);
      expect(local.highlightColor, base.highlightColor);
      expect(local.focusColor, base.focusColor);
      expect(local.iconButtonTheme, base.iconButtonTheme);
      expect((local.cardTheme.shape! as RoundedRectangleBorder).side,
          BorderSide.none);
      expect(local.colorScheme.primary,
          name == 'light' ? const Color(0xFF545864) : const Color(0xFFD2D4DC));
      expect(local.colorScheme.onSurfaceVariant,
          name == 'light' ? const Color(0xFF6B6D76) : const Color(0xFFB4B5BE));
      final tokens = local.extension<ShirohaThemeTokens>()!;
      expect(tokens.welcomeCaption, const Color(0xFF747780));
      expect(tokens.welcomePillText, const Color(0xFF555760));
      if (name == 'light') {
        expect(todayCardDecoration(local).boxShadow!.single.color,
            const Color(0xFF375078).withValues(alpha: .06));
      } else {
        expect(tokens.categoryArtworkTint, const Color(0xFF85858D));
      }
    }
  });

  testWidgets('native tooltip, hover, press and keyboard focus preserve bounds',
      (tester) async {
    final theme = todayVisualTheme(AppTheme.colorfulTheme);
    final tokens = theme.extension<ShirohaThemeTokens>()!;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var calls = 0;
    const actionKey = ValueKey('polish-icon-action');
    await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
            body: Center(
                child: IconButton(
          key: actionKey,
          focusNode: focus,
          tooltip: '训练配置',
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          onPressed: () => calls++,
          icon: const ShirohaIcon(ShirohaGlyph.trainingConfiguration),
        )))));
    final finder = find.byKey(actionKey);
    final bounds = tester.getRect(finder);
    final style = theme.iconButtonTheme.style!;
    expect(style.overlayColor!.resolve({WidgetState.hovered}),
        tokens.hoverOverlay);
    expect(style.overlayColor!.resolve({WidgetState.pressed}),
        tokens.pressedOverlay);
    expect(style.overlayColor!.resolve({WidgetState.focused}),
        tokens.focusOverlay);
    expect(
        style.overlayColor!
            .resolve({WidgetState.disabled, WidgetState.hovered}),
        isNull);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(finder));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('训练配置'), findsOneWidget);
    expect(tester.getRect(finder), bounds);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    final press = await tester.startGesture(tester.getCenter(finder));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(finder), bounds);
    await press.up();
    await tester.pumpAndSettle();
    expect(calls, 1);
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(style.side!.resolve({WidgetState.focused})!.color, tokens.icon);
    expect(tester.getRect(finder), bounds);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(calls, 2);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });
}
