import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/models/scheduled_reminder.dart';
import 'package:allah_invites_you_to_salah/services/decline_flow.dart';
import 'package:allah_invites_you_to_salah/services/prayer_scheduler_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Decline plan is pure logic shared verbatim by the in-app Decline,
/// the background notification action, and the terminated-app action (the
/// background isolate runs the identical code path). These tests therefore
/// cover foreground, background, and terminated-app Decline behavior.
void main() {
  final now = DateTime(2026, 7, 4, 13, 10); // Dhuhr entered at 13:05.
  final dhuhrTime = DateTime(2026, 7, 4, 13, 5);
  final asrTime = DateTime(2026, 7, 4, 17, 0);

  ScheduledReminder primary(SalahPrayer prayer, DateTime at) =>
      ScheduledReminder(
        notificationId: prayer.index * 1000 + 1,
        prayer: prayer,
        scheduledAtMillis: at.millisecondsSinceEpoch,
      );

  ScheduledReminder followUpFor(SalahPrayer prayer, DateTime prayerAt) =>
      ScheduledReminder(
        notificationId: prayer.index * 1000 + 2,
        prayer: prayer,
        scheduledAtMillis:
            prayerAt
                .add(PrayerSchedulerService.followUpDelay)
                .millisecondsSinceEpoch,
        kind: ReminderKind.followUp,
      );

  group('follow-up cancellation', () {
    test('cancels the current-window follow-up for the declined prayer', () {
      final dhuhrFollowUp = followUpFor(SalahPrayer.dhuhr, dhuhrTime);
      final reminders = [
        dhuhrFollowUp,
        primary(SalahPrayer.asr, asrTime),
        followUpFor(SalahPrayer.asr, asrTime),
      ];

      final plan = planDecline(
        reminders: reminders,
        prayer: SalahPrayer.dhuhr,
        now: now,
        snoozeMinutes: 10,
      );

      expect(plan.followUpIdsToCancel, [dhuhrFollowUp.notificationId]);
      // The cancelled follow-up is removed from persistence.
      expect(
        plan.updatedReminders.any(
          (r) => r.notificationId == dhuhrFollowUp.notificationId,
        ),
        isFalse,
      );
      // Other prayers' reminders are untouched.
      expect(
        plan.updatedReminders.where((r) => r.prayer == SalahPrayer.asr).length,
        2,
      );
    });

    test('does not cancel follow-ups of future occurrences', () {
      // Tomorrow's Dhuhr follow-up: same prayer, different occurrence.
      final tomorrowDhuhr = dhuhrTime.add(const Duration(days: 1));
      final futureFollowUp = followUpFor(SalahPrayer.dhuhr, tomorrowDhuhr);
      final plan = planDecline(
        reminders: [futureFollowUp],
        prayer: SalahPrayer.dhuhr,
        now: now,
        snoozeMinutes: 10,
      );
      expect(plan.followUpIdsToCancel, isEmpty);
      expect(
        plan.updatedReminders.any(
          (r) => r.notificationId == futureFollowUp.notificationId,
        ),
        isTrue,
      );
    });
  });

  group('snooze scheduling', () {
    test('schedules and persists the snooze', () {
      final plan = planDecline(
        reminders: [primary(SalahPrayer.asr, asrTime)],
        prayer: SalahPrayer.dhuhr,
        now: now,
        snoozeMinutes: 10,
      );

      expect(plan.shouldScheduleSnooze, isTrue);
      expect(plan.snoozeFireAt, now.add(const Duration(minutes: 10)));
      final persisted =
          plan.updatedReminders
              .where((r) => r.kind == ReminderKind.snooze)
              .toList();
      expect(persisted, hasLength(1));
      expect(persisted.single.notificationId, plan.snoozeId);
      expect(persisted.single.prayer, SalahPrayer.dhuhr);
    });

    test('window still open when the snooze fires before the next prayer', () {
      final plan = planDecline(
        reminders: [primary(SalahPrayer.asr, asrTime)],
        prayer: SalahPrayer.dhuhr,
        now: now,
        snoozeMinutes: 10, // 13:20, well before Asr at 17:00
      );
      expect(plan.windowStillOpen, isTrue);
    });

    test(
      'window closed when the next prayer enters before the snooze fires',
      () {
        final justBeforeAsr = DateTime(2026, 7, 4, 16, 55);
        final plan = planDecline(
          reminders: [primary(SalahPrayer.asr, asrTime)],
          prayer: SalahPrayer.dhuhr,
          now: justBeforeAsr,
          snoozeMinutes: 10, // 17:05, after Asr enters
        );
        expect(plan.windowStillOpen, isFalse);
        // The snooze is still scheduled — with neutral copy downstream.
        expect(plan.shouldScheduleSnooze, isTrue);
      },
    );
  });

  group('duplicate callback idempotency', () {
    test('a second Decline with a pending equivalent snooze is a no-op', () {
      final firstPlan = planDecline(
        reminders: [
          primary(SalahPrayer.asr, asrTime),
          followUpFor(SalahPrayer.dhuhr, dhuhrTime),
        ],
        prayer: SalahPrayer.dhuhr,
        now: now,
        snoozeMinutes: 10,
      );
      expect(firstPlan.shouldScheduleSnooze, isTrue);

      // The callback fires again 30 seconds later (platform duplicate).
      final secondPlan = planDecline(
        reminders: firstPlan.updatedReminders,
        prayer: SalahPrayer.dhuhr,
        now: now.add(const Duration(seconds: 30)),
        snoozeMinutes: 10,
      );

      expect(secondPlan.shouldScheduleSnooze, isFalse);
      expect(secondPlan.snoozeId, isNull);
      // Still exactly one persisted snooze.
      expect(
        secondPlan.updatedReminders.where((r) => r.kind == ReminderKind.snooze),
        hasLength(1),
      );
    });

    test('a snooze for a different prayer does not block', () {
      final ishaSnooze = ScheduledReminder(
        notificationId: 777,
        prayer: SalahPrayer.fajr,
        scheduledAtMillis:
            now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
        kind: ReminderKind.snooze,
      );
      final plan = planDecline(
        reminders: [ishaSnooze],
        prayer: SalahPrayer.dhuhr,
        now: now,
        snoozeMinutes: 10,
      );
      expect(plan.shouldScheduleSnooze, isTrue);
    });
  });

  group('no double reminder after Decline', () {
    test(
      'after Decline exactly one pending reminder exists for the prayer',
      () {
        final reminders = [
          followUpFor(SalahPrayer.dhuhr, dhuhrTime),
          primary(SalahPrayer.asr, asrTime),
        ];

        final plan = planDecline(
          reminders: reminders,
          prayer: SalahPrayer.dhuhr,
          now: now,
          snoozeMinutes: 10,
        );

        // The follow-up is gone; only the snooze remains for Dhuhr. The user
        // gets exactly one reminder, not two.
        final dhuhrPending =
            plan.updatedReminders
                .where((r) => r.prayer == SalahPrayer.dhuhr)
                .toList();
        expect(dhuhrPending, hasLength(1));
        expect(dhuhrPending.single.kind, ReminderKind.snooze);
        expect(plan.followUpIdsToCancel, isNotEmpty);
      },
    );
  });
}
