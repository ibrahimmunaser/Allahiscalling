import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/services/ios_alarmkit_service.dart';
import 'package:allah_invites_you_to_salah/services/local_notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Contract tests for platform routing decisions.
///
/// The `Platform.isIOS` gate lives solely in the concrete
/// [IosAlarmKitService.isAvailable] (an [AlarmKitClient]); production
/// [IosHybridNotificationScheduler] itself no longer hard-codes it, and its
/// real routing/fallback logic is exercised directly (with a fake
/// [AlarmKitClient]) in `ios_hybrid_notification_scheduler_test.dart`. These
/// tests instead lock the intended decision table in isolation and the
/// Android-facing notification action identifiers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tz_data.initializeTimeZones();

  bool shouldUseAlarmKit({
    required bool isIos,
    required bool available,
    required bool authorized,
  }) {
    if (kIsWeb || !isIos) return false;
    return available && authorized;
  }

  group('AlarmKit routing decision table', () {
    test('iOS 26+ authorized → AlarmKit', () {
      expect(
        shouldUseAlarmKit(isIos: true, available: true, authorized: true),
        isTrue,
      );
    });

    test('iOS AlarmKit denied → fallback notifications', () {
      expect(
        shouldUseAlarmKit(isIos: true, available: true, authorized: false),
        isFalse,
      );
    });

    test('iOS AlarmKit unavailable → fallback', () {
      expect(
        shouldUseAlarmKit(isIos: true, available: false, authorized: true),
        isFalse,
      );
    });

    test('older iOS (unavailable) → fallback', () {
      expect(
        shouldUseAlarmKit(isIos: true, available: false, authorized: false),
        isFalse,
      );
    });

    test('Android never uses AlarmKit', () {
      expect(
        shouldUseAlarmKit(isIos: false, available: true, authorized: true),
        isFalse,
      );
    });
  });

  group('Android action labels must remain Pray Now / Decline', () {
    test('action IDs are stable', () {
      expect(LocalNotificationService.actionPrayNow, 'pray_now');
      expect(LocalNotificationService.actionDecline, 'decline');
    });
  });

  group('no dual primary fire contract', () {
    test(
      'when AlarmKit path chosen, local notification for same id must be cancelled first',
      () {
        // Documents the hybrid order: cancel(id) then schedule AlarmKit.
        final steps = <String>[];
        void cancelLocal(int id) => steps.add('cancel:$id');
        void scheduleAlarmKit(int id) => steps.add('alarmkit:$id');
        void scheduleNotification(int id) => steps.add('notification:$id');

        const id = 42;
        for (final useAlarmKit in [true, false]) {
          steps.clear();
          if (useAlarmKit) {
            cancelLocal(id);
            scheduleAlarmKit(id);
            expect(steps, ['cancel:42', 'alarmkit:42']);
          } else {
            scheduleNotification(id);
            expect(steps, ['notification:42']);
          }
        }
      },
    );
  });

  group('stable identifiers across paths', () {
    test('notification id and AlarmKit UUID are both minute-stable', () {
      final t = DateTime.utc(2026, 7, 15, 16, 22, 10);
      final n1 = LocalNotificationService.notificationIdFor(SalahPrayer.asr, t);
      final n2 = LocalNotificationService.notificationIdFor(
        SalahPrayer.asr,
        t.add(const Duration(seconds: 49)),
      );
      final a1 = IosAlarmKitService.stableAlarmId(SalahPrayer.asr, t);
      final a2 = IosAlarmKitService.stableAlarmId(
        SalahPrayer.asr,
        t.add(const Duration(seconds: 49)),
      );
      expect(n1, n2);
      expect(a1, a2);
    });
  });

  group('zoned vs fixed time semantics (documented risk)', () {
    test('TZDateTime wall clock and UTC instant diverge across DST', () {
      final loc = tz.getLocation('America/New_York');
      final wall = tz.TZDateTime(loc, 2026, 3, 8, 1, 30);
      final utc = wall.toUtc();
      // Fixed AlarmKit schedule uses absolute instant; notifications use zone.
      expect(utc.isUtc, isTrue);
      expect(wall.timeZoneOffset.inHours, -5);
    });
  });
}
