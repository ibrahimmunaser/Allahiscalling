import 'package:flutter/material.dart';

/// Calm, serious Islamic design: deep emerald green with warm gold accents.
class AppTheme {
  AppTheme._();

  static const Color deepGreen = Color(0xFF0E3B2E);
  static const Color emerald = Color(0xFF1B5E4A);
  static const Color gold = Color(0xFFC9A24B);
  static const Color softGold = Color(0xFFE5D3A1);
  static const Color ivory = Color(0xFFF7F4EC);
  static const Color nightBlue = Color(0xFF0A1F1A);

  static ThemeData light() {
    final base = ColorScheme.fromSeed(
      seedColor: emerald,
      primary: emerald,
      secondary: gold,
      surface: ivory,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: base,
      scaffoldBackgroundColor: ivory,
      appBarTheme: const AppBarTheme(
        backgroundColor: deepGreen,
        foregroundColor: ivory,
        elevation: 0,
        centerTitle: true,
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: emerald,
          foregroundColor: ivory,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: deepGreen,
        contentTextStyle: TextStyle(color: ivory),
      ),
      dividerTheme: DividerThemeData(color: Colors.grey.shade300),
    );
  }
}
