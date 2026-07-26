import 'package:adhan_dart/adhan_dart.dart' as adhan;
import 'package:timezone/timezone.dart' as tz;

import '../models/prayer_day_times.dart';
import '../models/prayer_settings.dart';
import '../models/salah_prayer.dart';

/// Thrown when a chronologically valid five-prayer sequence cannot be
/// established for a date/location, even after the high-latitude recovery
/// search in [PrayerTimeService.calculateForDate]. Callers must never fall
/// back to scheduling whatever partial/garbage times were computed.
class PrayerCalculationException implements Exception {
  final String message;

  const PrayerCalculationException(this.message);

  @override
  String toString() => 'PrayerCalculationException: $message';
}

/// Calculates prayer times offline using adhan_dart, converting results into
/// the user's timezone (DST-safe via the IANA timezone database).
///
/// Extreme-latitude safety net (see [_isChronologicallyValid] /
/// [_nearestValidDaySearchLimit]):
///
/// adhan_dart's astronomical hour-angle correction can diverge by days or
/// weeks — not merely return NaN — on dates where the sun never reaches the
/// requested altitude at all (circumpolar midnight-sun / polar-night days).
/// Confirmed empirically for Tromsø (69.65°N): on 2026-06-21 the library
/// returns a raw sunset hour angle of ~558 (valid range is ~0-24), which
/// materializes as a Maghrib timestamp three weeks after the requested
/// date. adhan_dart's own `PolarCircleResolution` recovery path never
/// triggers for this case because its guard only checks for `NaN`, and the
/// astronomical routine deliberately clamps the underlying `acos` domain
/// error to a finite (but wrong) value instead of producing `NaN` — so the
/// clamp itself defeats the library's own recovery mechanism.
///
/// This service therefore validates every computed day itself and, when the
/// direct computation is not a self-consistent ordered sequence within a
/// sane window of the requested date, falls back to the "Aqrab al-Ayyam"
/// (nearest day) high-latitude convention: search outward for the nearest
/// calendar day whose own direct computation IS self-consistent, and borrow
/// that day's local time-of-day pattern (including which prayers fall after
/// local midnight) for the requested date. If no valid reference day exists
/// within [_nearestValidDaySearchLimit] days (never expected for real Earth
/// coordinates — every latitude has an equinox-like period within six
/// months), a [PrayerCalculationException] is thrown rather than ever
/// scheduling an incorrect alarm from divergent output.
class PrayerTimeService {
  /// Every legitimate day's five prayers — even with generous allowance for
  /// Isha/Fajr crossing local midnight at extreme latitudes — fall within
  /// this window of the requested date's UTC midnight. adhan_dart's
  /// divergent-iteration failure mode misses this by days/weeks, so this
  /// window cleanly separates "midnight-crossing" from "astronomically
  /// impossible."
  static const Duration _sanityWindow = Duration(hours: 42);

  /// How many calendar days outward (in each direction) to search for a
  /// self-consistent reference day when the requested date's direct
  /// computation is pathological. ~6 months always contains an
  /// equinox-like period for any latitude on Earth.
  static const int _nearestValidDaySearchLimit = 186;

  /// Calculates the five prayer times for the calendar [date] in the
  /// timezone from [settings].
  ///
  /// Throws [StateError] if location or timezone is missing, or
  /// [PrayerCalculationException] if no chronologically valid sequence can
  /// be established for [date] (see class docs).
  PrayerDayTimes calculateForDate(PrayerSettings settings, DateTime date) {
    if (!settings.hasLocation) {
      throw StateError('Location is not set');
    }
    if (settings.timezone == null) {
      throw StateError('Timezone is not set');
    }

    final location = tz.getLocation(settings.timezone!);
    final coordinates = adhan.Coordinates(
      settings.latitude!,
      settings.longitude!,
    );
    final params = buildCalculationParameters(settings);
    final requestedDate = DateTime(date.year, date.month, date.day);

    final direct = _computeRaw(requestedDate, coordinates, params, location);
    if (_isChronologicallyValid(direct, requestedDate)) {
      return PrayerDayTimes(date: requestedDate, times: direct);
    }

    for (var offset = 1; offset <= _nearestValidDaySearchLimit; offset++) {
      for (final sign in const [1, -1]) {
        final candidateDate = DateTime(
          requestedDate.year,
          requestedDate.month,
          requestedDate.day + sign * offset,
        );
        final candidate = _computeRaw(
          candidateDate,
          coordinates,
          params,
          location,
        );
        if (_isChronologicallyValid(candidate, candidateDate)) {
          return PrayerDayTimes(
            date: requestedDate,
            times: _stampTimeOfDay(
              candidate,
              referenceDate: candidateDate,
              targetDate: requestedDate,
              location: location,
            ),
          );
        }
      }
    }

    throw PrayerCalculationException(
      'No chronologically valid prayer sequence for '
      '${requestedDate.toIso8601String()} at '
      '(${settings.latitude}, ${settings.longitude}): the astronomical '
      'calculation diverged and no self-consistent reference day was found '
      'within $_nearestValidDaySearchLimit days.',
    );
  }

  /// Raw adhan_dart computation for one calendar date, localized — no
  /// validity checking or recovery. May return a pathological (non-ordered
  /// or wildly out-of-range) sequence at extreme latitudes; callers must
  /// validate before trusting the result.
  Map<SalahPrayer, DateTime> _computeRaw(
    DateTime date,
    adhan.Coordinates coordinates,
    adhan.CalculationParameters params,
    tz.Location location,
  ) {
    // adhan_dart computes from a UTC date and returns UTC instants.
    final utcDate = DateTime.utc(date.year, date.month, date.day);
    final prayerTimes = adhan.PrayerTimes(
      date: utcDate,
      coordinates: coordinates,
      calculationParameters: params,
    );

    tz.TZDateTime localize(DateTime utcTime) =>
        tz.TZDateTime.from(utcTime.toUtc(), location);

    return {
      SalahPrayer.fajr: localize(prayerTimes.fajr),
      SalahPrayer.dhuhr: localize(prayerTimes.dhuhr),
      SalahPrayer.asr: localize(prayerTimes.asr),
      SalahPrayer.maghrib: localize(prayerTimes.maghrib),
      SalahPrayer.isha: localize(prayerTimes.isha),
    };
  }

  /// True when [times] is a strictly increasing Fajr→Isha sequence (Isha
  /// legitimately crossing local midnight into the next calendar day is
  /// handled correctly here, since these are absolute instant comparisons,
  /// never naive HH:mm comparisons) AND every prayer falls within
  /// [_sanityWindow] of [anchorDate]'s UTC midnight.
  bool _isChronologicallyValid(
    Map<SalahPrayer, DateTime> times,
    DateTime anchorDate,
  ) {
    final fajr = times[SalahPrayer.fajr]!;
    final dhuhr = times[SalahPrayer.dhuhr]!;
    final asr = times[SalahPrayer.asr]!;
    final maghrib = times[SalahPrayer.maghrib]!;
    final isha = times[SalahPrayer.isha]!;

    final ordered =
        fajr.isBefore(dhuhr) &&
        dhuhr.isBefore(asr) &&
        asr.isBefore(maghrib) &&
        maghrib.isBefore(isha);
    if (!ordered) return false;

    final anchorUtc = DateTime.utc(
      anchorDate.year,
      anchorDate.month,
      anchorDate.day,
    );
    for (final t in [fajr, dhuhr, asr, maghrib, isha]) {
      if (t.toUtc().difference(anchorUtc).abs() > _sanityWindow) return false;
    }
    return true;
  }

  /// Re-applies the local time-of-day pattern from a validated reference
  /// day onto [targetDate], preserving which prayers fell after local
  /// midnight on the reference day (so a borrowed Isha at, say, 00:40 stays
  /// one calendar day after Maghrib when stamped onto the target date).
  Map<SalahPrayer, DateTime> _stampTimeOfDay(
    Map<SalahPrayer, DateTime> reference, {
    required DateTime referenceDate,
    required DateTime targetDate,
    required tz.Location location,
  }) {
    final result = <SalahPrayer, DateTime>{};
    for (final entry in reference.entries) {
      final local = tz.TZDateTime.from(entry.value, location);
      final dayOffset =
          DateTime(
            local.year,
            local.month,
            local.day,
          ).difference(referenceDate).inDays;
      result[entry.key] = tz.TZDateTime(
        location,
        targetDate.year,
        targetDate.month,
        targetDate.day + dayOffset,
        local.hour,
        local.minute,
        local.second,
      );
    }
    return result;
  }

  /// Calculates prayer times for [days] consecutive days starting at the
  /// current calendar date in the user's timezone.
  ///
  /// A day whose valid sequence cannot be established (see
  /// [calculateForDate]) is skipped rather than aborting the whole range —
  /// [onInvalidDay], when provided, is called with the skipped date and the
  /// error so callers can log/report it. This must never happen for real
  /// Earth coordinates (see class docs) but is handled defensively so one
  /// pathological day can never take down the rest of the schedule.
  List<PrayerDayTimes> calculateRange(
    PrayerSettings settings, {
    DateTime? from,
    int days = 7,
    void Function(DateTime date, Object error)? onInvalidDay,
  }) {
    final location = tz.getLocation(settings.timezone!);
    final start = from ?? tz.TZDateTime.now(location);
    final startDate = DateTime(start.year, start.month, start.day);

    final result = <PrayerDayTimes>[];
    for (var i = 0; i < days; i++) {
      // Add days on the pure date; avoids DST hour-shift issues.
      final date = DateTime(startDate.year, startDate.month, startDate.day + i);
      try {
        result.add(calculateForDate(settings, date));
      } catch (e) {
        onInvalidDay?.call(date, e);
      }
    }
    return result;
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
    PrayerSettings settings,
  ) {
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

    params.madhab =
        settings.asrMethod == AsrMethod.hanafi
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
