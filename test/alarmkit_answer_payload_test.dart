import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/services/ios_alarmkit_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure Dart tests for AlarmKit Answer payload parsing and stable IDs.
/// These do not require iOS or a MethodChannel.
void main() {
  group('AlarmKitAnswer.fromMap', () {
    test('parses correct prayer, time, and alarm ID', () {
      final answer = AlarmKitAnswer.fromMap({
        'alarmId': 'a11a0000-0000-4000-8000-000001abcdef',
        'prayerName': 'fajr',
        'scheduledAtISO': '2026-07-15T09:12:00.000Z',
        'prayerDisplayName': 'Fajr Prayer',
      });
      expect(answer.alarmId, 'a11a0000-0000-4000-8000-000001abcdef');
      expect(answer.prayer, SalahPrayer.fajr);
      expect(answer.scheduledAt, DateTime.parse('2026-07-15T09:12:00.000Z'));
      expect(answer.prayerDisplayName, 'Fajr Prayer');
    });

    test('missing prayer name defaults to dhuhr', () {
      final answer = AlarmKitAnswer.fromMap({
        'alarmId': 'id',
        'scheduledAtISO': '2026-07-15T09:12:00.000Z',
      });
      expect(answer.prayer, SalahPrayer.dhuhr);
    });

    test('unknown prayer name defaults to dhuhr', () {
      final answer = AlarmKitAnswer.fromMap({
        'prayerName': 'tahajjud',
        'alarmId': 'id',
      });
      expect(answer.prayer, SalahPrayer.dhuhr);
    });

    test('missing scheduled time yields null scheduledAt', () {
      final answer = AlarmKitAnswer.fromMap({
        'prayerName': 'asr',
        'alarmId': 'id',
      });
      expect(answer.prayer, SalahPrayer.asr);
      expect(answer.scheduledAt, isNull);
    });

    test('empty scheduledAtISO yields null scheduledAt', () {
      final answer = AlarmKitAnswer.fromMap({
        'prayerName': 'maghrib',
        'scheduledAtISO': '',
        'alarmId': 'id',
      });
      expect(answer.scheduledAt, isNull);
    });

    test('invalid date string yields null scheduledAt (no throw)', () {
      final answer = AlarmKitAnswer.fromMap({
        'prayerName': 'isha',
        'scheduledAtISO': 'not-a-date',
        'alarmId': 'id',
      });
      expect(answer.scheduledAt, isNull);
      expect(answer.prayer, SalahPrayer.isha);
    });

    test('missing alarm ID becomes empty string', () {
      final answer = AlarmKitAnswer.fromMap({'prayerName': 'fajr'});
      expect(answer.alarmId, '');
    });

    test('missing display name synthesizes from prayerName', () {
      final answer = AlarmKitAnswer.fromMap({'prayerName': 'fajr'});
      expect(answer.prayerDisplayName, 'fajr Prayer');
    });

    test('display-name prayer resolves via fromName', () {
      final answer = AlarmKitAnswer.fromMap({'prayerName': 'Fajr'});
      expect(answer.prayer, SalahPrayer.fajr);
    });
  });

  group('IosAlarmKitService.stableAlarmId', () {
    test('same prayer + same minute → identical UUID', () {
      final a = DateTime.utc(2026, 7, 15, 9, 12, 30);
      final b = DateTime.utc(2026, 7, 15, 9, 12, 59);
      expect(
        IosAlarmKitService.stableAlarmId(SalahPrayer.fajr, a),
        IosAlarmKitService.stableAlarmId(SalahPrayer.fajr, b),
      );
    });

    test('different prayers at same minute → different UUIDs', () {
      final t = DateTime.utc(2026, 7, 15, 9, 12);
      expect(
        IosAlarmKitService.stableAlarmId(SalahPrayer.fajr, t),
        isNot(IosAlarmKitService.stableAlarmId(SalahPrayer.dhuhr, t)),
      );
    });

    test('adjacent minutes → different UUIDs', () {
      final a = DateTime.utc(2026, 7, 15, 9, 12);
      final b = DateTime.utc(2026, 7, 15, 9, 13);
      expect(
        IosAlarmKitService.stableAlarmId(SalahPrayer.asr, a),
        isNot(IosAlarmKitService.stableAlarmId(SalahPrayer.asr, b)),
      );
    });

    test('local vs UTC same instant → identical UUID', () {
      final utc = DateTime.utc(2026, 3, 8, 14, 0);
      final localish = utc.toLocal();
      expect(
        IosAlarmKitService.stableAlarmId(SalahPrayer.maghrib, utc),
        IosAlarmKitService.stableAlarmId(SalahPrayer.maghrib, localish),
      );
    });

    test('produced string is a valid UUID shape', () {
      final id = IosAlarmKitService.stableAlarmId(
        SalahPrayer.isha,
        DateTime.utc(2026, 12, 31, 23, 59),
      );
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(id),
        isTrue,
        reason: id,
      );
    });

    test(
      'DST spring-forward: same wall clock different UTC → different ids',
      () {
        // America/New_York 2026-03-08: 2:00 AM skipped.
        final before = DateTime.utc(2026, 3, 8, 6, 30); // 1:30 EST
        final after = DateTime.utc(2026, 3, 8, 7, 30); // 3:30 EDT
        expect(
          IosAlarmKitService.stableAlarmId(SalahPrayer.fajr, before),
          isNot(IosAlarmKitService.stableAlarmId(SalahPrayer.fajr, after)),
        );
      },
    );
  });
}
