import 'package:allah_invites_you_to_salah/models/prayer_settings.dart';
import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/models/scheduled_reminder.dart';
import 'package:allah_invites_you_to_salah/repositories/prayer_settings_repository.dart';
import 'package:allah_invites_you_to_salah/services/ios_alarmkit_service.dart';
import 'package:allah_invites_you_to_salah/services/local_notification_service.dart';
import 'package:allah_invites_you_to_salah/services/prayer_scheduler_service.dart';
import 'package:allah_invites_you_to_salah/services/prayer_time_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// In-memory scheduler that can optionally fail exactly one primary mid-batch
/// and can emulate AlarmKit-vs-notification routing without requiring
/// Platform.isIOS.
class TortureScheduler implements NotificationScheduler {
  final Map<int, ({SalahPrayer prayer, tz.TZDateTime at, String path})>
  primaries = {};
  final Map<int, ({SalahPrayer prayer, tz.TZDateTime at})> followUps = {};
  final Map<int, tz.TZDateTime> refreshes = {};
  final List<int> cancelled = [];
  final Set<int> extraPendingIds = {};

  /// When non-null, [schedulePrayerReminder] returns a failed outcome for
  /// exactly the call immediately after this many successes (call number
  /// `failPrimaryAfter + 1`), then behaves normally for every call after
  /// that — a single, isolated failure, not a hard abort. This mirrors
  /// [PrayerSchedulerService.rescheduleAll]'s contract: a failed outcome
  /// must never throw, and must never stop the remaining primaries in the
  /// batch from being scheduled.
  int? failPrimaryAfter;

  /// When true, primaries are recorded as AlarmKit-path (and NOT in pendingIds).
  bool routePrimariesToAlarmKit = false;

  int primaryScheduleCalls = 0;
  int rescheduleInvocations = 0;

  @override
  Future<List<int>> pendingIds() async {
    if (routePrimariesToAlarmKit) {
      return [...followUps.keys, ...refreshes.keys, ...extraPendingIds];
    }
    return [
      ...primaries.keys,
      ...followUps.keys,
      ...refreshes.keys,
      ...extraPendingIds,
    ];
  }

  @override
  Future<PrimaryReminderOutcome> schedulePrayerReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  }) async {
    primaryScheduleCalls++;
    if (failPrimaryAfter != null &&
        primaryScheduleCalls == failPrimaryAfter! + 1) {
      return PrimaryReminderOutcome.failed(
        StateError('simulated AlarmKit/notification schedule failure'),
      );
    }
    primaries[id] = (
      prayer: prayer,
      at: scheduledAt,
      path: routePrimariesToAlarmKit ? 'alarmkit' : 'notification',
    );
    return routePrimariesToAlarmKit
        ? PrimaryReminderOutcome.alarmKit('fake-alarm-$id')
        : const PrimaryReminderOutcome.notification();
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
    primaries.remove(id);
    followUps.remove(id);
    refreshes.remove(id);
  }

  void resetLive() {
    primaries.clear();
    followUps.clear();
    refreshes.clear();
    cancelled.clear();
    primaryScheduleCalls = 0;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tz_data.initializeTimeZones();

  const settings = PrayerSettings(
    latitude: 40.7128,
    longitude: -74.0060,
    timezone: 'America/New_York',
    calculationMethod: CalculationMethodOption.isna,
  );

  late PrayerSettingsRepository repository;
  late TortureScheduler fake;
  final location = tz.getLocation('America/New_York');
  final fixedNow = tz.TZDateTime(location, 2026, 7, 4, 10);

  PrayerSchedulerService build({
    DateTime Function()? now,
    SchedulingPolicy? policy,
  }) {
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
    repository = PrayerSettingsRepository(
      await SharedPreferences.getInstance(),
    );
    fake = TortureScheduler();
  });

  group('scheduling torture', () {
    test('schedule/cancel cycle 100 times leaves no duplicates', () async {
      final scheduler = build();
      for (var i = 0; i < 100; i++) {
        await scheduler.rescheduleAll(settings);
      }
      final primaries =
          repository
              .loadScheduledReminders()
              .where((r) => r.kind == ReminderKind.prayer)
              .toList();
      final ids = primaries.map((r) => r.notificationId).toSet();
      expect(ids.length, primaries.length);
      // Live map should match last successful schedule, not accumulate.
      expect(fake.primaries.length, primaries.length);
    });

    test('rapid toggle notificationsEnabled on/off', () async {
      final scheduler = build();
      for (var i = 0; i < 20; i++) {
        await scheduler.rescheduleAll(
          settings.copyWith(notificationsEnabled: i.isEven),
        );
      }
      // Ends disabled (i=19 odd → enabled false? 19 is odd → i.isEven false → disabled)
      expect(fake.primaries, isEmpty);
      expect(repository.loadScheduledReminders(), isEmpty);
    });

    test('rapid settings changes during reschedule', () async {
      final scheduler = build();
      final variants = [
        settings,
        settings.copyWith(calculationMethod: CalculationMethodOption.egyptian),
        settings.copyWith(asrMethod: AsrMethod.hanafi),
        settings.copyWith(manualAdjustments: {SalahPrayer.fajr: 2}),
        settings.copyWith(timezone: 'America/Detroit'),
      ];
      for (final v in variants) {
        await scheduler.rescheduleAll(v);
      }
      final ids = fake.primaries.keys.toSet();
      expect(ids.length, fake.primaries.length);
    });

    test(
      'two concurrent reschedules do not leave duplicate live primaries',
      () async {
        final scheduler = build();
        await Future.wait([
          scheduler.rescheduleAll(settings),
          scheduler.rescheduleAll(settings),
        ]);
        final ids = fake.primaries.keys.toSet();
        expect(ids.length, fake.primaries.length);
      },
    );

    test('launch rescheduling twice is idempotent for IDs', () async {
      final scheduler = build();
      final a = await scheduler.rescheduleAll(settings);
      final b = await scheduler.rescheduleAll(settings);
      expect(
        a
            .where((r) => r.kind == ReminderKind.prayer)
            .map((r) => r.notificationId)
            .toSet(),
        b
            .where((r) => r.kind == ReminderKind.prayer)
            .map((r) => r.notificationId)
            .toSet(),
      );
    });

    test('schedule across midnight', () async {
      final nearMidnight = tz.TZDateTime(location, 2026, 7, 4, 23, 50);
      final scheduler = build(now: () => nearMidnight);
      final reminders = await scheduler.rescheduleAll(settings);
      for (final r in reminders.where((r) => r.kind == ReminderKind.prayer)) {
        expect(r.scheduledAt.isAfter(nearMidnight), isTrue);
      }
    });

    test('schedule across DST spring-forward day', () async {
      final spring = tz.TZDateTime(location, 2026, 3, 8, 10);
      final scheduler = build(now: () => spring);
      final reminders = await scheduler.rescheduleAll(settings);
      expect(reminders.where((r) => r.kind == ReminderKind.prayer), isNotEmpty);
      final ids = reminders.map((r) => r.notificationId).toSet();
      expect(ids.length, reminders.length);
    });

    test('iOS max window stays within budget', () async {
      final scheduler = build(policy: const SchedulingPolicy.ios());
      final reminders = await scheduler.rescheduleAll(settings);
      expect(reminders.length, lessThanOrEqualTo(60));
      expect(fake.liveCount, lessThanOrEqualTo(60));
    });

    test('disable all reminders clears primaries and follow-ups', () async {
      final scheduler = build();
      await scheduler.rescheduleAll(settings);
      expect(fake.primaries, isNotEmpty);
      await scheduler.rescheduleAll(
        settings.copyWith(notificationsEnabled: false),
      );
      expect(fake.primaries, isEmpty);
      expect(fake.followUps, isEmpty);
      expect(repository.loadScheduledReminders(), isEmpty);
    });

    test('re-enable after disable restores primaries', () async {
      final scheduler = build();
      await scheduler.rescheduleAll(
        settings.copyWith(notificationsEnabled: false),
      );
      final restored = await scheduler.rescheduleAll(settings);
      expect(restored.where((r) => r.kind == ReminderKind.prayer), isNotEmpty);
    });

    test('two prayers in same UTC minute get distinct notification IDs', () {
      final t = DateTime.utc(2026, 7, 15, 12, 0, 30);
      final a = LocalNotificationService.notificationIdFor(
        SalahPrayer.dhuhr,
        t,
      );
      final b = LocalNotificationService.notificationIdFor(SalahPrayer.asr, t);
      expect(a, isNot(b));
    });

    test(
      'stable AlarmKit UUID and notification ID stay aligned per prayer+minute',
      () {
        final t = DateTime.utc(2026, 7, 15, 12, 0, 15);
        final notif = LocalNotificationService.notificationIdFor(
          SalahPrayer.maghrib,
          t,
        );
        final alarm = IosAlarmKitService.stableAlarmId(SalahPrayer.maghrib, t);
        final notif2 = LocalNotificationService.notificationIdFor(
          SalahPrayer.maghrib,
          t.add(const Duration(seconds: 40)),
        );
        final alarm2 = IosAlarmKitService.stableAlarmId(
          SalahPrayer.maghrib,
          t.add(const Duration(seconds: 40)),
        );
        expect(notif, notif2);
        expect(alarm, alarm2);
      },
    );

    test('corrupt persistence (empty) recovers on next reschedule', () async {
      final scheduler = build();
      await scheduler.rescheduleAll(settings);
      await repository.saveScheduledReminders([]);
      final again = await scheduler.rescheduleAll(settings);
      expect(again.where((r) => r.kind == ReminderKind.prayer), isNotEmpty);
    });

    test('cancellation of unknown ID is a no-op', () async {
      await fake.cancel(999999001);
      expect(fake.cancelled, contains(999999001));
      expect(fake.primaries.containsKey(999999001), isFalse);
    });

    test(
      'one primary failing mid-batch does not abort the remaining prayers',
      () async {
        fake.failPrimaryAfter = 3;
        final scheduler = build();
        final result = await scheduler.rescheduleAll(settings);

        // Every primary after the one simulated failure was still attempted
        // and scheduled — the batch was never aborted.
        expect(fake.primaryScheduleCalls, greaterThan(4));
        expect(fake.primaries.length, fake.primaryScheduleCalls - 1);

        // Follow-ups and the refresh safety warning still ran.
        expect(fake.followUps, isNotEmpty);
        expect(fake.refreshes, isNotEmpty);

        // The failure is reported, never silently swallowed.
        expect(scheduler.lastRescheduleReport?.failedPrayers, hasLength(1));

        // The failed primary is excluded from what gets persisted/returned —
        // an enabled prayer is either alerted or explicitly reported as
        // failed, never silently dropped without a trace.
        expect(
          result.where((r) => r.kind == ReminderKind.prayer).length,
          fake.primaries.length,
        );
      },
    );

    test('partial AlarmKit failure cannot leave an enabled prayer without an '
        'alert: every non-failed prayer is scheduled and the exact failure '
        'count is reported', () async {
      fake.routePrimariesToAlarmKit = true;
      fake.failPrimaryAfter = 5;
      final scheduler = build(policy: const SchedulingPolicy.ios());
      final result = await scheduler.rescheduleAll(settings);

      final scheduledPrimaryIds =
          result
              .where((r) => r.kind == ReminderKind.prayer)
              .map((r) => r.notificationId)
              .toSet();
      // Every scheduled primary actually landed in the fake AlarmKit store.
      for (final id in scheduledPrimaryIds) {
        expect(fake.primaries.containsKey(id), isTrue);
      }
      expect(scheduler.lastRescheduleReport?.failedPrayers, hasLength(1));
      expect(
        scheduler.lastRescheduleReport?.alarmKitCount,
        fake.primaries.length,
      );
    });

    test('AlarmKit-style routing: primaries absent from pendingIds', () async {
      fake.routePrimariesToAlarmKit = true;
      final scheduler = build(policy: const SchedulingPolicy.ios());
      await scheduler.rescheduleAll(settings);
      final pending = await fake.pendingIds();
      for (final id in fake.primaries.keys) {
        expect(pending.contains(id), isFalse);
      }
      // Follow-ups still appear.
      expect(pending, isNotEmpty);
      expect(
        pending.every(fake.followUps.containsKey) ||
            pending.any(fake.refreshes.containsKey),
        isTrue,
      );
    });

    test('location change while scheduled replaces times', () async {
      final scheduler = build();
      final nyc = await scheduler.rescheduleAll(settings);
      final nycDhuhr =
          nyc
              .where(
                (r) =>
                    r.kind == ReminderKind.prayer &&
                    r.prayer == SalahPrayer.dhuhr,
              )
              .first
              .scheduledAtMillis;
      final detroit = await scheduler.rescheduleAll(
        settings.copyWith(
          latitude: 42.3314,
          longitude: -83.0458,
          timezone: 'America/Detroit',
        ),
      );
      final detroitDhuhr =
          detroit
              .where(
                (r) =>
                    r.kind == ReminderKind.prayer &&
                    r.prayer == SalahPrayer.dhuhr,
              )
              .first
              .scheduledAtMillis;
      expect(nycDhuhr, isNot(detroitDhuhr));
    });

    test('timezone change while scheduled replaces wall times', () async {
      final scheduler = build();
      await scheduler.rescheduleAll(settings);
      final shifted = await scheduler.rescheduleAll(
        settings.copyWith(timezone: 'America/Los_Angeles'),
      );
      expect(shifted.where((r) => r.kind == ReminderKind.prayer), isNotEmpty);
    });

    test('clock jump forward skips past prayers', () async {
      var now = fixedNow;
      final scheduler = build(now: () => now);
      await scheduler.rescheduleAll(settings);
      now = tz.TZDateTime(location, 2026, 7, 4, 23, 30);
      final late = await scheduler.rescheduleAll(settings);
      for (final r in late.where((r) => r.kind == ReminderKind.prayer)) {
        expect(r.scheduledAt.isAfter(now), isTrue);
      }
    });

    test(
      'clock jump backward does not schedule duplicates for same slot',
      () async {
        var now = fixedNow;
        final scheduler = build(now: () => now);
        await scheduler.rescheduleAll(settings);
        now = tz.TZDateTime(location, 2026, 7, 4, 6);
        final early = await scheduler.rescheduleAll(settings);
        final ids = early.map((r) => r.notificationId).toSet();
        expect(ids.length, early.length);
      },
    );
  });
}

extension on TortureScheduler {
  int get liveCount => primaries.length + followUps.length + refreshes.length;
}
