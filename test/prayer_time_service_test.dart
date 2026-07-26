import 'package:allah_invites_you_to_salah/models/prayer_settings.dart';
import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/services/prayer_time_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(tz_data.initializeTimeZones);

  final service = PrayerTimeService();

  const newYork = PrayerSettings(
    latitude: 40.7128,
    longitude: -74.0060,
    timezone: 'America/New_York',
    calculationMethod: CalculationMethodOption.isna,
  );

  group('prayer calculation for fixed coordinates/date/timezone', () {
    test('produces ordered, plausible times for New York in July', () {
      final day = service.calculateForDate(newYork, DateTime(2026, 7, 4));

      final fajr = day.timeFor(SalahPrayer.fajr);
      final dhuhr = day.timeFor(SalahPrayer.dhuhr);
      final asr = day.timeFor(SalahPrayer.asr);
      final maghrib = day.timeFor(SalahPrayer.maghrib);
      final isha = day.timeFor(SalahPrayer.isha);

      // Strict ordering.
      expect(fajr.isBefore(dhuhr), isTrue);
      expect(dhuhr.isBefore(asr), isTrue);
      expect(asr.isBefore(maghrib), isTrue);
      expect(maghrib.isBefore(isha), isTrue);

      // All on the requested local date.
      for (final t in [fajr, dhuhr, asr, maghrib, isha]) {
        expect(t.year, 2026);
        expect(t.month, 7);
        expect(t.day, 4);
      }

      // Plausible local windows for NYC in summer (EDT).
      expect(fajr.hour, inInclusiveRange(3, 5));
      expect(dhuhr.hour, inInclusiveRange(12, 13));
      expect(asr.hour, inInclusiveRange(16, 18));
      expect(maghrib.hour, inInclusiveRange(19, 21));
      expect(isha.hour, inInclusiveRange(21, 23));
    });

    test('results are in the requested timezone', () {
      final day = service.calculateForDate(newYork, DateTime(2026, 7, 4));
      final fajr = day.timeFor(SalahPrayer.fajr) as tz.TZDateTime;
      expect(fajr.location.name, 'America/New_York');
    });

    test('throws when location is missing', () {
      const noLocation = PrayerSettings(timezone: 'UTC');
      expect(
        () => service.calculateForDate(noLocation, DateTime(2026, 7, 4)),
        throwsStateError,
      );
    });
  });

  group('manual minute adjustments', () {
    test('shift each prayer by the configured offset', () {
      final adjusted = newYork.copyWith(
        manualAdjustments: {
          SalahPrayer.fajr: 2,
          SalahPrayer.dhuhr: 0,
          SalahPrayer.asr: -1,
          SalahPrayer.maghrib: 0,
          SalahPrayer.isha: 3,
        },
      );

      final date = DateTime(2026, 7, 4);
      final base = service.calculateForDate(newYork, date);
      final shifted = service.calculateForDate(adjusted, date);

      expect(
        shifted.timeFor(SalahPrayer.fajr),
        base.timeFor(SalahPrayer.fajr).add(const Duration(minutes: 2)),
      );
      expect(
        shifted.timeFor(SalahPrayer.dhuhr),
        base.timeFor(SalahPrayer.dhuhr),
      );
      expect(
        shifted.timeFor(SalahPrayer.asr),
        base.timeFor(SalahPrayer.asr).subtract(const Duration(minutes: 1)),
      );
      expect(
        shifted.timeFor(SalahPrayer.maghrib),
        base.timeFor(SalahPrayer.maghrib),
      );
      expect(
        shifted.timeFor(SalahPrayer.isha),
        base.timeFor(SalahPrayer.isha).add(const Duration(minutes: 3)),
      );
    });
  });

  group('Asr Standard vs Hanafi', () {
    test('Hanafi Asr is later than Standard Asr', () {
      final date = DateTime(2026, 7, 4);
      final standard = service.calculateForDate(
        newYork.copyWith(asrMethod: AsrMethod.standard),
        date,
      );
      final hanafi = service.calculateForDate(
        newYork.copyWith(asrMethod: AsrMethod.hanafi),
        date,
      );

      expect(
        hanafi
            .timeFor(SalahPrayer.asr)
            .isAfter(standard.timeFor(SalahPrayer.asr)),
        isTrue,
      );
      // Other prayers are unaffected.
      expect(
        hanafi.timeFor(SalahPrayer.dhuhr),
        standard.timeFor(SalahPrayer.dhuhr),
      );
      expect(
        hanafi.timeFor(SalahPrayer.maghrib),
        standard.timeFor(SalahPrayer.maghrib),
      );
    });
  });

  group('timezone changes', () {
    test('same coordinates in a different timezone give the same instant '
        'but different wall-clock time', () {
      final date = DateTime(2026, 7, 4);
      final localDay = service.calculateForDate(newYork, date);
      final utcDay = service.calculateForDate(
        newYork.copyWith(timezone: 'UTC'),
        date,
      );

      final localDhuhr = localDay.timeFor(SalahPrayer.dhuhr);
      final utcDhuhr = utcDay.timeFor(SalahPrayer.dhuhr);

      // Same physical instant.
      expect(localDhuhr.toUtc(), utcDhuhr.toUtc());
      // Different wall clock (EDT is UTC-4 in July).
      expect(utcDhuhr.hour - localDhuhr.hour, 4);
    });
  });

  group('daylight saving changes', () {
    test('UTC offset changes across the spring-forward boundary', () {
      // US DST starts 2026-03-08 in America/New_York.
      final before =
          service
                  .calculateForDate(newYork, DateTime(2026, 3, 7))
                  .timeFor(SalahPrayer.dhuhr)
              as tz.TZDateTime;
      final after =
          service
                  .calculateForDate(newYork, DateTime(2026, 3, 9))
                  .timeFor(SalahPrayer.dhuhr)
              as tz.TZDateTime;

      expect(before.timeZoneOffset, const Duration(hours: -5));
      expect(after.timeZoneOffset, const Duration(hours: -4));

      // Wall-clock Dhuhr stays around midday on both sides of the change.
      expect(before.hour, inInclusiveRange(11, 13));
      expect(after.hour, inInclusiveRange(12, 14));
    });

    test('UTC offset changes across the fall-back boundary', () {
      // US DST ends 2026-11-01 in America/New_York.
      final before =
          service
                  .calculateForDate(newYork, DateTime(2026, 10, 31))
                  .timeFor(SalahPrayer.dhuhr)
              as tz.TZDateTime;
      final after =
          service
                  .calculateForDate(newYork, DateTime(2026, 11, 2))
                  .timeFor(SalahPrayer.dhuhr)
              as tz.TZDateTime;

      expect(before.timeZoneOffset, const Duration(hours: -4));
      expect(after.timeZoneOffset, const Duration(hours: -5));
    });
  });

  group('calculateRange', () {
    test('returns consecutive days starting today', () {
      final location = tz.getLocation('America/New_York');
      final from = tz.TZDateTime(location, 2026, 7, 4, 10);
      final days = service.calculateRange(newYork, from: from, days: 7);

      expect(days, hasLength(7));
      for (var i = 0; i < 7; i++) {
        expect(days[i].date, DateTime(2026, 7, 4 + i));
      }
    });
  });

  group('high latitude rule', () {
    test('different rules produce different Fajr at high latitude', () {
      const oslo = PrayerSettings(
        latitude: 59.9139,
        longitude: 10.7522,
        timezone: 'Europe/Oslo',
        calculationMethod: CalculationMethodOption.muslimWorldLeague,
      );
      final date = DateTime(2026, 6, 21); // summer solstice

      final middle = service.calculateForDate(
        oslo.copyWith(
          highLatitudeRule: HighLatitudeRuleOption.middleOfTheNight,
        ),
        date,
      );
      final seventh = service.calculateForDate(
        oslo.copyWith(
          highLatitudeRule: HighLatitudeRuleOption.seventhOfTheNight,
        ),
        date,
      );

      expect(
        middle.timeFor(SalahPrayer.fajr),
        isNot(seventh.timeFor(SalahPrayer.fajr)),
      );
    });
  });
}
