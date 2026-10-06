import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'shiroha_theme_tokens.dart';

class AppTheme {
  // Legacy decoration constants remain for later page-polish batches.
  static const Color shirohaCyan = Color(0xFF08B9E8);
  static const Color shirohaCyanForeground = Color(0xFF006A85);
  static const Color irisPurple = Color(0xFF7C5CFC);
  static const Color warningAmber = Color(0xFFF4A621);
  static const Color dangerRed = Color(0xFFE5484D);

  static String normalizeName(String? name) => switch (name) {
        'dark' => 'dark',
        'colorful' => 'colorful',
        _ => 'light',
      };

  static ThemeData getTheme(String? themeName) =>
      switch (normalizeName(themeName)) {
        'dark' => darkTheme,
        'colorful' => colorfulTheme,
        _ => lightTheme,
      };

  static ThemeData get lightTheme => _build(ShirohaAppearance.light);
  static ThemeData get darkTheme => _build(ShirohaAppearance.dark);
  static ThemeData get colorfulTheme => _build(ShirohaAppearance.colorful);

  /// Preserves an explicit appearance and inherited typography in local routes.
  static ThemeData withPresetFallback(ThemeData base) {
    if (base.extension<ShirohaThemeTokens>() != null) return base;
    final preset = base.brightness == Brightness.dark ? darkTheme : lightTheme;
    return preset.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: preset.colorScheme.onSurface,
        displayColor: preset.colorScheme.onSurface,
      ),
    );
  }

  static ThemeData _build(ShirohaAppearance appearance) {
    final dark = appearance == ShirohaAppearance.dark;
    final colorful = appearance == ShirohaAppearance.colorful;
    final canvas = dark
        ? const Color(0xFF191A20)
        : colorful
            ? const Color(0xFFF5F8FC)
            : const Color(0xFFF7F7FA);
    final surface = dark ? const Color(0xFF24252B) : Colors.white;
    final ink = dark ? const Color(0xFFEAEAF0) : const Color(0xFF303238);
    final muted = dark
        ? const Color(0xFFB4B5BE)
        : colorful
            ? const Color(0xFF626F83)
            : const Color(0xFF6B6D76);
    final fill = dark
        ? const Color(0xFF33343D)
        : colorful
            ? const Color(0xFFEDF3F9)
            : const Color(0xFFF0F0F5);
    // Slightly darker than the suggested blue so small CTA text stays readable.
    final accent = dark
        ? const Color(0xFFD2D4DC)
        : colorful
            ? const Color(0xFF077799)
            : const Color(0xFF545864);
    final secondary = dark
        ? const Color(0xFFB4A3CF)
        : colorful
            ? const Color(0xFF7052A3)
            : const Color(0xFF7866A5);
    final tertiary = colorful ? const Color(0xFF94612F) : accent;
    final line = dark
        ? const Color(0xFF3B3C45)
        : colorful
            ? const Color(0xFFDDE5EE)
            : const Color(0xFFE8E8EE);
    final onAccent = dark ? canvas : Colors.white;
    final primaryFill = colorful ? const Color(0xFFE3F0F5) : fill;
    final secondaryFill = dark
        ? const Color(0xFF37303F)
        : colorful
            ? const Color(0xFFE8DCF5)
            : const Color(0xFFEEE8FA);
    final tertiaryFill = colorful ? const Color(0xFFF6EDE2) : fill;
    final error = dark ? const Color(0xFFFFB4AB) : const Color(0xFFBA3540);
    final errorFill = dark ? const Color(0xFF5B252B) : const Color(0xFFFFEDEE);
    final colors = ColorScheme(
      brightness: dark ? Brightness.dark : Brightness.light,
      primary: accent,
      onPrimary: onAccent,
      primaryContainer: primaryFill,
      onPrimaryContainer: colorful
          ? const Color(0xFF05657F)
          : dark
              ? ink
              : accent,
      primaryFixed: primaryFill,
      primaryFixedDim: primaryFill,
      onPrimaryFixed: ink,
      onPrimaryFixedVariant: accent,
      secondary: secondary,
      onSecondary: onAccent,
      secondaryContainer: secondaryFill,
      onSecondaryContainer: colorful
          ? const Color(0xFF634391)
          : dark
              ? const Color(0xFFD6C8EA)
              : const Color(0xFF68578F),
      secondaryFixed: secondaryFill,
      secondaryFixedDim: secondaryFill,
      onSecondaryFixed: ink,
      onSecondaryFixedVariant: secondary,
      tertiary: tertiary,
      onTertiary: onAccent,
      tertiaryContainer: tertiaryFill,
      onTertiaryContainer: colorful
          ? const Color(0xFF805524)
          : dark
              ? ink
              : tertiary,
      tertiaryFixed: tertiaryFill,
      tertiaryFixedDim: tertiaryFill,
      onTertiaryFixed: ink,
      onTertiaryFixedVariant: tertiary,
      error: error,
      onError: dark ? const Color(0xFF381015) : Colors.white,
      errorContainer: errorFill,
      onErrorContainer:
          dark ? const Color(0xFFFFDAD6) : const Color(0xFF7D1B25),
      surface: surface,
      onSurface: ink,
      onSurfaceVariant: muted,
      surfaceDim: canvas,
      surfaceBright: surface,
      surfaceContainerLowest: canvas,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: fill,
      surfaceContainerHighest: fill,
      outline: muted,
      outlineVariant: line,
      inverseSurface: ink,
      onInverseSurface: surface,
      inversePrimary: primaryFill,
      surfaceTint: Colors.transparent,
      shadow: Colors.black,
      scrim: Colors.black,
    );
    final tokens = ShirohaThemeTokens(
      appearance: appearance,
      colors: colors,
      canvas: canvas,
      success: dark ? const Color(0xFF9AD5B2) : const Color(0xFF397552),
      warning: dark ? const Color(0xFFE5C18A) : const Color(0xFF8A641F),
      featureLibrary: dark
          ? const Color(0xFF80AFC1)
          : colorful
              ? const Color(0xFF197B9E)
              : const Color(0xFF3286A2),
      featureLibraryFill: dark
          ? const Color(0xFF293A42)
          : colorful
              ? const Color(0xFFD7EEF7)
              : const Color(0xFFDDF3FA),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
    );
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: colors);
    Color stateColor(Set<WidgetState> states) =>
        states.contains(WidgetState.disabled)
            ? tokens.disabledForeground
            : accent;
    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[tokens],
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      primaryColor: accent,
      disabledColor: tokens.disabledForeground,
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      iconTheme: IconThemeData(color: tokens.icon),
      primaryIconTheme: IconThemeData(color: onAccent),
      appBarTheme: AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
            color: ink,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            fontFamily: base.textTheme.titleLarge?.fontFamily),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: accent,
        unselectedItemColor: muted,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: primaryFill,
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? accent : muted)),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: shape.copyWith(side: BorderSide(color: line)),
      ),
      dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: onAccent,
        disabledBackgroundColor: tokens.disabledFill,
        disabledForegroundColor: tokens.disabledForeground,
        shape: shape,
        minimumSize: const Size(44, 44),
      )),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: onAccent,
        elevation: 0,
        disabledBackgroundColor: tokens.disabledFill,
        disabledForegroundColor: tokens.disabledForeground,
        shape: shape,
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
        foregroundColor: accent,
        side: BorderSide(color: muted),
        shape: shape,
      )),
      textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: accent)),
      iconButtonTheme: IconButtonThemeData(
          style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(stateColor),
      )),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fill,
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder:
            inputBorder.copyWith(borderSide: BorderSide(color: accent)),
        errorBorder: inputBorder.copyWith(borderSide: BorderSide(color: error)),
        focusedErrorBorder: inputBorder.copyWith(
            borderSide: BorderSide(color: error, width: 2)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: TextStyle(color: muted),
        labelStyle: TextStyle(color: muted),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: shape,
        titleTextStyle:
            TextStyle(color: ink, fontSize: 18, fontWeight: FontWeight.w700),
        contentTextStyle: TextStyle(color: ink, fontSize: 14),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      popupMenuTheme: PopupMenuThemeData(
          color: surface, surfaceTintColor: Colors.transparent, shape: shape),
      snackBarTheme: SnackBarThemeData(
          backgroundColor: ink, contentTextStyle: TextStyle(color: surface)),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: fill,
        selectedColor: primaryFill,
        disabledColor: tokens.disabledFill,
        side: BorderSide(color: line),
        labelStyle: TextStyle(color: ink),
        secondaryLabelStyle: TextStyle(color: accent),
      ),
      checkboxTheme: CheckboxThemeData(
          fillColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? tokens.disabledForeground
                  : states.contains(WidgetState.selected)
                      ? accent
                      : Colors.transparent)),
      radioTheme: RadioThemeData(
          fillColor: WidgetStateProperty.resolveWith(stateColor)),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? tokens.disabledForeground
                : states.contains(WidgetState.selected)
                    ? onAccent
                    : muted),
        trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? tokens.disabledFill
                : states.contains(WidgetState.selected)
                    ? accent
                    : fill),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: accent,
        inactiveTrackColor: fill,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: .1),
        trackHeight: 7,
        showValueIndicator: ShowValueIndicator.onlyForDiscrete,
      ),
      progressIndicatorTheme:
          ProgressIndicatorThemeData(color: accent, linearTrackColor: fill),
      listTileTheme: ListTileThemeData(
          iconColor: tokens.icon,
          textColor: ink,
          selectedColor: colors.onPrimaryContainer,
          selectedTileColor: primaryFill),
      segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? tokens.disabledForeground
                : states.contains(WidgetState.selected)
                    ? colors.onPrimaryContainer
                    : ink),
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primaryFill : surface),
      )),
    );
  }
}
