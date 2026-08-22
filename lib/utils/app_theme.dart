import 'package:flutter/material.dart';

import '../models/salah_prayer.dart';

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

  /// Atmosphere for a specific prayer — used on the incoming call and list.
  static PrayerPalette forPrayer(SalahPrayer prayer) =>
      PrayerPalette.forPrayer(prayer);
}

/// Distinct color + mood for each of the five daily prayers.
///
/// App chrome stays on [AppTheme]; these palettes color prayer-scoped UI
/// (incoming call, times list highlight) so each salah feels different.
class PrayerPalette {
  const PrayerPalette({
    required this.primary,
    required this.deep,
    required this.accent,
    required this.softAccent,
    required this.gradientTop,
    required this.gradientMid,
    required this.gradientBottom,
    required this.onAccent,
    required this.listTint,
  });

  /// Avatar / fill focus color.
  final Color primary;

  /// Darker companion for gradients and strong text.
  final Color deep;

  /// Borders, ripples, Answer glow.
  final Color accent;

  /// Prayer name / secondary labels on dark backgrounds.
  final Color softAccent;

  /// Incoming-call background gradient (top → mid → bottom).
  final Color gradientTop;
  final Color gradientMid;
  final Color gradientBottom;

  /// Icon color on the Answer button.
  final Color onAccent;

  /// Soft wash behind the highlighted row in the times list.
  final Color listTint;

  static PrayerPalette forPrayer(SalahPrayer prayer) {
    switch (prayer) {
      case SalahPrayer.fajr:
        // Pre-dawn: cool slate and frost — still night, first light.
        return const PrayerPalette(
          primary: Color(0xFF3D5A80),
          deep: Color(0xFF1B2838),
          accent: Color(0xFF8EACCB),
          softAccent: Color(0xFFC5D5E8),
          gradientTop: Color(0xFF0B1220),
          gradientMid: Color(0xFF152536),
          gradientBottom: Color(0xFF243B55),
          onAccent: Color(0xFF0B1220),
          listTint: Color(0xFF3D5A80),
        );
      case SalahPrayer.dhuhr:
        // Midday: clear sky and sun — bright, open, warm.
        return const PrayerPalette(
          primary: Color(0xFF1A7A8C),
          deep: Color(0xFF0C4A56),
          accent: Color(0xFFE8B84A),
          softAccent: Color(0xFFF5D98A),
          gradientTop: Color(0xFF063640),
          gradientMid: Color(0xFF0C5A68),
          gradientBottom: Color(0xFF187A8A),
          onAccent: Color(0xFF063640),
          listTint: Color(0xFF1A7A8C),
        );
      case SalahPrayer.asr:
        // Late afternoon: honey light and warm bronze.
        return const PrayerPalette(
          primary: Color(0xFF9A6B2F),
          deep: Color(0xFF4A3218),
          accent: Color(0xFFD4A04A),
          softAccent: Color(0xFFE8C98A),
          gradientTop: Color(0xFF1A140C),
          gradientMid: Color(0xFF3D2A14),
          gradientBottom: Color(0xFF6B4820),
          onAccent: Color(0xFF1A140C),
          listTint: Color(0xFF9A6B2F),
        );
      case SalahPrayer.maghrib:
        // Sunset: deep wine and copper glow.
        return const PrayerPalette(
          primary: Color(0xFF8B3A3A),
          deep: Color(0xFF3D1518),
          accent: Color(0xFFE08A5A),
          softAccent: Color(0xFFF0B898),
          gradientTop: Color(0xFF14080A),
          gradientMid: Color(0xFF3A1518),
          gradientBottom: Color(0xFF6B2A28),
          onAccent: Color(0xFF14080A),
          listTint: Color(0xFF8B3A3A),
        );
      case SalahPrayer.isha:
        // Night: midnight navy and cool moonlight.
        return const PrayerPalette(
          primary: Color(0xFF2A3F6E),
          deep: Color(0xFF0C1428),
          accent: Color(0xFFA8B8D8),
          softAccent: Color(0xFFD0DAEC),
          gradientTop: Color(0xFF050810),
          gradientMid: Color(0xFF0E1628),
          gradientBottom: Color(0xFF1A2848),
          onAccent: Color(0xFF050810),
          listTint: Color(0xFF2A3F6E),
        );
    }
  }
}
