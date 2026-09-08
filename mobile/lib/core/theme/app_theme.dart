import 'package:flutter/material.dart';

/// Dark navy theme used across the Mogok Maung mobile app.
class AppTheme {
  AppTheme._();

  static const Color navyBackground = Color(0xFF0F172A);
  static const Color navySurface = Color(0xFF1E293B);
  static const Color accentBlue = Color(0xFF3B82F6);
  static const Color accentAmber = Color(0xFFF59E0B);

  static final ThemeData dark = _buildDark();

  static ThemeData _buildDark() {
    const ColorScheme scheme = ColorScheme.dark(
      primary: accentBlue,
      secondary: accentAmber,
      surface: navySurface,
      error: Color(0xFFEF4444),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: navyBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: navySurface,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
    );
  }
}

/// Shared palette tokens used across the betting/live feature widgets.
class AppColors {
  AppColors._();

  static const Color background = AppTheme.navyBackground;
  static const Color panel = AppTheme.navySurface;
  static const Color edge = Color(0xFF334155);
  static const Color amber = AppTheme.accentAmber;
  static const Color blue = AppTheme.accentBlue;
  static const Color text = Colors.white;
  static const Color textDim = Color(0xFF94A3B8);
  static const Color error = Color(0xFFEF4444);
}