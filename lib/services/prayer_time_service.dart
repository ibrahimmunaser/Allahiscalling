import 'package:adhan_dart/adhan_dart.dart' as adhan;
import 'package:timezone/timezone.dart' as tz;

import '../models/prayer_day_times.dart';
import '../models/prayer_settings.dart';
import '../models/salah_prayer.dart';

/// Calculates prayer times offline using adhan_dart, converting results into
/// the user's timezone (DST-safe via the IANA timezone database).
class PrayerTimeService {
  /// Calculates the five prayer times for the calendar [date] in the
  /// timezone from [settings].
  ///
  /// Throws [StateError] if location or timezone is missing.
  PrayerDayTimes calculateForDate(PrayerSettings settings, DateTime date) {
    if (!settings.hasLocation) {
      throw StateError('Location is not set');
    }
    if (settings.timezone == null) {
      throw StateError('Timezone is not set');
    }

    final location = tz.getLocation(settings.timezone!);
    final coordinates =
        adhan.Coordinates(settings.latitude!, settings.longitude!);
    final params = buildCalculationParameters(settings);

    // adhan_dart computes from a UTC date and returns UTC instants.
    final utcDate = DateTime.utc(date.year, date.month, date.day);
    final prayerTimes = adhan.PrayerTimes(
      date: utcDate,
      coordinates: coordinates,
      calculationParameters: params,
    );

    tz.TZDateTime localize(DateTime utcTime) =>
        tz.TZDateTime.from(utcTime.toUtc(), location);

    return PrayerDayTimes(
      date: DateTime(date.year, date.month, date.day),
      times: {
        SalahPrayer.fajr: localize(prayerTimes.fajr),
        SalahPrayer.dhuhr: localize(prayerTimes.dhuhr),
        SalahPrayer.asr: localize(prayerTimes.asr),
        SalahPrayer.maghrib: localize(prayerTimes.maghrib),
        SalahPrayer.isha: localize(prayerTimes.isha),
      },
    );
  }

  /// Calculates prayer times for [days] consecutive days starting at the
  /// current calendar date in the user's timezone.
  List<PrayerDayTimes> calculateRange(
    PrayerSettings settings, {
    DateTime? from,
    int days = 7,
  }) {
    final location = tz.getLocation(settings.timezone!);
    final start = from ?? tz.TZDateTime.now(location);
    final startDate = DateTime(start.year, start.month, start.day);

    return List.generate(days, (i) {
      // Add days on the pure date; avoids DST hour-shift issues.
      final date =
          DateTime(startDate.year, startDate.month, startDate.day + i);
      return calculateForDate(settings, date);
    });
  }

  /// Returns the next upcoming prayer at or after [now].
  MapEntry<SalahPrayer, DateTime>? nextPrayer(
    PrayerSettings settings, {
    DateTime? now,
  }) {
    final location = tz.getLocation(settings.timezone!);
    final reference = now ?? tz.TZDateTime.now(location);
    // Two days is always enough to find the next prayer.
    for (final day in calculateRange(settings, from: reference, days: 2)) {
      final next = day.nextAfter(reference);
      if (next != null) return next;
    }
    return null;
  }

  /// Maps app settings to adhan_dart calculation parameters, including
  /// method, Asr madhab, high-latitude rule, and manual minute adjustments.
  ///
  /// Only Sunni calculation presets are exposed. Shia methods (Jafari,
  /// Tehran) are not available in the app.
  adhan.CalculationParameters buildCalculationParameters(
      PrayerSettings settings) {
    final params = switch (settings.calculationMethod) {
      CalculationMethodOption.isna =>
        adhan.CalculationMethodParameters.northAmerica(),
      CalculationMethodOption.muslimWorldLeague =>
        adhan.CalculationMethodParameters.muslimWorldLeague(),
      CalculationMethodOption.ummAlQura =>
        adhan.CalculationMethodParameters.ummAlQura(),
      CalculationMethodOption.egyptian =>
        adhan.CalculationMethodParameters.egyptian(),
      CalculationMethodOption.karachi =>
        adhan.CalculationMethodParameters.karachi(),
      CalculationMethodOption.diyanet =>
        adhan.CalculationMethodParameters.turkiye(),
      // JAKIM (Malaysia) has no adhan_dart preset; it uses Fajr 20°/Isha 18°.
      CalculationMethodOption.jakim => adhan.CalculationParameters(
          method: adhan.CalculationMethod.other,
          fajrAngle: 20,
          ishaAngle: 18,
        ),
      CalculationMethodOption.muis =>
        adhan.CalculationMethodParameters.singapore(),
      CalculationMethodOption.kemenag =>
        adhan.CalculationMethodParameters.indonesian(),
      CalculationMethodOption.tunisia =>
        adhan.CalculationMethodParameters.tunisia(),
      CalculationMethodOption.algeria =>
        adhan.CalculationMethodParameters.algerian(),
      CalculationMethodOption.russia =>
        adhan.CalculationMethodParameters.russia(),
      CalculationMethodOption.custom => adhan.CalculationParameters(
          method: adhan.CalculationMethod.other,
          fajrAngle: settings.customFajrAngle,
          ishaAngle: settings.customIshaAngle,
        ),
    };

    params.madhab = settings.asrMethod == AsrMethod.hanafi
        ? adhan.Madhab.hanafi
        : adhan.Madhab.shafi;

    params.highLatitudeRule = switch (settings.highLatitudeRule) {
      HighLatitudeRuleOption.middleOfTheNight =>
        adhan.HighLatitudeRule.middleOfTheNight,
      HighLatitudeRuleOption.seventhOfTheNight =>
        adhan.HighLatitudeRule.seventhOfTheNight,
      HighLatitudeRuleOption.twilightAngle =>
        adhan.HighLatitudeRule.twilightAngle,
    };

    params.adjustments = {
      adhan.Prayer.fajr: settings.adjustmentFor(SalahPrayer.fajr),
      adhan.Prayer.sunrise: 0,
      adhan.Prayer.dhuhr: settings.adjustmentFor(SalahPrayer.dhuhr),
      adhan.Prayer.asr: settings.adjustmentFor(SalahPrayer.asr),
      adhan.Prayer.maghrib: settings.adjustmentFor(SalahPrayer.maghrib),
      adhan.Prayer.isha: settings.adjustmentFor(SalahPrayer.isha),
    };

    return params;
  }
}
