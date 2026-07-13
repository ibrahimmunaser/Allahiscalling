import 'package:allah_invites_you_to_salah/models/prayer_settings.dart';
import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/models/scheduled_reminder.dart';
import 'package:allah_invites_you_to_salah/repositories/prayer_settings_repository.dart';
import 'package:allah_invites_you_to_salah/services/local_notification_service.dart';
import 'package:allah_invites_you_to_salah/services/prayer_scheduler_service.dart';
import 'package:allah_invites_you_to_salah/services/prayer_time_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// In-memory fake so scheduling can be verified without platform channels.
class FakeNotificationScheduler implements NotificationScheduler {
  final Map<int, ({SalahPrayer prayer, tz.TZDateTime at})> scheduled = {};
  final Map<int, ({SalahPrayer prayer, tz.TZDateTime at})> followUps = {};
  final Map<int, tz.TZDateTime> refreshes = {};
  int scheduleCalls = 0;
  final List<int> cancelled = [];

  int get livePendingCount =>
      scheduled.length + followUps.length + refreshes.length;

  /// Extra IDs to report as pending that are NOT in any of the live maps
  /// above — lets tests simulate an OS notification unknown to persistence
  /// (an orphan) without the fake's other bookkeeping getting confused.
  final Set<int> extraPendingIds = {};

  @override
  Future<List<int>> pendingIds() async => [
        ...scheduled.keys,
        ...followUps.keys,
        ...refreshes.keys,
        ...extraPendingIds,
      ];

  @override
  Future<void> schedulePrayerReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  }) async {
    scheduleCalls++;
    scheduled[id] = (prayer: prayer, at: scheduledAt);
  }

  @override
  Future<void> scheduleFollowUpReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  }) async {
    followUps[id] = (prayer: prayer, at: scheduledAt);
  }

  @override
  Future<void> scheduleRefreshReminder({
    required int id,
    required tz.TZDateTime scheduledAt,
  }) async {
    refreshes[id] = scheduledAt;
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
    followUps.remove(id);
    refreshes.remove(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Initialize eagerly: tz.getLocation below runs before setUpAll would.
  tz_data.initializeTimeZones();

  const settings = PrayerSettings(
    latitude: 40.7128,
    longitude: -74.0060,
    timezone: 'America/New_York',
    calculationMethod: CalculationMethodOption.isna,
  );

  late PrayerSettingsRepository repository;
  late FakeNotificationScheduler fake;

  // Fixed "now": 2026-07-04 10:00 in New York (after Fajr, before Dhuhr).
  final location = tz.getLocation('America/New_York');
  final fixedNow = tz.TZDateTime(location, 2026, 7, 4, 10);

  PrayerSchedulerService buildScheduler(
      {DateTime Function()? now, SchedulingPolicy? policy}) {
    return PrayerSchedulerService(
      prayerTimeService: PrayerTimeService(),
      notificationScheduler: fake,
      repository: repository,
      policy: policy ?? const SchedulingPolicy.android(),
      now: now ?? () => fixedNow,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repository =
        PrayerSettingsRepository(await SharedPreferences.getInstance());
    fake = FakeNotificationScheduler();
  });

  group('scheduling next 7 days', () {
    test('schedules 7 days of prayers minus already-passed ones', () async {
      final scheduler = buildScheduler();
      final reminders = await scheduler.rescheduleAll(settings);
      final prayers =
          reminders.where((r) => r.kind == ReminderKind.prayer).toList();
      final followUps =
          reminders.where((r) => r.kind == ReminderKind.followUp).toList();

      // 7 days x 5 prayers = 35, minus Fajr of day 1 (already passed at
      // 10:00). Dhuhr and later on day 1 are still ahead.
      expect(prayers, hasLength(34));
      expect(fake.scheduled, hasLength(34));

      // Missed-prayer follow-ups: one per prayer 20 minutes in, except day-1
      // Fajr (its follow-up already passed) and day-7 Isha (no known next
      // prayer to bound the window).
      expect(followUps, hasLength(33));
      expect(fake.followUps, hasLength(33));

      // All scheduled strictly in the future.
      for (final r in reminders) {
        expect(r.scheduledAt.isAfter(fixedNow), isTrue);
      }
    });

    test('follow-ups fire 20 minutes after the prayer, within the window',
        () async {
      final scheduler = buildScheduler();
      final reminders = await scheduler.rescheduleAll(settings);
      final prayerTimes = {
        for (final r in reminders.where((r) => r.kind == ReminderKind.prayer))
          (r.prayer, r.scheduledAtMillis)
      };
      for (final f
          in reminders.where((r) => r.kind == ReminderKind.followUp)) {
        final delay = PrayerSchedulerService.followUpDelay.inMilliseconds;
        // Each follow-up is exactly followUpDelay after some occurrence of
        // its prayer (or after a passed occurrence not in the prayer list).
        final matchesAPrayer =
            prayerTimes.contains((f.prayer, f.scheduledAtMillis - delay));
        final isCurrentWindow = f.scheduledAtMillis - delay <=
            fixedNow.millisecondsSinceEpoch;
        expect(matchesAPrayer || isCurrentWindow, isTrue);
      }
    });

    test('persists scheduled IDs and bookkeeping', () async {
      final scheduler = buildScheduler();
      await scheduler.rescheduleAll(settings);

      final persisted = repository.loadScheduledReminders();
      expect(
          persisted.where((r) => r.kind == ReminderKind.prayer), hasLength(34));
      expect(persisted.where((r) => r.kind == ReminderKind.followUp),
          hasLength(33));
      expect(repository.loadLastCalculationDate(), isNotNull);
      expect(repository.loadLastKnownTimezone(), 'America/New_York');
      final coords = repository.loadLastKnownCoordinates();
      expect(coords?.latitude, closeTo(40.7128, 1e-9));
      expect(coords?.longitude, closeTo(-74.0060, 1e-9));
    });
  });

  group('skipping past prayer times', () {
    test('skips everything before "now" late in the day', () async {
      // 23:30: all of today's prayers have passed.
      final lateNow = tz.TZDateTime(location, 2026, 7, 4, 23, 30);
      final scheduler = buildScheduler(now: () => lateNow);
      final reminders = await scheduler.rescheduleAll(settings);
      final prayers =
          reminders.where((r) => r.kind == ReminderKind.prayer).toList();

      // Only days 2-7 remain: 6 x 5 = 30.
      expect(prayers, hasLength(30));
      final first = reminders
          .reduce((a, b) => a.scheduledAtMillis < b.scheduledAtMillis ? a : b);
      expect(first.prayer, SalahPrayer.fajr);
      expect(first.scheduledAt.isAfter(lateNow), isTrue);
    });
  });

  group('duplicate notification prevention', () {
    test('rescheduling cancels old reminders before scheduling new ones',
        () async {
      final scheduler = buildScheduler();
      final first = await scheduler.rescheduleAll(settings);
      final second = await scheduler.rescheduleAll(settings);

      // Old IDs were cancelled.
      expect(fake.cancelled.toSet(),
          first.map((r) => r.notificationId).toSet());
      // No duplicate live notifications: the live maps hold exactly the
      // second batch (prayers + follow-ups + refresh safety notification).
      expect(fake.livePendingCount, second.length);
      // Deterministic IDs: same inputs give same IDs across runs.
      expect(second.map((r) => r.notificationId).toSet(),
          first.map((r) => r.notificationId).toSet());
    });

    test('scheduled IDs are unique within a batch', () async {
      final scheduler = buildScheduler();
      final reminders = await scheduler.rescheduleAll(settings);
      final ids = reminders.map((r) => r.notificationId).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });
  });

  group('notifications disabled or unconfigured', () {
    test('cancels everything and schedules nothing when disabled', () async {
      final scheduler = buildScheduler();
      await scheduler.rescheduleAll(settings);
      expect(fake.scheduled, isNotEmpty);

      final disabled = settings.copyWith(notificationsEnabled: false);
      final reminders = await scheduler.rescheduleAll(disabled);

      expect(reminders, isEmpty);
      expect(fake.scheduled, isEmpty);
      expect(repository.loadScheduledReminders(), isEmpty);
    });

    test('schedules nothing without a location', () async {
      final scheduler = buildScheduler();
      final reminders =
          await scheduler.rescheduleAll(const PrayerSettings(timezone: 'UTC'));
      expect(reminders, isEmpty);
    });
  });

  group('next scheduled reminder', () {
    test('returns the soonest future reminder', () async {
      final scheduler = buildScheduler();
      await scheduler.rescheduleAll(settings);

      final next = scheduler.nextScheduledReminder();
      expect(next, isNotNull);
      expect(next!.prayer, SalahPrayer.dhuhr); // first upcoming after 10:00
      expect(next.scheduledAt.isAfter(fixedNow), isTrue);
    });
  });

  group('iOS scheduling policy (pending-notification cap)', () {
    test('pending count never exceeds 60 with the iOS policy', () async {
      final scheduler =
          buildScheduler(policy: const SchedulingPolicy.ios());
      final reminders = await scheduler.rescheduleAll(settings);

      expect(reminders.length, lessThanOrEqualTo(60));
      expect(fake.livePendingCount, lessThanOrEqualTo(60));
    });

    test('baseline primary reminders are never trimmed to fit the cap',
        () async {
      // Android baseline: how many primaries a full 7-day window contains.
      final androidScheduler =
          buildScheduler(policy: const SchedulingPolicy.android());
      final androidReminders = await androidScheduler.rescheduleAll(settings);
      final baselinePrimaries = androidReminders
          .where((r) => r.kind == ReminderKind.prayer)
          .length;

      SharedPreferences.setMockInitialValues({});
      repository =
          PrayerSettingsRepository(await SharedPreferences.getInstance());
      fake = FakeNotificationScheduler();

      final iosScheduler =
          buildScheduler(policy: const SchedulingPolicy.ios());
      final iosReminders = await iosScheduler.rescheduleAll(settings);
      final iosPrimaries =
          iosReminders.where((r) => r.kind == ReminderKind.prayer).toList();

      // Every baseline (7-day) primary survives, and the dynamic budget
      // fills the remaining capacity with MORE primaries — never fewer.
      expect(iosPrimaries.length, greaterThanOrEqualTo(baselinePrimaries));
      expect(fake.scheduled.length, iosPrimaries.length);
    });

    test('remaining capacity is filled with extra primary days (dynamic)',
        () async {
      final scheduler =
          buildScheduler(policy: const SchedulingPolicy.ios());
      final reminders = await scheduler.rescheduleAll(settings);
      final primaries =
          reminders.where((r) => r.kind == ReminderKind.prayer).toList();
      final followUps =
          reminders.where((r) => r.kind == ReminderKind.followUp).toList();

      // Not hardcoded to seven days: 34 baseline + extension fills the
      // leftover slots (60 - 34 - 10 follow-ups - 1 refresh = 15 more).
      expect(primaries.length, greaterThan(34));
      expect(primaries.length + followUps.length + 1,
          lessThanOrEqualTo(60));
      // Coverage extends beyond 8 days.
      final last = primaries
          .reduce((a, b) => a.scheduledAtMillis > b.scheduledAtMillis ? a : b);
      expect(
          last.scheduledAt.isAfter(fixedNow.add(const Duration(days: 8))),
          isTrue);
    });

    test('the final scheduled primary prayer still exists', () async {
      final scheduler =
          buildScheduler(policy: const SchedulingPolicy.ios());
      final reminders = await scheduler.rescheduleAll(settings);
      final primaries = reminders
          .where((r) => r.kind == ReminderKind.prayer)
          .toList()
        ..sort((a, b) => a.scheduledAtMillis.compareTo(b.scheduledAtMillis));

      final last = primaries.last;
      // The furthest primary is beyond the old 7-day cliff and is genuinely
      // live in the notification system, not just persisted.
      expect(
          last.scheduledAt
              .isAfter(fixedNow.add(const Duration(days: 8))),
          isTrue);
      expect(fake.scheduled.containsKey(last.notificationId), isTrue);
      // The refresh safety notification sits after it.
      final refresh =
          reminders.singleWhere((r) => r.kind == ReminderKind.refresh);
      expect(refresh.scheduledAtMillis, greaterThan(last.scheduledAtMillis));
    });

    test('follow-ups are limited to the 48-hour horizon', () async {
      final scheduler =
          buildScheduler(policy: const SchedulingPolicy.ios());
      final reminders = await scheduler.rescheduleAll(settings);
      final followUps =
          reminders.where((r) => r.kind == ReminderKind.followUp).toList();

      expect(followUps, isNotEmpty);
      final horizon = fixedNow.add(const Duration(hours: 48));
      for (final f in followUps) {
        expect(f.scheduledAt.isAfter(horizon), isFalse,
            reason: 'follow-up for ${f.prayer} at ${f.scheduledAt} is '
                'beyond the 48h horizon');
      }
      // Sanity: far fewer follow-ups than the 7-day Android schedule (~33).
      expect(followUps.length, lessThanOrEqualTo(11));
    });

    test('a tight cap trims only follow-ups, furthest-out first', () async {
      const tightPolicy = SchedulingPolicy(
        daysToSchedule: 7,
        followUpHorizon: Duration(hours: 48),
        maxPending: 40,
      );
      final scheduler = buildScheduler(policy: tightPolicy);
      final reminders = await scheduler.rescheduleAll(settings);

      final primaries =
          reminders.where((r) => r.kind == ReminderKind.prayer).toList();
      final followUps =
          reminders.where((r) => r.kind == ReminderKind.followUp).toList();

      expect(reminders.length, lessThanOrEqualTo(40));
      // All 34 primaries survive; follow-ups absorb the entire cut.
      expect(primaries, hasLength(34));
      // 40 - 34 primaries - 1 refresh = 5 follow-up slots.
      expect(followUps, hasLength(5));
      // The remaining follow-ups are the soonest ones.
      final keptTimes = followUps.map((f) => f.scheduledAtMillis).toList();
      final maxKept = keptTimes.reduce((a, b) => a > b ? a : b);
      expect(
          maxKept,
          lessThan(fixedNow
              .add(const Duration(hours: 48))
              .millisecondsSinceEpoch));
    });

    test('carried snoozes reserve slots that would otherwise hold primaries',
        () async {
      final scheduler =
          buildScheduler(policy: const SchedulingPolicy.ios());
      // Baseline run to learn the unconstrained totals.
      final unconstrained = await scheduler.rescheduleAll(settings);
      final basePrimaries =
          unconstrained.where((r) => r.kind == ReminderKind.prayer).length;

      // Add three pending future snoozes; they must survive AND consume
      // budget, shrinking the primary extension by exactly three.
      final existing = repository.loadScheduledReminders();
      final snoozes = [
        for (var i = 0; i < 3; i++)
          ScheduledReminder(
            notificationId: 990000 + i,
            prayer: SalahPrayer.dhuhr,
            scheduledAtMillis: fixedNow
                .add(Duration(minutes: 10 + i))
                .millisecondsSinceEpoch,
            kind: ReminderKind.snooze,
          ),
      ];
      await repository.saveScheduledReminders([...existing, ...snoozes]);

      final reminders = await scheduler.rescheduleAll(settings);
      final primaries =
          reminders.where((r) => r.kind == ReminderKind.prayer).length;
      final keptSnoozes =
          reminders.where((r) => r.kind == ReminderKind.snooze).length;

      expect(keptSnoozes, 3);
      expect(reminders.length, lessThanOrEqualTo(60));
      expect(primaries, basePrimaries - 3);
    });

    test('degenerate cap smaller than the baseline still never exceeds it',
        () async {
      const degenerate = SchedulingPolicy(
        daysToSchedule: 7,
        followUpHorizon: Duration(hours: 48),
        maxPending: 20,
      );
      final scheduler = buildScheduler(policy: degenerate);
      final reminders = await scheduler.rescheduleAll(settings);

      final primaries = reminders
          .where((r) => r.kind == ReminderKind.prayer)
          .toList()
        ..sort((a, b) => a.scheduledAtMillis.compareTo(b.scheduledAtMillis));
      final followUps =
          reminders.where((r) => r.kind == ReminderKind.followUp).toList();

      expect(reminders.length, lessThanOrEqualTo(20));
      // Every follow-up was sacrificed before any primary.
      expect(followUps, isEmpty);
      // 20 - 1 refresh = 19 primaries, and they are the SOONEST ones.
      expect(primaries, hasLength(19));
      expect(
          primaries.first.scheduledAt.isBefore(
              primaries.last.scheduledAt),
          isTrue);
      // The soonest upcoming prayer (Dhuhr today) was kept.
      expect(primaries.first.prayer, SalahPrayer.dhuhr);
    });
  });

  group('rolling-window replenishment (seven-day cliff)', () {
    test('a refresh safety notification is scheduled after the last primary',
        () async {
      final scheduler = buildScheduler();
      final reminders = await scheduler.rescheduleAll(settings);

      final refresh = reminders
          .where((r) => r.kind == ReminderKind.refresh)
          .toList();
      expect(refresh, hasLength(1));
      expect(refresh.single.notificationId,
          LocalNotificationService.refreshReminderId);

      final lastPrimary = reminders
          .where((r) => r.kind == ReminderKind.prayer)
          .reduce((a, b) => a.scheduledAtMillis > b.scheduledAtMillis ? a : b);
      expect(
          refresh.single.scheduledAtMillis,
          lastPrimary.scheduledAtMillis +
              PrayerSchedulerService.refreshReminderDelay.inMilliseconds);
      expect(fake.refreshes,
          containsPair(LocalNotificationService.refreshReminderId, anything));
    });

    test('rescheduling pushes the safety notification forward', () async {
      final scheduler = buildScheduler();
      final first = await scheduler.rescheduleAll(settings);
      final firstRefreshAt = first
          .singleWhere((r) => r.kind == ReminderKind.refresh)
          .scheduledAtMillis;

      // Two days later the user opens the app; the window rolls forward.
      final laterNow = tz.TZDateTime(location, 2026, 7, 6, 10);
      final laterScheduler = buildScheduler(now: () => laterNow);
      final second = await laterScheduler.rescheduleAll(settings);
      final secondRefreshAt = second
          .singleWhere((r) => r.kind == ReminderKind.refresh)
          .scheduledAtMillis;

      expect(secondRefreshAt, greaterThan(firstRefreshAt));
      // Exactly one refresh notification is ever live.
      expect(fake.refreshes, hasLength(1));
    });

    test('replenishment keeps the full primary horizon scheduled', () async {
      final scheduler = buildScheduler();
      await scheduler.rescheduleAll(settings);

      final laterNow = tz.TZDateTime(location, 2026, 7, 8, 10);
      final laterScheduler = buildScheduler(now: () => laterNow);
      final reminders = await laterScheduler.rescheduleAll(settings);

      final lastPrimary = reminders
          .where((r) => r.kind == ReminderKind.prayer)
          .reduce((a, b) => a.scheduledAtMillis > b.scheduledAtMillis ? a : b);
      // Coverage extends ~7 days past the new "now", not the original one.
      expect(
          lastPrimary.scheduledAt
              .isAfter(laterNow.add(const Duration(days: 6))),
          isTrue);
    });

    test('no refresh notification when nothing is scheduled', () async {
      final scheduler = buildScheduler();
      await scheduler
          .rescheduleAll(settings.copyWith(notificationsEnabled: false));
      expect(fake.refreshes, isEmpty);
    });
  });

  group('user-requested snoozes survive rescheduling', () {
    test('future snoozes are kept, expired ones are dropped', () async {
      final scheduler = buildScheduler();
      await scheduler.rescheduleAll(settings);

      // Simulate persisted snoozes: one future, one already fired.
      final existing = repository.loadScheduledReminders();
      final futureSnooze = ScheduledReminder(
        notificationId: 999901,
        prayer: SalahPrayer.dhuhr,
        scheduledAtMillis:
            fixedNow.add(const Duration(minutes: 10)).millisecondsSinceEpoch,
        kind: ReminderKind.snooze,
      );
      final expiredSnooze = ScheduledReminder(
        notificationId: 999902,
        prayer: SalahPrayer.fajr,
        scheduledAtMillis: fixedNow
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        kind: ReminderKind.snooze,
      );
      await repository
          .saveScheduledReminders([...existing, futureSnooze, expiredSnooze]);

      final reminders = await scheduler.rescheduleAll(settings);
      final snoozes =
          reminders.where((r) => r.kind == ReminderKind.snooze).toList();

      expect(snoozes, hasLength(1));
      expect(snoozes.single.notificationId, 999901);
      // The future snooze was NOT cancelled; the expired one was.
      expect(fake.cancelled, isNot(contains(999901)));
      expect(fake.cancelled, contains(999902));
    });
  });

  group('recalculation triggers', () {
    test('recalculation is due after midnight rollover', () async {
      final scheduler = buildScheduler();
      await scheduler.rescheduleAll(settings);
      expect(scheduler.isRecalculationDue(settings), isFalse);

      // Same service but the clock has rolled past midnight.
      final nextDay = tz.TZDateTime(location, 2026, 7, 5, 0, 5);
      final laterScheduler = buildScheduler(now: () => nextDay);
      expect(laterScheduler.isRecalculationDue(settings), isTrue);
    });

    test('significant location change is detected', () async {
      final scheduler = buildScheduler();
      await scheduler.rescheduleAll(settings);

      // Same city: not significant.
      expect(
          scheduler.hasLocationChangedSignificantly(40.72, -74.01), isFalse);
      // Philadelphia (~130 km away): significant.
      expect(
          scheduler.hasLocationChangedSignificantly(39.9526, -75.1652),
          isTrue);
      // No stored coordinates: treated as changed.
      SharedPreferences.setMockInitialValues({});
    });
  });
}
