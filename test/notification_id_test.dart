import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/services/local_notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('deterministic notification IDs', () {
    final time = DateTime.utc(2026, 7, 4, 17, 34);

    test('same prayer occurrence always maps to the same ID', () {
      final a = LocalNotificationService.notificationIdFor(
          SalahPrayer.asr, time);
      final b = LocalNotificationService.notificationIdFor(
          SalahPrayer.asr, time);
      expect(a, b);
    });

    test('different prayers at the same minute get different IDs', () {
      final ids = SalahPrayer.values
          .map((p) => LocalNotificationService.notificationIdFor(p, time))
          .toSet();
      expect(ids, hasLength(SalahPrayer.values.length));
    });

    test('different times get different IDs', () {
      final a = LocalNotificationService.notificationIdFor(
          SalahPrayer.fajr, time);
      final b = LocalNotificationService.notificationIdFor(
          SalahPrayer.fajr, time.add(const Duration(minutes: 1)));
      expect(a, isNot(b));
    });

    test('snooze scheduling uses a distinct ID from the prayer reminder', () {
      final prayerId = LocalNotificationService.notificationIdFor(
          SalahPrayer.maghrib, time);
      final snoozeId = LocalNotificationService.notificationIdFor(
          SalahPrayer.maghrib, time,
          snooze: true);
      expect(snoozeId, isNot(prayerId));
      // Deterministic: re-issuing a snooze for the same minute replaces the
      // old one instead of duplicating it.
      expect(
          LocalNotificationService.notificationIdFor(
              SalahPrayer.maghrib, time,
              snooze: true),
          snoozeId);
    });

    test('follow-up IDs are distinct from prayer and snooze IDs', () {
      final prayerId = LocalNotificationService.notificationIdFor(
          SalahPrayer.asr, time);
      final snoozeId = LocalNotificationService.notificationIdFor(
          SalahPrayer.asr, time,
          snooze: true);
      final followUpId = LocalNotificationService.notificationIdFor(
          SalahPrayer.asr, time,
          followUp: true);
      expect(followUpId, isNot(prayerId));
      expect(followUpId, isNot(snoozeId));
      // Deterministic across calls.
      expect(
          LocalNotificationService.notificationIdFor(SalahPrayer.asr, time,
              followUp: true),
          followUpId);
    });

    test('IDs fit in a signed 32-bit int (Android requirement)', () {
      for (final p in SalahPrayer.values) {
        for (final (snooze, followUp) in [
          (false, false),
          (true, false),
          (false, true),
        ]) {
          final id = LocalNotificationService.notificationIdFor(
              p, DateTime.utc(2099, 12, 31, 23, 59),
              snooze: snooze, followUp: followUp);
          expect(id, lessThan(1 << 31));
          expect(id, greaterThanOrEqualTo(0));
        }
      }
    });
  });
}
