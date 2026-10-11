import 'package:flutter/material.dart';
import 'design_tokens.dart';
import '../../domain/appearance/shiroha_appearance.dart';

export '../../domain/appearance/shiroha_appearance.dart';

/// Semantic colors shared by all appearances; layout stays in DesignTokens.
class ShirohaThemeTokens extends ThemeExtension<ShirohaThemeTokens> {
  const ShirohaThemeTokens({
    required this.appearance,
    required this.colors,
    required this.canvas,
    required this.success,
    required this.warning,
    required this.featureLibrary,
    required this.featureLibraryFill,
  });

  final ShirohaAppearance appearance;
  final ColorScheme colors;
  final Color canvas;
  final Color success;
  final Color warning;
  final Color featureLibrary;
  final Color featureLibraryFill;

  ShirohaThemeStyle get style => appearance.style;
  Brightness get brightness => colors.brightness;
  bool get isDark => brightness == Brightness.dark;
  // Colorful's historical palette is light; dark reuses grayscale compatibility.
  bool get isColorful => style == ShirohaThemeStyle.colorful && !isDark;
  bool get isPaper => style == ShirohaThemeStyle.paper;
  // Paper and Colorful map grayscale artwork to the active palette so the
  // existing illustrations blend with warm/tinted surfaces non-destructively.
  bool get harmonizeIllustrations => isColorful || isPaper;

  Color get brandAccent => featureLibrary;
  Color get brandFill => featureLibraryFill;
  Color get featureAi => colors.secondary;
  Color get featureAiFill => colors.secondaryContainer;
  Color get featureNeutral => colors.onSurfaceVariant;
  Color get featureNeutralFill => subtleFill;

  Color get assistantActionBackground => (isColorful || isPaper)
      ? colors.primary
      : isDark
          ? const Color(0xFF575B69)
          : const Color(0xFF707482);
  Color get assistantOnAction => (isColorful || isPaper)
      ? colors.onPrimary
      : isDark
          ? colors.onSurface
          : colors.onPrimary;
  Color get assistantCanvasStart => Color.lerp(surface, canvas, .35)!;
  Color get assistantCanvasEnd => Color.lerp(canvas, subtleFill, .5)!;
  Color get assistantDrawerScrim => isDark
      ? Colors.black.withValues(alpha: .28)
      : isColorful
          ? colors.primaryContainer.withValues(alpha: .12)
          : const Color(0xFFE0E3EE).withValues(alpha: .12);

  Color get surface => colors.surface;
  Color get textPrimary => colors.onSurface;
  Color get textSecondary => colors.onSurfaceVariant;
  Color get border => colors.outline;
  Color get divider => colors.outlineVariant;
  Color get subtleFill => colors.surfaceContainerHighest;
  Color get icon => isColorful ? colors.primary : colors.onSurface;
  Color get iconBackground => colors.primaryContainer;
  Color get primaryAction => colors.primary;
  Color get onPrimaryAction => colors.onPrimary;
  Color get secondaryAction => colors.secondary;
  Color get selectedFill => colors.primaryContainer;
  Color get selectedForeground => colors.onPrimaryContainer;
  Color get disabledForeground => colors.onSurface.withValues(alpha: .38);
  Color get disabledFill => colors.onSurface.withValues(alpha: .12);
  Color get error => colors.error;
  Color get correct => success;
  Color get incorrect => error;

  Color get cardOutline => divider.withValues(alpha: isColorful ? .45 : 0);
  Color get cardShadow => isColorful
      ? colors.shadow.withValues(alpha: .04)
      : DesignTokens.surfaceShadow(Brightness.light).first.color;
  // Existing dark Category modulation, retained at the shared token boundary.
  Color get categoryArtworkTint => const Color(0xFF85858D);
  // Existing neutral banner/fold colors retained without new palette values.
  // Paper, like Colorful, harmonizes the banner art so its live text reads the
  // shared secondary token against the filtered surface.
  Color get welcomeCaption =>
      (isColorful || isPaper) ? textSecondary : const Color(0xFF747780);
  Color get welcomePillText =>
      (isColorful || isPaper) ? textSecondary : const Color(0xFF555760);
  List<Color> get foldedCornerColors => isDark
      ? const [
          Color(0xFF484B55),
          Color(0xFF898C96),
          Color(0xFFA9ABB2),
          Color(0xFF4F525C)
        ]
      : [subtleFill, surface, surface, border.withValues(alpha: .6)];
  Color get hoverOverlay => icon.withValues(alpha: .06);
  Color get pressedOverlay => icon.withValues(alpha: .12);
  Color get focusOverlay => icon.withValues(alpha: .10);

  /// Maps existing grayscale artwork to the active surface and neutral ink.
  /// Alpha is preserved, including transparent category illustrations.
  ColorFilter get illustrationFilter {
    final dark = isDark;
    final low = dark
        ? Color.lerp(textPrimary, surface, .35)!
        : Color.lerp(textPrimary, icon, .18)!;
    final high = surface;
    final dr = high.r - low.r;
    final dg = high.g - low.g;
    final db = high.b - low.b;
    return ColorFilter.matrix([
      dr * .2126,
      dr * .7152,
      dr * .0722,
      0,
      low.r * 255,
      dg * .2126,
      dg * .7152,
      dg * .0722,
      0,
      low.g * 255,
      db * .2126,
      db * .7152,
      db * .0722,
      0,
      low.b * 255,
      0,
      0,
      0,
      1,
      0,
    ]);
  }

  @override
  ShirohaThemeTokens copyWith({
    ShirohaAppearance? appearance,
    ColorScheme? colors,
    Color? canvas,
    Color? success,
    Color? warning,
    Color? featureLibrary,
    Color? featureLibraryFill,
  }) =>
      ShirohaThemeTokens(
        appearance: appearance ?? this.appearance,
        colors: colors ?? this.colors,
        canvas: canvas ?? this.canvas,
        success: success ?? this.success,
        warning: warning ?? this.warning,
        featureLibrary: featureLibrary ?? this.featureLibrary,
        featureLibraryFill: featureLibraryFill ?? this.featureLibraryFill,
      );

  @override
  ShirohaThemeTokens lerp(ShirohaThemeTokens? other, double t) {
    if (other == null) return this;
    return ShirohaThemeTokens(
      appearance: t < .5 ? appearance : other.appearance,
      colors: ColorScheme.lerp(colors, other.colors, t),
      canvas: Color.lerp(canvas, other.canvas, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      featureLibrary: Color.lerp(featureLibrary, other.featureLibrary, t)!,
      featureLibraryFill:
          Color.lerp(featureLibraryFill, other.featureLibraryFill, t)!,
    );
  }
}
