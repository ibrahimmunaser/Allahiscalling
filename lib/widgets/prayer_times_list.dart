import 'package:flutter/material.dart';

import '../models/prayer_day_times.dart';
import '../models/salah_prayer.dart';
import '../utils/app_theme.dart';
import '../utils/formatting.dart';

/// Today's five prayer times, highlighting the upcoming one.
///
/// Each row uses that prayer's own palette so Fajr–Isha read as distinct
/// atmospheres; the next prayer gets a stronger tint and border.
class PrayerTimesList extends StatelessWidget {
  final PrayerDayTimes day;
  final SalahPrayer? highlighted;

  const PrayerTimesList({super.key, required this.day, this.highlighted});

  @override
  Widget build(BuildContext context) {
    return Column(
      children:
          day.orderedEntries.map((entry) {
            final prayer = entry.key;
            final theme = AppTheme.forPrayer(prayer);
            final isNext = prayer == highlighted;
            return Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color:
                    isNext
                        ? theme.listTint.withValues(alpha: 0.12)
                        : theme.listTint.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                border:
                    isNext
                        ? Border.all(color: theme.accent, width: 1.2)
                        : Border.all(
                          color: theme.listTint.withValues(alpha: 0.14),
                          width: 1,
                        ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        _iconFor(prayer),
                        size: 20,
                        color:
                            isNext
                                ? theme.primary
                                : theme.primary.withValues(alpha: 0.72),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        prayer.displayName,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight:
                              isNext ? FontWeight.w700 : FontWeight.w500,
                          color: isNext ? theme.deep : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    formatTime(entry.value),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: isNext ? FontWeight.w700 : FontWeight.w500,
                      color: isNext ? theme.deep : Colors.black87,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
    );
  }

  IconData _iconFor(SalahPrayer prayer) {
    switch (prayer) {
      case SalahPrayer.fajr:
        return Icons.wb_twilight;
      case SalahPrayer.dhuhr:
        return Icons.wb_sunny_outlined;
      case SalahPrayer.asr:
        return Icons.sunny_snowing;
      case SalahPrayer.maghrib:
        return Icons.nights_stay_outlined;
      case SalahPrayer.isha:
        return Icons.dark_mode_outlined;
    }
  }
}
