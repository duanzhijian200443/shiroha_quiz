import 'package:flutter/material.dart';

class AppTheme {
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
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF8F9FA),
      primaryColor: const Color(0xFF4C6ED7),
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF4C6ED7),
        secondary: Color(0xFF5C7CFA),
        surface: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: Colors.black87),
        titleTextStyle: TextStyle(color: Colors.black87, fontSize: 18, fontWeight: FontWeight.bold),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: Color(0xFF4C6ED7),
        unselectedItemColor: Colors.black38,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
    );
  }

  static ThemeData get darkTheme {
    const Color midnightBlack = Color(0xFF121214);
    const Color deepSeaBlue = Color(0xFF1E2030);
    const Color cyberBlue = Color(0xFF00E5FF);
    
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: midnightBlack,
      primaryColor: cyberBlue,
      colorScheme: const ColorScheme.dark(
        primary: cyberBlue,
        secondary: cyberBlue,
        surface: deepSeaBlue,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: midnightBlack,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: Colors.white),
        titleTextStyle: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
      ),
      cardTheme: CardThemeData(
        color: deepSeaBlue,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withAlpha(13), width: 1),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: deepSeaBlue,
        selectedItemColor: cyberBlue,
        unselectedItemColor: Colors.white38,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
    );
  }
}
