import 'package:flutter/material.dart';

import 'design_tokens.dart';

class AppTheme {
  static const Color shirohaCyan = Color(0xFF08B9E8);
  static const Color shirohaCyanForeground = Color(0xFF006A85);
  static const Color irisPurple = Color(0xFF7C5CFC);
  static const Color warningAmber = Color(0xFFF4A621);
  static const Color dangerRed = Color(0xFFE5484D);

  static const Color _lightCanvas = Color(0xFFF4F8FC);
  static const Color _lightSurface = Color(0xFFFFFFFF);
  static const Color _lightPrimaryText = Color(0xFF102033);
  static const Color _lightSecondaryText = Color(0xFF5E6F83);
  static const Color _lightOutline = Color(0xFFDCE6EF);

  static const Color _darkCanvas = Color(0xFF071827);
  static const Color _darkSurface = Color(0xFF102538);
  static const Color _darkPrimaryText = Color(0xFFF4F8FC);
  static const Color _darkSecondaryText = Color(0xFFA9B8C7);
  static const Color _darkOutline = Color(0xFF294054);

  static ThemeData getTheme(String themeName) {
    switch (themeName) {
      case 'dark':
        return darkTheme;
      case 'morandi':
        // 预留莫兰迪主题，暂返回 lightTheme
        return lightTheme;
      case 'light':
      default:
        return lightTheme;
    }
  }

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: _lightCanvas,
      primaryColor: shirohaCyan,
      colorScheme: const ColorScheme.light(
        primary: shirohaCyan,
        onPrimary: Color(0xFF003642),
        primaryContainer: Color(0xFFDFF7FC),
        onPrimaryContainer: Color(0xFF054A60),
        secondary: irisPurple,
        onSecondary: Colors.black,
        secondaryContainer: Color(0xFFEDE8FF),
        onSecondaryContainer: Color(0xFF35236F),
        tertiary: warningAmber,
        onTertiary: Color(0xFF3D2A00),
        error: dangerRed,
        onError: Colors.black,
        surface: _lightSurface,
        onSurface: _lightPrimaryText,
        onSurfaceVariant: _lightSecondaryText,
        outline: Color(0xFFB9C8D6),
        outlineVariant: _lightOutline,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: _lightCanvas,
        foregroundColor: _lightPrimaryText,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: _lightPrimaryText,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: _lightSurface,
        selectedItemColor: shirohaCyanForeground,
        unselectedItemColor: _lightSecondaryText,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: _lightSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
          side: const BorderSide(color: _lightOutline),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: _lightOutline,
        thickness: 1,
        space: 1,
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _darkCanvas,
      primaryColor: shirohaCyan,
      colorScheme: const ColorScheme.dark(
        primary: shirohaCyan,
        onPrimary: Color(0xFF003642),
        primaryContainer: Color(0xFF123D4B),
        onPrimaryContainer: Color(0xFFB8F1FF),
        secondary: irisPurple,
        onSecondary: Colors.white,
        secondaryContainer: Color(0xFF332B61),
        onSecondaryContainer: Color(0xFFE5DDFF),
        tertiary: warningAmber,
        onTertiary: Color(0xFF3D2A00),
        error: dangerRed,
        onError: Colors.white,
        surface: _darkSurface,
        onSurface: _darkPrimaryText,
        onSurfaceVariant: _darkSecondaryText,
        outline: Color(0xFF52697D),
        outlineVariant: _darkOutline,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: _darkCanvas,
        foregroundColor: _darkPrimaryText,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: _darkPrimaryText,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: _darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.cardRadius),
          side: const BorderSide(color: _darkOutline),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: _darkSurface,
        selectedItemColor: shirohaCyan,
        unselectedItemColor: _darkSecondaryText,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(
        color: _darkOutline,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
