import 'salah_prayer.dart';

/// Prayer times for one calendar day, in the user's local timezone.
class PrayerDayTimes {
  /// The calendar date these times belong to (in the user's timezone).
  final DateTime date;

  /// Prayer -> time-zone-aware DateTime.
  final Map<SalahPrayer, DateTime> times;

  const PrayerDayTimes({required this.date, required this.times});

  DateTime timeFor(SalahPrayer prayer) => times[prayer]!;

  /// Ordered list of (prayer, time) entries for this day.
  List<MapEntry<SalahPrayer, DateTime>> get orderedEntries =>
      SalahPrayer.values.map((p) => MapEntry(p, times[p]!)).toList();

  /// The next prayer of this day strictly after [now], or null.
  MapEntry<SalahPrayer, DateTime>? nextAfter(DateTime now) {
    for (final entry in orderedEntries) {
      if (entry.value.isAfter(now)) return entry;
    }
    return null;
  }
}
