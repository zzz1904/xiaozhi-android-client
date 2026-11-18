import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTheme {
  static const Color _lightBackground = Color(0xFFF7F8FA);
  static const Color _darkBackground = Color(0xFF121212);
  static const Color _darkSurface = Color(0xFF1E1E1E);
  static const Color _darkElevated = Color(0xFF252525);

  static final ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: const ColorScheme.light(
      primary: Color(0xFF202124), secondary: Color(0xFF5F6368),
      surface: Colors.white, error: Color(0xFFB3261E),
      onPrimary: Colors.white, onSecondary: Colors.white,
      onSurface: Color(0xFF202124), onError: Colors.white,
    ),
    scaffoldBackgroundColor: _lightBackground,
    appBarTheme: const AppBarTheme(
      backgroundColor: _lightBackground, foregroundColor: Color(0xFF202124),
      elevation: 0, scrolledUnderElevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent, statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light, systemNavigationBarColor: _lightBackground,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Color(0xFF202124)), bodyMedium: TextStyle(color: Color(0xFF202124)),
      titleLarge: TextStyle(color: Color(0xFF202124), fontWeight: FontWeight.bold),
      titleMedium: TextStyle(color: Color(0xFF202124), fontWeight: FontWeight.bold),
      titleSmall: TextStyle(color: Color(0xFF202124), fontWeight: FontWeight.bold),
    ),
    cardTheme: CardTheme(color: Colors.white, elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: Colors.white, hintStyle: const TextStyle(color: Color(0xFF777777)),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE0E0E0))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE0E0E0))),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    dividerColor: const Color(0xFFE5E5E5),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Colors.white, selectedItemColor: Color(0xFF202124),
      unselectedItemColor: Color(0xFF757575), type: BottomNavigationBarType.fixed, elevation: 8),
  );

  static final ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFFE8EAED), secondary: Color(0xFFBDC1C6),
      surface: _darkSurface, error: Color(0xFFF2B8B5),
      onPrimary: Color(0xFF202124), onSecondary: Color(0xFF202124),
      onSurface: Color(0xFFE8EAED), onError: Color(0xFF601410),
    ),
    scaffoldBackgroundColor: _darkBackground,
    appBarTheme: const AppBarTheme(
      backgroundColor: _darkBackground, foregroundColor: Color(0xFFE8EAED),
      elevation: 0, scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: Color(0xFFE8EAED)),
      titleTextStyle: TextStyle(color: Color(0xFFE8EAED), fontSize: 22, fontWeight: FontWeight.bold),
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent, statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark, systemNavigationBarColor: _darkBackground,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Color(0xFFE8EAED)), bodyMedium: TextStyle(color: Color(0xFFE8EAED)),
      titleLarge: TextStyle(color: Color(0xFFE8EAED), fontWeight: FontWeight.bold),
      titleMedium: TextStyle(color: Color(0xFFE8EAED), fontWeight: FontWeight.bold),
      titleSmall: TextStyle(color: Color(0xFFE8EAED), fontWeight: FontWeight.bold),
    ),
    cardTheme: CardTheme(color: _darkSurface, elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: _darkElevated,
      hintStyle: const TextStyle(color: Color(0xFF9AA0A6)),
      labelStyle: const TextStyle(color: Color(0xFFBDC1C6)),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF454545))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF454545))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE8EAED), width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    dividerColor: const Color(0xFF383838),
    iconTheme: const IconThemeData(color: Color(0xFFE8EAED)),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: _darkSurface, selectedItemColor: Color(0xFFE8EAED),
      unselectedItemColor: Color(0xFF9AA0A6), type: BottomNavigationBarType.fixed, elevation: 8),
  );
}
