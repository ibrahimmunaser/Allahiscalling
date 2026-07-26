import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/models/scheduled_reminder.dart';
import 'package:allah_invites_you_to_salah/services/ios_alarmkit_service.dart';
import 'package:allah_invites_you_to_salah/services/ios_hybrid_notification_scheduler.dart';
import 'package:allah_invites_you_to_salah/services/local_notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Fully controllable fake of the native AlarmKit bridge. Because
/// [IosHybridNotificationScheduler] depends on the [AlarmKitClient]
/// interface (not the concrete, `Platform.isIOS`-gated [IosAlarmKitService]),
/// every routing/fallback branch below is exercised for real on this
/// non-iOS test host — this is genuine Dart-layer coverage of the
/// production hybrid scheduler class, not a parallel documented contract.
class FakeAlarmKitClient implements AlarmKitClient {
  bool available = true;
  bool authorized = true;

  /// When set, [schedulePrayerAlarm] returns this outcome instead of
  /// [AlarmKitOutcome.scheduled].
  AlarmKitOutcome? forcedOutcome;
  Object? forcedError;

  int scheduleCalls = 0;
  final List<String> cancelledIds = [];
  int cancelAllCalls = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> get isAuthorized async => authorized;

  @override
  Future<AlarmKitScheduleResult> schedulePrayerAlarm({
    required SalahPrayer prayer,
    required DateTime scheduledAt,
    String? soundName,
  }) async {
    scheduleCalls++;
    final alarmId = IosAlarmKitService.stableAlarmId(prayer, scheduledAt);
    if (!available) {
      return AlarmKitScheduleResult(
        outcome: AlarmKitOutcome.unavailable,
        alarmId: alarmId,
      );
    }
    if (!authorized) {
      return AlarmKitScheduleResult(
        outcome: AlarmKitOutcome.notAuthorized,
        alarmId: alarmId,
      );
    }
    if (forcedOutcome != null && forcedOutcome != AlarmKitOutcome.scheduled) {
      return AlarmKitScheduleResult(
        outcome: forcedOutcome!,
        alarmId: alarmId,
        error: forcedError,
      );
    }
    return AlarmKitScheduleResult(
      outcome: AlarmKitOutcome.scheduled,
      alarmId: alarmId,
    );
  }

  @override
  Future<void> cancelAlarmId(String alarmId) async {
    cancelledIds.add(alarmId);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
  }
}

/// In-memory fake of the local-notification fallback path.
class FakeLocalScheduler implements NotificationScheduler {
  final Map<int, SalahPrayer> scheduled = {};
  final List<int> cancelled = [];
  bool failNextSchedule = false;

  @override
  Future<PrimaryReminderOutcome> schedulePrayerReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  }) async {
    if (failNextSchedule) {
      failNextSchedule = false;
      return PrimaryReminderOutcome.failed(StateError('local failure'));
    }
    scheduled[id] = prayer;
    return const PrimaryReminderOutcome.notification();
  }

  @override
  Future<void> scheduleFollowUpReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  }) async {}

  @override
  Future<void> scheduleRefreshReminder({
    required int id,
    required tz.TZDateTime scheduledAt,
  }) async {}

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
  }

  @override
  Future<List<int>> pendingIds() async => scheduled.keys.toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tz_data.initializeTimeZones();

  final location = tz.getLocation('America/New_York');
  final scheduledAt = tz.TZDateTime(location, 2026, 7, 15, 13, 5);

  late FakeAlarmKitClient alarmKit;
  late FakeLocalScheduler local;
  late IosHybridNotificationScheduler hybrid;

  setUp(() {
    alarmKit = FakeAlarmKitClient();
    local = FakeLocalScheduler();
    hybrid = IosHybridNotificationScheduler(
      notifications: local,
      alarmKit: alarmKit,
    );
  });

  group('AlarmKit available and authorized', () {
    test('schedules via AlarmKit and reports the alarmKit channel', () async {
      final outcome = await hybrid.schedulePrayerReminder(
        id: 1,
        prayer: SalahPrayer.dhuhr,
        scheduledAt: scheduledAt,
        callStyle: true,
      );
      expect(outcome.channel, PrimaryReminderChannel.alarmKit);
      expect(outcome.alarmKitId, isNotNull);
      expect(alarmKit.scheduleCalls, 1);
      expect(local.scheduled, isEmpty);
    });

    test(
      'cancels a pre-existing local notification only after success',
      () async {
        // Simulate a leftover local notification for this id from a previous
        // fallback run.
        local.scheduled[1] = SalahPrayer.dhuhr;

        await hybrid.schedulePrayerReminder(
          id: 1,
          prayer: SalahPrayer.dhuhr,
          scheduledAt: scheduledAt,
          callStyle: true,
        );

        expect(local.cancelled, contains(1));
      },
    );

    test('pendingIds reports the AlarmKit-backed id', () async {
      await hybrid.schedulePrayerReminder(
        id: 7,
        prayer: SalahPrayer.asr,
        scheduledAt: scheduledAt,
        callStyle: true,
      );
      expect(await hybrid.pendingIds(), contains(7));
    });

    test('cancel() cancels the native alarm, not just the local id', () async {
      await hybrid.schedulePrayerReminder(
        id: 3,
        prayer: SalahPrayer.isha,
        scheduledAt: scheduledAt,
        callStyle: true,
      );
      await hybrid.cancel(3);
      expect(alarmKit.cancelledIds, hasLength(1));
      expect(await hybrid.pendingIds(), isNot(contains(3)));
    });
  });

  group(
    'AlarmKit unavailable / unauthorized: fallback never loses the alert',
    () {
      test('unavailable falls back to a local notification', () async {
        alarmKit.available = false;
        final outcome = await hybrid.schedulePrayerReminder(
          id: 2,
          prayer: SalahPrayer.fajr,
          scheduledAt: scheduledAt,
          callStyle: true,
        );
        expect(outcome.channel, PrimaryReminderChannel.notification);
        expect(local.scheduled[2], SalahPrayer.fajr);
      });

      test('unauthorized falls back to a local notification', () async {
        alarmKit.authorized = false;
        final outcome = await hybrid.schedulePrayerReminder(
          id: 4,
          prayer: SalahPrayer.maghrib,
          scheduledAt: scheduledAt,
          callStyle: true,
        );
        expect(outcome.channel, PrimaryReminderChannel.notification);
        expect(local.scheduled[4], SalahPrayer.maghrib);
      });

      test(
        'native schedule failure falls back to a local notification',
        () async {
          alarmKit.forcedOutcome = AlarmKitOutcome.failed;
          alarmKit.forcedError = 'platform channel error';
          final outcome = await hybrid.schedulePrayerReminder(
            id: 5,
            prayer: SalahPrayer.asr,
            scheduledAt: scheduledAt,
            callStyle: true,
          );
          expect(outcome.channel, PrimaryReminderChannel.notification);
          expect(local.scheduled[5], SalahPrayer.asr);
        },
      );

      test(
        'fallback failure surfaces as failed, never silently swallowed',
        () async {
          alarmKit.available = false;
          local.failNextSchedule = true;
          final outcome = await hybrid.schedulePrayerReminder(
            id: 6,
            prayer: SalahPrayer.dhuhr,
            scheduledAt: scheduledAt,
            callStyle: true,
          );
          expect(outcome.channel, PrimaryReminderChannel.failed);
          expect(outcome.error, isNotNull);
        },
      );

      test(
        'AlarmKit id is not tracked (and not pending) when falling back',
        () async {
          alarmKit.available = false;
          await hybrid.schedulePrayerReminder(
            id: 8,
            prayer: SalahPrayer.isha,
            scheduledAt: scheduledAt,
            callStyle: true,
          );
          // Pending via the local path only, never double-counted.
          expect(await hybrid.pendingIds(), [8]);
        },
      );

      test(
        'a prayer that previously used AlarmKit and now fails over still has '
        'exactly one live alert',
        () async {
          // First reschedule: AlarmKit succeeds.
          await hybrid.schedulePrayerReminder(
            id: 9,
            prayer: SalahPrayer.dhuhr,
            scheduledAt: scheduledAt,
            callStyle: true,
          );
          expect(await hybrid.pendingIds(), [9]);

          // Second reschedule (e.g. AlarmKit access revoked): falls back.
          alarmKit.available = false;
          await hybrid.schedulePrayerReminder(
            id: 9,
            prayer: SalahPrayer.dhuhr,
            scheduledAt: scheduledAt,
            callStyle: true,
          );

          // Exactly one channel carries the alert: local, not AlarmKit.
          expect(local.scheduled[9], SalahPrayer.dhuhr);
          expect(await hybrid.pendingIds(), [9]);
        },
      );
    },
  );

  group('restoreTrackedAlarmIds (cross-restart bookkeeping)', () {
    test('pendingIds is blind to a live AlarmKit primary before restoring', () {
      // A fresh process (or a fresh hybrid instance) has empty in-memory
      // tracking even though a persisted record says id 11 is AlarmKit-
      // backed — this documents why restoreTrackedAlarmIds must run first.
      expect(hybrid.pendingIds(), completion(isNot(contains(11))));
    });

    test(
      'restoring from persistence makes the AlarmKit id visible again',
      () async {
        hybrid.restoreTrackedAlarmIds([
          ScheduledReminder(
            notificationId: 11,
            prayer: SalahPrayer.fajr,
            scheduledAtMillis: scheduledAt.millisecondsSinceEpoch,
            alarmKitId: 'restored-uuid',
          ),
        ]);
        expect(await hybrid.pendingIds(), contains(11));
      },
    );

    test('cancel() after restore reaches the native alarm', () async {
      hybrid.restoreTrackedAlarmIds([
        ScheduledReminder(
          notificationId: 12,
          prayer: SalahPrayer.maghrib,
          scheduledAtMillis: scheduledAt.millisecondsSinceEpoch,
          alarmKitId: 'restored-uuid-2',
        ),
      ]);
      await hybrid.cancel(12);
      expect(alarmKit.cancelledIds, contains('restored-uuid-2'));
    });

    test('restoring twice does not accumulate stale entries', () {
      hybrid.restoreTrackedAlarmIds([
        ScheduledReminder(
          notificationId: 13,
          prayer: SalahPrayer.asr,
          scheduledAtMillis: scheduledAt.millisecondsSinceEpoch,
          alarmKitId: 'a',
        ),
      ]);
      hybrid.restoreTrackedAlarmIds([
        ScheduledReminder(
          notificationId: 14,
          prayer: SalahPrayer.asr,
          scheduledAtMillis: scheduledAt.millisecondsSinceEpoch,
          alarmKitId: 'b',
        ),
      ]);
      expect(hybrid.pendingIds(), completion(isNot(contains(13))));
      expect(hybrid.pendingIds(), completion(contains(14)));
    });
  });

  group('cancelAllAlarmKitAlarms', () {
    test('clears tracking and calls the native cancel-all', () async {
      await hybrid.schedulePrayerReminder(
        id: 20,
        prayer: SalahPrayer.dhuhr,
        scheduledAt: scheduledAt,
        callStyle: true,
      );
      await hybrid.cancelAllAlarmKitAlarms();
      expect(alarmKit.cancelAllCalls, 1);
      expect(await hybrid.pendingIds(), isNot(contains(20)));
    });
  });
}
