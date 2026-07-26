import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/models/scheduled_reminder.dart';
import 'package:allah_invites_you_to_salah/repositories/prayer_settings_repository.dart';
import 'package:allah_invites_you_to_salah/services/decline_flow.dart';
import 'package:allah_invites_you_to_salah/services/local_notification_service.dart';
import 'package:allah_invites_you_to_salah/services/notification_budget.dart';
import 'package:allah_invites_you_to_salah/services/notification_reconciliation.dart';
import 'package:allah_invites_you_to_salah/services/prayer_scheduler_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

/// Minimal fake covering exactly what [NotificationBudgetCoordinator] uses
/// (`pendingIds` + `cancel`); the scheduling methods are never called by the
/// coordinator directly (callers pass their own `schedule` closure), so they
/// simply satisfy the interface.
class FakeBudgetScheduler implements NotificationScheduler {
  final Set<int> pending;
  final List<int> cancelledIds = [];
  Object? pendingIdsError;

  FakeBudgetScheduler([Set<int>? initial]) : pending = initial ?? {};

  @override
  Future<List<int>> pendingIds() async {
    if (pendingIdsError != null) throw pendingIdsError!;
    return pending.toList();
  }

  @override
  Future<void> cancel(int id) async {
    cancelledIds.add(id);
    pending.remove(id);
  }

  @override
  Future<PrimaryReminderOutcome> schedulePrayerReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  }) async {
    pending.add(id);
    return const PrimaryReminderOutcome.notification();
  }

  @override
  Future<void> scheduleFollowUpReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  }) async => pending.add(id);

  @override
  Future<void> scheduleRefreshReminder({
    required int id,
    required tz.TZDateTime scheduledAt,
  }) async => pending.add(id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 7, 4, 10);

  ScheduledReminder reminder(
    int id, {
    ReminderKind kind = ReminderKind.prayer,
    int minutesFromNow = 60,
    SalahPrayer prayer = SalahPrayer.dhuhr,
  }) => ScheduledReminder(
    notificationId: id,
    prayer: prayer,
    scheduledAtMillis:
        now.add(Duration(minutes: minutesFromNow)).millisecondsSinceEpoch,
    kind: kind,
  );

  group('reconcile (pure)', () {
    test('stale persisted reminder not present in the OS', () {
      final persisted = [reminder(1), reminder(2)];
      final result = reconcile(persisted: persisted, actualPendingIds: {1});

      expect(result.confirmed.map((r) => r.notificationId), [1]);
      expect(result.staleInPersistence.map((r) => r.notificationId), [2]);
      expect(result.orphanedInOs, isEmpty);
    });

    test('OS reminder present but missing from persistence', () {
      final persisted = [reminder(1)];
      final result = reconcile(
        persisted: persisted,
        actualPendingIds: {1, 999},
      );

      expect(result.confirmed.map((r) => r.notificationId), [1]);
      expect(result.staleInPersistence, isEmpty);
      expect(result.orphanedInOs, [999]);
    });

    test('ignoredIds are never reported as orphans', () {
      final result = reconcile(
        persisted: const [],
        actualPendingIds: {LocalNotificationService.testNotificationId},
        ignoredIds: const {LocalNotificationService.testNotificationId},
      );
      expect(result.orphanedInOs, isEmpty);
    });
  });

  group('planAdmission (pure)', () {
    test('exactly 59 pending, then add a snooze: admitted, no eviction', () {
      final reconciled = [for (var i = 0; i < 59; i++) reminder(i)];
      final candidate = reminder(
        1000,
        kind: ReminderKind.snooze,
        minutesFromNow: 10,
      );

      final plan = planAdmission(
        reconciled: reconciled,
        candidate: candidate,
        maxPending: 60,
      );

      expect(plan.admitted, isTrue);
      expect(plan.idsToEvict, isEmpty);
      expect(plan.updatedReminders, hasLength(60));
      expect(plan.updatedReminders, contains(candidate));
    });

    test('exactly 60 pending, then add a snooze: evicts the furthest-out '
        'follow-up first', () {
      final reconciled = [
        for (var i = 0; i < 55; i++) reminder(i),
        reminder(200, kind: ReminderKind.followUp, minutesFromNow: 30),
        reminder(201, kind: ReminderKind.followUp, minutesFromNow: 90),
        reminder(202, kind: ReminderKind.followUp, minutesFromNow: 45),
        reminder(300, kind: ReminderKind.refresh, minutesFromNow: 500),
        reminder(400, kind: ReminderKind.snooze, minutesFromNow: 5),
      ];
      expect(reconciled, hasLength(60));
      final candidate = reminder(
        1000,
        kind: ReminderKind.snooze,
        minutesFromNow: 10,
      );

      final plan = planAdmission(
        reconciled: reconciled,
        candidate: candidate,
        maxPending: 60,
      );

      expect(plan.admitted, isTrue);
      // The follow-up furthest in the future (90 min) is evicted, not the
      // sooner ones, and never the refresh warning or the existing snooze.
      expect(plan.idsToEvict, [201]);
      expect(plan.updatedReminders, hasLength(60));
      expect(
        plan.updatedReminders.where((r) => r.notificationId == 201),
        isEmpty,
      );
      expect(plan.updatedReminders, contains(candidate));
    });

    test('same-ID candidate is a replacement: never evicts', () {
      final reconciled = [for (var i = 0; i < 60; i++) reminder(i)];
      final candidate = ScheduledReminder(
        notificationId: 30,
        prayer: SalahPrayer.asr,
        scheduledAtMillis:
            now.add(const Duration(minutes: 999)).millisecondsSinceEpoch,
      );

      final plan = planAdmission(
        reconciled: reconciled,
        candidate: candidate,
        maxPending: 60,
      );

      expect(plan.isReplacement, isTrue);
      expect(plan.idsToEvict, isEmpty);
      expect(plan.updatedReminders, hasLength(60));
      expect(plan.updatedReminders[30].prayer, SalahPrayer.asr);
    });

    test('nothing evictable (all primaries): candidate is not admitted, '
        'primaries are untouched', () {
      final reconciled = [for (var i = 0; i < 60; i++) reminder(i)];
      final candidate = reminder(
        1000,
        kind: ReminderKind.snooze,
        minutesFromNow: 10,
      );

      final plan = planAdmission(
        reconciled: reconciled,
        candidate: candidate,
        maxPending: 60,
      );

      expect(plan.admitted, isFalse);
      expect(plan.idsToEvict, isEmpty);
      expect(plan.updatedReminders, hasLength(60));
      expect(plan.updatedReminders, isNot(contains(candidate)));
    });

    test('uncapped platform (maxPending null) always admits', () {
      final reconciled = [for (var i = 0; i < 200; i++) reminder(i)];
      final candidate = reminder(1000, kind: ReminderKind.snooze);

      final plan = planAdmission(
        reconciled: reconciled,
        candidate: candidate,
        maxPending: null,
      );

      expect(plan.admitted, isTrue);
      expect(plan.updatedReminders, hasLength(201));
    });
  });

  group('NotificationBudgetCoordinator.admit', () {
    late PrayerSettingsRepository repository;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      repository = PrayerSettingsRepository(
        await SharedPreferences.getInstance(),
      );
    });

    const policy = SchedulingPolicy(daysToSchedule: 7, maxPending: 60);

    test('exactly 59 pending, then add a snooze: admitted with zero '
        'cancellations', () async {
      final persisted = [for (var i = 0; i < 59; i++) reminder(i)];
      final scheduler = FakeBudgetScheduler(
        persisted.map((r) => r.notificationId).toSet(),
      );
      final coordinator = NotificationBudgetCoordinator(
        notificationScheduler: scheduler,
        repository: repository,
        policy: policy,
      );
      final candidate = reminder(
        1000,
        kind: ReminderKind.snooze,
        minutesFromNow: 10,
      );
      var scheduleCalls = 0;

      final admitted = await coordinator.admit(
        persisted: persisted,
        candidate: candidate,
        schedule: () async {
          scheduleCalls++;
          scheduler.pending.add(candidate.notificationId);
        },
      );

      expect(admitted, isTrue);
      expect(scheduleCalls, 1);
      expect(scheduler.cancelledIds, isEmpty);
      expect(repository.loadScheduledReminders(), hasLength(60));
    });

    test('exactly 60 pending, then add a snooze: evicts exactly one '
        'follow-up and stays at 60', () async {
      final persisted = [
        for (var i = 0; i < 58; i++) reminder(i),
        reminder(200, kind: ReminderKind.followUp, minutesFromNow: 90),
        reminder(300, kind: ReminderKind.refresh, minutesFromNow: 500),
      ];
      expect(persisted, hasLength(60));
      final scheduler = FakeBudgetScheduler(
        persisted.map((r) => r.notificationId).toSet(),
      );
      final coordinator = NotificationBudgetCoordinator(
        notificationScheduler: scheduler,
        repository: repository,
        policy: policy,
      );
      final candidate = reminder(
        1000,
        kind: ReminderKind.snooze,
        minutesFromNow: 10,
      );

      final admitted = await coordinator.admit(
        persisted: persisted,
        candidate: candidate,
        schedule: () async => scheduler.pending.add(candidate.notificationId),
      );

      expect(admitted, isTrue);
      expect(scheduler.cancelledIds, [200]);
      final finalList = repository.loadScheduledReminders();
      expect(finalList, hasLength(60));
      expect(finalList.map((r) => r.notificationId), isNot(contains(200)));
      expect(finalList.map((r) => r.notificationId), contains(1000));
    });

    test('stale persisted reminder not present in the OS is dropped, not '
        'cancelled', () async {
      final persisted = [reminder(1), reminder(2)];
      // The OS truth only has id 1 — id 2 already vanished (fired, or was
      // silently dropped) without the app's knowledge.
      final scheduler = FakeBudgetScheduler({1});
      final coordinator = NotificationBudgetCoordinator(
        notificationScheduler: scheduler,
        repository: repository,
        policy: policy,
      );
      final candidate = reminder(
        1000,
        kind: ReminderKind.snooze,
        minutesFromNow: 10,
      );

      await coordinator.admit(
        persisted: persisted,
        candidate: candidate,
        schedule: () async => scheduler.pending.add(candidate.notificationId),
      );

      // No cancel() call for the stale id — it was never in the OS.
      expect(scheduler.cancelledIds, isEmpty);
      final finalList = repository.loadScheduledReminders();
      expect(finalList.map((r) => r.notificationId), [1, 1000]);
    });

    test(
      'OS reminder present but missing from persistence is cancelled',
      () async {
        final persisted = [reminder(1)];
        final scheduler = FakeBudgetScheduler({1, 999});
        final coordinator = NotificationBudgetCoordinator(
          notificationScheduler: scheduler,
          repository: repository,
          policy: policy,
        );
        final candidate = reminder(
          1000,
          kind: ReminderKind.snooze,
          minutesFromNow: 10,
        );

        await coordinator.admit(
          persisted: persisted,
          candidate: candidate,
          schedule: () async => scheduler.pending.add(candidate.notificationId),
        );

        expect(scheduler.cancelledIds, contains(999));
        expect(scheduler.pending, isNot(contains(999)));
      },
    );

    test('duplicate admission of the same candidate at the cap is '
        'idempotent (no second eviction)', () async {
      final persisted = [
        for (var i = 0; i < 58; i++) reminder(i),
        reminder(200, kind: ReminderKind.followUp, minutesFromNow: 90),
        reminder(201, kind: ReminderKind.followUp, minutesFromNow: 120),
      ];
      final scheduler = FakeBudgetScheduler(
        persisted.map((r) => r.notificationId).toSet(),
      );
      final coordinator = NotificationBudgetCoordinator(
        notificationScheduler: scheduler,
        repository: repository,
        policy: policy,
      );
      final candidate = reminder(
        1000,
        kind: ReminderKind.snooze,
        minutesFromNow: 10,
      );

      await coordinator.admit(
        persisted: persisted,
        candidate: candidate,
        schedule: () async => scheduler.pending.add(candidate.notificationId),
      );
      final afterFirst = repository.loadScheduledReminders();
      expect(afterFirst, hasLength(60));
      expect(scheduler.cancelledIds, hasLength(1)); // one follow-up evicted

      // Simulate the duplicate background callback: same candidate ID,
      // called again against the now-persisted state.
      final admittedAgain = await coordinator.admit(
        persisted: afterFirst,
        candidate: candidate,
        schedule: () async => scheduler.pending.add(candidate.notificationId),
      );

      expect(admittedAgain, isTrue);
      // Recognized as a replacement: no further eviction.
      expect(scheduler.cancelledIds, hasLength(1));
      expect(repository.loadScheduledReminders(), hasLength(60));
    });

    test('a failed pendingIds query still admits a new candidate when '
        'persisted usage is well under the cap', () async {
      final persisted = [for (var i = 0; i < 30; i++) reminder(i)];
      final scheduler = FakeBudgetScheduler(
        persisted.map((r) => r.notificationId).toSet(),
      )..pendingIdsError = Exception('channel unavailable');
      final coordinator = NotificationBudgetCoordinator(
        notificationScheduler: scheduler,
        repository: repository,
        policy: policy,
      );
      final candidate = reminder(
        1000,
        kind: ReminderKind.snooze,
        minutesFromNow: 10,
      );
      var scheduleCalls = 0;

      final admitted = await coordinator.admit(
        persisted: persisted,
        candidate: candidate,
        schedule: () async => scheduleCalls++,
      );

      expect(admitted, isTrue);
      expect(scheduleCalls, 1);
      expect(repository.loadScheduledReminders(), hasLength(31));
    });

    test('a failed pendingIds query REFUSES a new non-primary candidate '
        'once persisted usage is already close to the cap', () async {
      // 56/60: within the 5-slot query-failure safety margin.
      final persisted = [for (var i = 0; i < 56; i++) reminder(i)];
      final scheduler = FakeBudgetScheduler(
        persisted.map((r) => r.notificationId).toSet(),
      )..pendingIdsError = Exception('channel unavailable');
      final coordinator = NotificationBudgetCoordinator(
        notificationScheduler: scheduler,
        repository: repository,
        policy: policy,
      );
      final candidate = reminder(
        1000,
        kind: ReminderKind.snooze,
        minutesFromNow: 10,
      );
      var scheduleCalls = 0;

      final admitted = await coordinator.admit(
        persisted: persisted,
        candidate: candidate,
        schedule: () async => scheduleCalls++,
      );

      expect(admitted, isFalse);
      expect(scheduleCalls, 0);
      // Nothing was added, and — flying blind — nothing was evicted either.
      expect(repository.loadScheduledReminders(), hasLength(56));
    });

    test('a failed pendingIds query still admits a same-ID replacement '
        'even at the cap (net-zero, always safe)', () async {
      final existing = reminder(
        1000,
        kind: ReminderKind.snooze,
        minutesFromNow: 999,
      );
      final persisted = [for (var i = 0; i < 59; i++) reminder(i), existing];
      expect(persisted, hasLength(60));
      final scheduler = FakeBudgetScheduler(
        persisted.map((r) => r.notificationId).toSet(),
      )..pendingIdsError = Exception('channel unavailable');
      final coordinator = NotificationBudgetCoordinator(
        notificationScheduler: scheduler,
        repository: repository,
        policy: policy,
      );
      final replacement = reminder(
        1000,
        kind: ReminderKind.snooze,
        minutesFromNow: 10,
      );
      var scheduleCalls = 0;

      final admitted = await coordinator.admit(
        persisted: persisted,
        candidate: replacement,
        schedule: () async => scheduleCalls++,
      );

      expect(admitted, isTrue);
      expect(scheduleCalls, 1);
      final finalList = repository.loadScheduledReminders();
      expect(finalList, hasLength(60));
      expect(
        finalList.firstWhere((r) => r.notificationId == 1000).scheduledAtMillis,
        replacement.scheduledAtMillis,
      );
    });
  });

  group('Decline integration: follow-up cancellation vs. eviction', () {
    late PrayerSettingsRepository repository;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      repository = PrayerSettingsRepository(
        await SharedPreferences.getInstance(),
      );
    });

    const policy = SchedulingPolicy(daysToSchedule: 7, maxPending: 60);

    test('Decline where a matching follow-up exists: cancelling it frees '
        'the exact slot the snooze needs (zero further eviction)', () async {
      final dhuhrTime = now.subtract(const Duration(minutes: 5));
      final matchingFollowUp = ScheduledReminder(
        notificationId: 555,
        prayer: SalahPrayer.dhuhr,
        scheduledAtMillis:
            dhuhrTime
                .add(PrayerSchedulerService.followUpDelay)
                .millisecondsSinceEpoch,
        kind: ReminderKind.followUp,
      );
      final others = [for (var i = 0; i < 59; i++) reminder(i)];
      final allReminders = [...others, matchingFollowUp];
      expect(allReminders, hasLength(60));

      final plan = planDecline(
        reminders: allReminders,
        prayer: SalahPrayer.dhuhr,
        now: now,
        snoozeMinutes: 10,
      );
      expect(plan.followUpIdsToCancel, [555]);

      final scheduler = FakeBudgetScheduler(
        allReminders.map((r) => r.notificationId).toSet(),
      );
      // Cancel the matched follow-up exactly as performDecline does.
      for (final id in plan.followUpIdsToCancel) {
        await scheduler.cancel(id);
      }
      final beforeCandidate =
          plan.updatedReminders
              .where((r) => r.notificationId != plan.snoozeId)
              .toList();
      expect(beforeCandidate, hasLength(59));

      final coordinator = NotificationBudgetCoordinator(
        notificationScheduler: scheduler,
        repository: repository,
        policy: policy,
      );
      final snoozeCandidate = ScheduledReminder(
        notificationId: plan.snoozeId!,
        prayer: SalahPrayer.dhuhr,
        scheduledAtMillis: plan.snoozeFireAt!.millisecondsSinceEpoch,
        kind: ReminderKind.snooze,
      );

      await coordinator.admit(
        persisted: beforeCandidate,
        candidate: snoozeCandidate,
        schedule:
            () async => scheduler.pending.add(snoozeCandidate.notificationId),
      );

      // Only the matched follow-up was ever cancelled — no additional
      // eviction was necessary.
      expect(scheduler.cancelledIds, [555]);
      expect(repository.loadScheduledReminders(), hasLength(60));
    });

    test('Decline where no matching follow-up exists: the snooze addition '
        'must evict an unrelated follow-up instead', () async {
      final unrelatedFollowUp = ScheduledReminder(
        notificationId: 777,
        prayer: SalahPrayer.isha,
        scheduledAtMillis:
            now.add(const Duration(minutes: 300)).millisecondsSinceEpoch,
        kind: ReminderKind.followUp,
      );
      final others = [for (var i = 0; i < 59; i++) reminder(i)];
      final allReminders = [...others, unrelatedFollowUp];
      expect(allReminders, hasLength(60));

      final plan = planDecline(
        reminders: allReminders,
        prayer: SalahPrayer.dhuhr,
        now: now,
        snoozeMinutes: 10,
      );
      // No follow-up matches Dhuhr's current window in this fixture.
      expect(plan.followUpIdsToCancel, isEmpty);

      final scheduler = FakeBudgetScheduler(
        allReminders.map((r) => r.notificationId).toSet(),
      );
      final beforeCandidate =
          plan.updatedReminders
              .where((r) => r.notificationId != plan.snoozeId)
              .toList();
      expect(beforeCandidate, hasLength(60));

      final coordinator = NotificationBudgetCoordinator(
        notificationScheduler: scheduler,
        repository: repository,
        policy: policy,
      );
      final snoozeCandidate = ScheduledReminder(
        notificationId: plan.snoozeId!,
        prayer: SalahPrayer.dhuhr,
        scheduledAtMillis: plan.snoozeFireAt!.millisecondsSinceEpoch,
        kind: ReminderKind.snooze,
      );

      final admitted = await coordinator.admit(
        persisted: beforeCandidate,
        candidate: snoozeCandidate,
        schedule:
            () async => scheduler.pending.add(snoozeCandidate.notificationId),
      );

      expect(admitted, isTrue);
      // The unrelated follow-up (the only evictable entry) was sacrificed.
      expect(scheduler.cancelledIds, [777]);
      final finalList = repository.loadScheduledReminders();
      expect(finalList, hasLength(60));
      expect(finalList.map((r) => r.notificationId), isNot(contains(777)));
    });
  });
}
