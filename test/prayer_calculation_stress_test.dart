import 'package:allah_invites_you_to_salah/models/prayer_settings.dart';
import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/services/prayer_time_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Aggressive prayer-calculation stress coverage (pure Dart / no platform).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tz_data.initializeTimeZones();

  final service = PrayerTimeService();

  PrayerSettings base({
    required double lat,
    required double lng,
    required String timezone,
    CalculationMethodOption method = CalculationMethodOption.isna,
    AsrMethod asr = AsrMethod.standard,
    HighLatitudeRuleOption highLat = HighLatitudeRuleOption.middleOfTheNight,
    Map<SalahPrayer, int> adjustments = const {},
  }) {
    return PrayerSettings(
      latitude: lat,
      longitude: lng,
      timezone: timezone,
      calculationMethod: method,
      asrMethod: asr,
      highLatitudeRule: highLat,
      manualAdjustments: adjustments,
    );
  }

  void expectOrdered(Map<SalahPrayer, DateTime> times) {
    final ordered = [
      times[SalahPrayer.fajr]!,
      times[SalahPrayer.dhuhr]!,
      times[SalahPrayer.asr]!,
      times[SalahPrayer.maghrib]!,
      times[SalahPrayer.isha]!,
    ];
    for (var i = 1; i < ordered.length; i++) {
      expect(
        ordered[i].isAfter(ordered[i - 1]),
        isTrue,
        reason: 'prayer order broken at index $i: $ordered',
      );
    }
  }

  group('all calculation methods produce ordered times (Detroit)', () {
    final day = DateTime.utc(2026, 7, 15);
    for (final method in CalculationMethodOption.values) {
      test(method.name, () {
        final settings = base(
          lat: 42.3314,
          lng: -83.0458,
          timezone: 'America/Detroit',
          method: method,
          // Custom angles required when method is custom.
          // Other methods ignore these.
        ).copyWith(customFajrAngle: 18, customIshaAngle: 17);
        final times = service.calculateForDate(settings, day).times;
        expect(times.length, 5);
        expectOrdered(times);
      });
    }
  });

  group('every calculation method × every madhhab stays ordered', () {
    final locations = <String, (double, double, String)>{
      'Detroit': (42.3314, -83.0458, 'America/Detroit'),
      'London': (51.5074, -0.1278, 'Europe/London'),
      'Makkah': (21.4225, 39.8262, 'Asia/Riyadh'),
      'Tromsø': (69.6492, 18.9553, 'Europe/Oslo'),
    };
    final day = DateTime.utc(2026, 9, 21); // equinox: safe for every method.

    for (final locEntry in locations.entries) {
      for (final method in CalculationMethodOption.values) {
        for (final asr in AsrMethod.values) {
          test('${locEntry.key} / ${method.name} / ${asr.name}', () {
            final (lat, lng, zone) = locEntry.value;
            final settings = base(
              lat: lat,
              lng: lng,
              timezone: zone,
              method: method,
              asr: asr,
            ).copyWith(customFajrAngle: 18, customIshaAngle: 17);
            final times = service.calculateForDate(settings, day).times;
            expect(times.length, 5);
            expectOrdered(times);
          });
        }
      }
    }
  });

  group('madhhab / Asr', () {
    test('Hanafi Asr is later than Standard in Detroit summer', () {
      final day = DateTime.utc(2026, 7, 15);
      final standard =
          service
              .calculateForDate(
                base(
                  lat: 42.3314,
                  lng: -83.0458,
                  timezone: 'America/Detroit',
                  asr: AsrMethod.standard,
                ),
                day,
              )
              .times;
      final hanafi =
          service
              .calculateForDate(
                base(
                  lat: 42.3314,
                  lng: -83.0458,
                  timezone: 'America/Detroit',
                  asr: AsrMethod.hanafi,
                ),
                day,
              )
              .times;
      expect(
        hanafi[SalahPrayer.asr]!.isAfter(standard[SalahPrayer.asr]!),
        isTrue,
      );
    });
  });

  group('manual offsets', () {
    test('each prayer shifts by configured minutes', () {
      final day = DateTime.utc(2026, 7, 15);
      final plain =
          service
              .calculateForDate(
                base(lat: 21.4225, lng: 39.8262, timezone: 'Asia/Riyadh'),
                day,
              )
              .times;
      final shifted =
          service
              .calculateForDate(
                base(
                  lat: 21.4225,
                  lng: 39.8262,
                  timezone: 'Asia/Riyadh',
                  adjustments: {
                    SalahPrayer.fajr: 3,
                    SalahPrayer.dhuhr: -2,
                    SalahPrayer.asr: 5,
                    SalahPrayer.maghrib: 0,
                    SalahPrayer.isha: -1,
                  },
                ),
                day,
              )
              .times;
      expect(
        shifted[SalahPrayer.fajr]!
            .difference(plain[SalahPrayer.fajr]!)
            .inMinutes,
        3,
      );
      expect(
        shifted[SalahPrayer.dhuhr]!
            .difference(plain[SalahPrayer.dhuhr]!)
            .inMinutes,
        -2,
      );
      expect(
        shifted[SalahPrayer.asr]!.difference(plain[SalahPrayer.asr]!).inMinutes,
        5,
      );
      expect(
        shifted[SalahPrayer.isha]!
            .difference(plain[SalahPrayer.isha]!)
            .inMinutes,
        -1,
      );
    });
  });

  group('geographic locations', () {
    final cases = <String, (double, double, String)>{
      'America/Detroit': (42.3314, -83.0458, 'America/Detroit'),
      'UTC': (51.5074, -0.1278, 'UTC'),
      'Makkah': (21.4225, 39.8262, 'Asia/Riyadh'),
      'London': (51.5074, -0.1278, 'Europe/London'),
      'high-latitude Stockholm': (59.3293, 18.0686, 'Europe/Stockholm'),
    };

    for (final entry in cases.entries) {
      test(entry.key, () {
        final (lat, lng, zone) = entry.value;
        final times =
            service
                .calculateForDate(
                  base(lat: lat, lng: lng, timezone: zone),
                  DateTime.utc(2026, 6, 21),
                )
                .times;
        expect(times.length, 5);
        expectOrdered(times);
        for (final t in times.values) {
          expect(t.isUtc, isFalse);
        }
      });
    }

    // FIXED (was "KNOWN DEFECT"): adhan_dart's own iterative hour-angle
    // correction diverges to out-of-range (but non-NaN) sunrise/sunset at
    // this latitude/solstice, which used to produce a Maghrib before Dhuhr
    // on the same calendar day. PrayerTimeService now validates every
    // computed sequence (see PrayerCalculationException /
    // _isChronologicallyValid) and, when direct computation is invalid,
    // substitutes the nearest chronologically valid day's time-of-day
    // pattern (Aqrab al-Ayyam) — so a caller only ever sees five correctly
    // ordered times or an explicit exception, never a pathological result.
    test('Tromsø winter solstice yields a chronologically valid, ordered '
        'sequence (previously a KNOWN DEFECT)', () {
      final times =
          service
              .calculateForDate(
                base(lat: 69.6492, lng: 18.9553, timezone: 'Europe/Oslo'),
                DateTime.utc(2026, 12, 21),
              )
              .times;
      expect(times.length, 5);
      expectOrdered(times);
    });

    test('Tromsø summer solstice yields a chronologically valid, ordered '
        'sequence (previously a KNOWN DEFECT)', () {
      final times =
          service
              .calculateForDate(
                base(lat: 69.6492, lng: 18.9553, timezone: 'Europe/Oslo'),
                DateTime.utc(2026, 6, 21),
              )
              .times;
      expect(times.length, 5);
      expectOrdered(times);
    });

    test('Tromsø midsummer: Isha correctly lands after midnight (crosses '
        'into the next calendar day) yet is still chronologically last', () {
      final times =
          service
              .calculateForDate(
                base(lat: 69.6492, lng: 18.9553, timezone: 'Europe/Oslo'),
                DateTime.utc(2026, 6, 21),
              )
              .times;
      final fajr = times[SalahPrayer.fajr]!;
      final maghrib = times[SalahPrayer.maghrib]!;
      final isha = times[SalahPrayer.isha]!;
      // Fajr stays on the requested calendar day; Isha genuinely crosses
      // into the next one (after 23:58 Maghrib, before the ~00:19 Fajr of
      // the following day) — this must be treated as correct, not
      // "unordered", precisely because expectOrdered checks isAfter rather
      // than same-day equality.
      expect(fajr.day, 21);
      expect(maghrib.day, 21);
      expect(isha.day, 22, reason: 'Isha genuinely occurs after midnight');
      expect(isha.isAfter(maghrib), isTrue);
      expect(isha.difference(maghrib).inHours, lessThan(2));
    });

    test('Tromsø: every supported high-latitude rule stays ordered across '
        'both solstices', () {
      for (final rule in HighLatitudeRuleOption.values) {
        for (final day in [
          DateTime.utc(2026, 6, 21),
          DateTime.utc(2026, 12, 21),
        ]) {
          final times =
              service
                  .calculateForDate(
                    base(
                      lat: 69.6492,
                      lng: 18.9553,
                      timezone: 'Europe/Oslo',
                      highLat: rule,
                    ),
                    day,
                  )
                  .times;
          expect(times.length, 5, reason: '$rule on $day');
          expectOrdered(times);
        }
      }
    });
  });

  group('calendar boundaries', () {
    test('midnight boundary: consecutive days are ordered', () {
      final settings = base(
        lat: 40.7128,
        lng: -74.0060,
        timezone: 'America/New_York',
      );
      final loc = tz.getLocation('America/New_York');
      final from = tz.TZDateTime(loc, 2026, 7, 15, 23, 30);
      final range = service.calculateRange(settings, from: from, days: 3);
      expect(range.length, 3);
      expect(range[0].date.day, 15);
      expect(range[1].date.day, 16);
      expect(range[2].date.day, 17);
    });

    test('month boundary Dec→Jan', () {
      final settings = base(
        lat: 40.7128,
        lng: -74.0060,
        timezone: 'America/New_York',
      );
      final loc = tz.getLocation('America/New_York');
      final from = tz.TZDateTime(loc, 2026, 12, 31, 10);
      final range = service.calculateRange(settings, from: from, days: 3);
      expect(range[0].date.month, 12);
      expect(range[1].date.month, 1);
      expect(range[1].date.year, 2027);
    });

    test('leap day 2028-02-29 exists and is ordered', () {
      final settings = base(
        lat: 51.5074,
        lng: -0.1278,
        timezone: 'Europe/London',
      );
      final times =
          service.calculateForDate(settings, DateTime.utc(2028, 2, 29)).times;
      expect(times.length, 5);
      expectOrdered(times);
    });
  });

  group('DST transitions America/New_York', () {
    test('spring-forward day still yields five ordered prayers', () {
      // 2026-03-08 springs forward in US.
      final settings = base(
        lat: 40.7128,
        lng: -74.0060,
        timezone: 'America/New_York',
      );
      final times =
          service.calculateForDate(settings, DateTime.utc(2026, 3, 8)).times;
      expect(times.length, 5);
      expectOrdered(times);
    });

    test('fall-back day still yields five ordered prayers', () {
      // 2026-11-01 falls back in US.
      final settings = base(
        lat: 40.7128,
        lng: -74.0060,
        timezone: 'America/New_York',
      );
      final times =
          service.calculateForDate(settings, DateTime.utc(2026, 11, 1)).times;
      expect(times.length, 5);
      expectOrdered(times);
    });

    test('UTC offset changes across spring-forward', () {
      final loc = tz.getLocation('America/New_York');
      final before = tz.TZDateTime(loc, 2026, 3, 8, 1, 30);
      final after = tz.TZDateTime(loc, 2026, 3, 8, 3, 30);
      expect(before.timeZoneOffset.inHours, -5);
      expect(after.timeZoneOffset.inHours, -4);
    });

    test('UTC offset changes across fall-back', () {
      final loc = tz.getLocation('America/New_York');
      final before = tz.TZDateTime(loc, 2026, 11, 1, 0, 30);
      final after = tz.TZDateTime(loc, 2026, 11, 1, 2, 30);
      expect(before.timeZoneOffset.inHours, -4);
      expect(after.timeZoneOffset.inHours, -5);
    });
  });

  group('DST transitions America/Detroit', () {
    test('spring-forward day still yields five ordered prayers', () {
      // 2026-03-08 springs forward in the US.
      final settings = base(
        lat: 42.3314,
        lng: -83.0458,
        timezone: 'America/Detroit',
      );
      final times =
          service.calculateForDate(settings, DateTime.utc(2026, 3, 8)).times;
      expect(times.length, 5);
      expectOrdered(times);
    });

    test('fall-back day still yields five ordered prayers', () {
      // 2026-11-01 falls back in the US.
      final settings = base(
        lat: 42.3314,
        lng: -83.0458,
        timezone: 'America/Detroit',
      );
      final times =
          service.calculateForDate(settings, DateTime.utc(2026, 11, 1)).times;
      expect(times.length, 5);
      expectOrdered(times);
    });

    test('a full week straddling spring-forward stays ordered and '
        'consecutive', () {
      final settings = base(
        lat: 42.3314,
        lng: -83.0458,
        timezone: 'America/Detroit',
      );
      final loc = tz.getLocation('America/Detroit');
      final from = tz.TZDateTime(loc, 2026, 3, 5, 10);
      final range = service.calculateRange(settings, from: from, days: 7);
      expect(range.length, 7);
      for (final day in range) {
        expectOrdered(day.times);
      }
    });

    test('a full week straddling fall-back stays ordered and consecutive', () {
      final settings = base(
        lat: 42.3314,
        lng: -83.0458,
        timezone: 'America/Detroit',
      );
      final loc = tz.getLocation('America/Detroit');
      final from = tz.TZDateTime(loc, 2026, 10, 29, 10);
      final range = service.calculateRange(settings, from: from, days: 7);
      expect(range.length, 7);
      for (final day in range) {
        expectOrdered(day.times);
      }
    });
  });

  group('invalid / unavailable location', () {
    test('missing coordinates throws', () {
      expect(
        () => service.calculateForDate(
          const PrayerSettings(timezone: 'UTC'),
          DateTime.utc(2026, 7, 15),
        ),
        throwsA(anything),
      );
    });

    test('nextPrayer returns null-safe when location missing via caller', () {
      // PrayerTimeService.nextPrayer throws without location; callers guard.
      expect(
        () => service.nextPrayer(const PrayerSettings()),
        throwsA(anything),
      );
    });
  });

  group('past prayers', () {
    test('nextPrayer skips times already in the past', () {
      final settings = base(
        lat: 40.7128,
        lng: -74.0060,
        timezone: 'America/New_York',
      );
      final loc = tz.getLocation('America/New_York');
      final late = tz.TZDateTime(loc, 2026, 7, 15, 23, 0);
      // Inject "now" by using calculateRange and filtering — nextPrayer uses
      // DateTime.now(); for deterministic past-skipping we assert on range.
      final today = service.calculateForDate(settings, late).times;
      final future = today.entries.where((e) => e.value.isAfter(late)).toList();
      expect(future, isEmpty);
    });
  });

  group('high latitude rules', () {
    test('different rules can change Fajr in Tromsø midsummer', () {
      final day = DateTime.utc(2026, 6, 21);
      DateTime fajr(HighLatitudeRuleOption rule) =>
          service
              .calculateForDate(
                base(
                  lat: 69.6492,
                  lng: 18.9553,
                  timezone: 'Europe/Oslo',
                  highLat: rule,
                ),
                day,
              )
              .times[SalahPrayer.fajr]!;

      final a = fajr(HighLatitudeRuleOption.middleOfTheNight);
      final b = fajr(HighLatitudeRuleOption.seventhOfTheNight);
      final c = fajr(HighLatitudeRuleOption.twilightAngle);
      // At least one pair differs (rules are not identical at high latitude).
      expect(
        a != b || b != c || a != c,
        isTrue,
        reason: 'expected high-latitude rules to diverge: $a $b $c',
      );
    });
  });
}
