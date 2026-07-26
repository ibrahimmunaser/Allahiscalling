import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/services/ios_alarmkit_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Documents Answer-action routing contracts that Flutter can verify without
/// a device. Cold-start / navigator behavior remains Not Run on Windows.
void main() {
  group('Answer payload → prayer screen inputs', () {
    AlarmKitAnswer parse(Map<String, dynamic> map) =>
        AlarmKitAnswer.fromMap(map);

    test('correct payload yields usable navigation inputs', () {
      final a = parse({
        'alarmId': 'a11a0000-0000-4000-8000-000001abcdef',
        'prayerName': 'maghrib',
        'scheduledAtISO': '2026-07-15T23:45:00.000Z',
        'prayerDisplayName': 'Maghrib Prayer',
      });
      expect(a.prayer, SalahPrayer.maghrib);
      expect(a.alarmId, isNotEmpty);
      expect(a.scheduledAt, isNotNull);
    });

    test('stale alarm (past scheduledAt) still parses — UI must decide', () {
      final a = parse({
        'prayerName': 'fajr',
        'alarmId': 'stale',
        'scheduledAtISO': '2020-01-01T05:00:00.000Z',
      });
      expect(a.scheduledAt!.isBefore(DateTime.now()), isTrue);
      expect(a.prayer, SalahPrayer.fajr);
    });

    test('duplicate Answer events produce equal prayer identity', () {
      final map = {
        'prayerName': 'isha',
        'alarmId': 'dup',
        'scheduledAtISO': '2026-07-15T03:00:00.000Z',
      };
      final a = parse(map);
      final b = parse(map);
      expect(a.prayer, b.prayer);
      expect(a.alarmId, b.alarmId);
      expect(a.scheduledAt, b.scheduledAt);
    });

    test('Answer before Flutter init: pending map remains parseable later', () {
      // Simulates UserDefaults payload read after runApp.
      final pending = {
        'alarmId': 'cold',
        'prayerName': 'asr',
        'scheduledAtISO': '2026-07-15T18:00:00.000Z',
        'prayerDisplayName': 'Asr Prayer',
      };
      final later = AlarmKitAnswer.fromMap(pending);
      expect(later.prayer, SalahPrayer.asr);
      expect(later.alarmId, 'cold');
    });

    test('missing fields never throw', () {
      expect(() => AlarmKitAnswer.fromMap({}), returnsNormally);
      expect(
        () => AlarmKitAnswer.fromMap({'prayerName': null}),
        returnsNormally,
      );
    });
  });

  group('re-entrancy guard contract (documented)', () {
    test(
      'incomingScreenOpen style guard drops second concurrent present',
      () async {
        var open = false;
        var presentations = 0;

        Future<void> present() async {
          if (open) return;
          open = true;
          presentations++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          open = false;
        }

        await Future.wait([present(), present(), present()]);
        expect(presentations, 1);
      },
    );
  });
}
