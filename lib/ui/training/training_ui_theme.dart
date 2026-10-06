import 'package:flutter/material.dart';

/// Local grayscale presentation for the three training configuration routes.
class TrainingUiTheme extends StatelessWidget {
  const TrainingUiTheme({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final dark = base.brightness == Brightness.dark;
    final canvas = dark ? const Color(0xFF191B20) : const Color(0xFFF7F9FB);
    final surface = dark ? const Color(0xFF24272D) : Colors.white;
    final ink = dark ? const Color(0xFFEFF0F2) : const Color(0xFF17191C);
    final muted = dark ? const Color(0xFFADB2BC) : const Color(0xFF8C929E);
    final fill = dark ? const Color(0xFF30343C) : const Color(0xFFF0F2F5);
    final accent = dark ? const Color(0xFFBFC4CE) : const Color(0xFF606772);
    return Theme(
      data: base.copyWith(
        scaffoldBackgroundColor: canvas,
        colorScheme: base.colorScheme.copyWith(
          primary: accent,
          onPrimary: dark ? canvas : Colors.white,
          primaryContainer: fill,
          onPrimaryContainer: ink,
          secondary: accent,
          secondaryContainer: fill,
          onSecondaryContainer: ink,
          surface: surface,
          onSurface: ink,
          onSurfaceVariant: muted,
          surfaceContainerHighest: fill,
          outline: muted,
          outlineVariant: fill,
        ),
        textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
        appBarTheme: base.appBarTheme.copyWith(
          backgroundColor: canvas,
          foregroundColor: ink,
          centerTitle: true,
          titleTextStyle: TextStyle(
              color: ink,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              fontFamily: base.textTheme.titleLarge?.fontFamily),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: fill,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          hintStyle: TextStyle(color: muted),
        ),
        sliderTheme: base.sliderTheme.copyWith(
          activeTrackColor: accent,
          inactiveTrackColor: fill,
          thumbColor: surface,
          trackHeight: 7,
          overlayColor: accent.withValues(alpha: .1),
          showValueIndicator: ShowValueIndicator.onlyForDiscrete,
        ),
      ),
      child: child,
    );
  }
}
