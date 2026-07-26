import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/salah_prayer.dart';
import '../models/scheduled_reminder.dart';
import '../repositories/prayer_settings_repository.dart';
import 'ios_hybrid_notification_scheduler.dart';
import 'local_notification_service.dart';
import 'notification_budget.dart';
import 'prayer_scheduler_service.dart';

/// The plan for a single Decline action: which follow-up to cancel and
/// whether/when to schedule the snooze.
///
/// Kept pure (no plugin, no I/O) so foreground Decline, background Decline,
/// and unit tests all share exactly the same logic and cannot drift apart.
class DeclinePlan {
  /// Notification IDs of the current-window follow-ups to cancel.
  final List<int> followUpIdsToCancel;

  /// The persisted reminder list after removing cancelled follow-ups and
  /// adding the new snooze record (when scheduled).
  final List<ScheduledReminder> updatedReminders;

  /// False when an equivalent snooze is already pending (idempotency: the
  /// platform may deliver the same action callback more than once).
  final bool shouldScheduleSnooze;

  /// When the snooze fires. Null when [shouldScheduleSnooze] is false.
  final DateTime? snoozeFireAt;

  /// Deterministic snooze notification ID. Null when not scheduling.
  final int? snoozeId;

  /// Whether the prayer window is still open at [snoozeFireAt], judged by
  /// the persisted schedule (the window closes when the next prayer enters).
  final bool windowStillOpen;

  const DeclinePlan({
    required this.followUpIdsToCancel,
    required this.updatedReminders,
    required this.shouldScheduleSnooze,
    required this.snoozeFireAt,
    required this.snoozeId,
    required this.windowStillOpen,
  });
}

/// Computes everything a Decline must do, from the persisted reminder list.
///
/// Behavior (identical for in-app Decline and the notification action):
/// 1. Cancel the automatic follow-up for the currently open prayer window.
/// 2. Schedule the configured snooze — unless an equivalent snooze is
///    already pending (duplicate action callbacks are ignored).
/// 3. Determine whether the prayer window will still be open at snooze time
///    so the notification copy never claims an expired window is open.
DeclinePlan planDecline({
  required List<ScheduledReminder> reminders,
  required SalahPrayer prayer,
  required DateTime now,
  required int snoozeMinutes,
  Duration followUpDelay = PrayerSchedulerService.followUpDelay,
}) {
  final nowMillis = now.millisecondsSinceEpoch;
  final fireAt = now.add(Duration(minutes: snoozeMinutes));
  final fireAtMillis = fireAt.millisecondsSinceEpoch;

  // 1. Current-window follow-up(s) for this prayer: already entered
  //    (scheduledAt - delay <= now) but not fired yet (scheduledAt > now).
  final followUpIdsToCancel = <int>[];
  final kept = <ScheduledReminder>[];
  var duplicateSnooze = false;
  int? nextPrayerMillis;

  for (final r in reminders) {
    final isCurrentWindowFollowUp =
        r.kind == ReminderKind.followUp &&
        r.prayer == prayer &&
        r.scheduledAtMillis > nowMillis &&
        r.scheduledAtMillis - followUpDelay.inMilliseconds <= nowMillis;
    if (isCurrentWindowFollowUp) {
      followUpIdsToCancel.add(r.notificationId);
      continue;
    }

    // Idempotency: a pending snooze for the same prayer that fires within
    // the same requested interval means this Decline was already handled.
    if (r.kind == ReminderKind.snooze &&
        r.prayer == prayer &&
        r.scheduledAtMillis > nowMillis &&
        r.scheduledAtMillis <= fireAtMillis + Duration.millisecondsPerMinute) {
      duplicateSnooze = true;
    }

    // Track the next primary prayer to judge the window.
    if (r.kind == ReminderKind.prayer && r.scheduledAtMillis > nowMillis) {
      if (nextPrayerMillis == null || r.scheduledAtMillis < nextPrayerMillis) {
        nextPrayerMillis = r.scheduledAtMillis;
      }
    }

    kept.add(r);
  }

  final windowStillOpen =
      nextPrayerMillis == null || fireAtMillis < nextPrayerMillis;

  if (duplicateSnooze) {
    return DeclinePlan(
      followUpIdsToCancel: followUpIdsToCancel,
      updatedReminders: kept,
      shouldScheduleSnooze: false,
      snoozeFireAt: null,
      snoozeId: null,
      windowStillOpen: windowStillOpen,
    );
  }

  final snoozeId = LocalNotificationService.notificationIdFor(
    prayer,
    fireAt,
    snooze: true,
  );
  kept.add(
    ScheduledReminder(
      notificationId: snoozeId,
      prayer: prayer,
      scheduledAtMillis: fireAtMillis,
      kind: ReminderKind.snooze,
    ),
  );

  return DeclinePlan(
    followUpIdsToCancel: followUpIdsToCancel,
    updatedReminders: kept,
    shouldScheduleSnooze: true,
    snoozeFireAt: fireAt,
    snoozeId: snoozeId,
    windowStillOpen: windowStillOpen,
  );
}

/// Applies a full Decline against SharedPreferences and the notification
/// plugin. Safe to call from the background isolate (no widget tree, no
/// AppController) and from the foreground controller.
///
/// The snooze addition goes through [NotificationBudgetCoordinator], which
/// enforces the platform's pending-notification cap (a no-op on platforms
/// with no cap): it reconciles persisted bookkeeping against what the OS
/// actually still has pending, evicts lower-priority notifications if
/// necessary (never a primary prayer reminder), and keeps persistence in
/// sync with every cancellation/addition it makes.
///
/// [notificationScheduler], when supplied, MUST be used for cancellation and
/// reconciliation instead of [notificationService] directly — on iOS 26+
/// this is the hybrid AlarmKit/local scheduler, and a persisted primary may
/// be AlarmKit-backed. Reconciling against [notificationService] alone
/// (which only ever reports local-notification IDs) would make every live
/// AlarmKit primary look stale and silently drop it from persistence the
/// next time this function saves the reminder list. Defaults to
/// [notificationService] so Android and pre-AlarmKit iOS are unaffected.
/// [scheduleSnooze] itself always stays on [notificationService] — snoozes
/// are local notifications on every platform, never AlarmKit.
Future<void> performDecline({
  required SharedPreferences prefs,
  required LocalNotificationService notificationService,
  NotificationScheduler? notificationScheduler,
  required SalahPrayer prayer,
  DateTime Function()? nowFn,
  SchedulingPolicy? policy,
}) async {
  final scheduler = notificationScheduler ?? notificationService;
  final now = (nowFn ?? DateTime.now)();

  // Read the user's snooze preferences straight from stored settings.
  var snoozeMinutes = 10;
  String? timezone;
  final rawSettings = prefs.getString(PrayerSettingsRepository.settingsKey);
  if (rawSettings != null) {
    try {
      final map = jsonDecode(rawSettings) as Map<String, dynamic>;
      snoozeMinutes = (map['snoozeMinutes'] as num?)?.toInt() ?? 10;
      timezone = map['timezone'] as String?;
    } catch (_) {}
  }

  final reminders = _loadReminders(prefs);

  // A fresh scheduler instance (as constructed by both callers of this
  // function) starts with no in-memory AlarmKit tracking; without this, the
  // coordinator's reconciliation below would see every AlarmKit-backed
  // primary as vanished and drop it from persistence. See doc comment.
  if (scheduler is IosHybridNotificationScheduler) {
    scheduler.restoreTrackedAlarmIds(reminders);
  }

  final plan = planDecline(
    reminders: reminders,
    prayer: prayer,
    now: now,
    snoozeMinutes: snoozeMinutes,
  );

  // Cancelling the matching follow-up always happens immediately and frees
  // a slot regardless of the cap — this is what lets a Decline "trade" a
  // follow-up for a snooze at net-zero cost to the budget.
  for (final id in plan.followUpIdsToCancel) {
    await scheduler.cancel(id);
  }

  // `plan.updatedReminders` already has the follow-up(s) above removed and
  // (when scheduling) the new snooze appended; strip the snooze back out to
  // get the persisted state as it stands right before admission.
  final beforeCandidate =
      plan.snoozeId == null
          ? plan.updatedReminders
          : plan.updatedReminders
              .where((r) => r.notificationId != plan.snoozeId)
              .toList();

  if (plan.shouldScheduleSnooze) {
    final repository = PrayerSettingsRepository(prefs);
    final coordinator = NotificationBudgetCoordinator(
      notificationScheduler: scheduler,
      repository: repository,
      policy: policy ?? SchedulingPolicy.forPlatform(),
    );
    final snoozeCandidate = ScheduledReminder(
      notificationId: plan.snoozeId!,
      prayer: prayer,
      scheduledAtMillis: plan.snoozeFireAt!.millisecondsSinceEpoch,
      kind: ReminderKind.snooze,
    );
    await coordinator.admit(
      persisted: beforeCandidate,
      candidate: snoozeCandidate,
      schedule:
          () => notificationService.scheduleSnooze(
            prayer: prayer,
            minutes: snoozeMinutes,
            callStyle: true,
            userTimezone: timezone,
            windowStillOpen: plan.windowStillOpen,
            fireAt: plan.snoozeFireAt,
          ),
      ignoredIds: const {LocalNotificationService.testNotificationId},
    );
  } else {
    // Idempotent no-op path: an equivalent snooze is already pending (a
    // duplicate action callback). Nothing is added and nothing is evicted —
    // only the follow-up cancellation above (if any) is persisted.
    await prefs.setString(
      PrayerSettingsRepository.scheduledRemindersKey,
      jsonEncode([for (final r in beforeCandidate) r.toJson()]),
    );
  }
}

List<ScheduledReminder> _loadReminders(SharedPreferences prefs) {
  final raw = prefs.getString(PrayerSettingsRepository.scheduledRemindersKey);
  if (raw == null) return [];
  try {
    final list = jsonDecode(raw) as List<dynamic>;
    return [
      for (final e in list)
        ScheduledReminder.fromJson(e as Map<String, dynamic>),
    ];
  } catch (_) {
    return [];
  }
}
