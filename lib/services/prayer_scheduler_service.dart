import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/prayer_settings.dart';
import '../models/salah_prayer.dart';
import '../models/scheduled_reminder.dart';
import '../repositories/prayer_settings_repository.dart';
import 'diagnostics_log.dart';
import 'local_notification_service.dart';
import 'notification_reconciliation.dart';
import 'ios_hybrid_notification_scheduler.dart';
import 'prayer_time_service.dart';

/// Aggregated outcome of one [PrayerSchedulerService.rescheduleAll] call:
/// which channel ended up carrying each primary prayer reminder. Exposed via
/// [PrayerSchedulerService.lastRescheduleReport] rather than changing
/// `rescheduleAll`'s return type, so every existing caller (including
/// Android, where every primary is always [notificationCount]) is
/// unaffected.
class RescheduleReport {
  /// Primaries delivered via native AlarmKit alarms.
  final int alarmKitCount;

  /// Primaries delivered via ordinary local notifications — every primary
  /// on Android/pre-iOS-26, plus any iOS 26+ AlarmKit fallback.
  final int notificationCount;

  /// Primaries for which BOTH AlarmKit and the local-notification fallback
  /// failed. Should be exceedingly rare; each is also recorded in
  /// [DiagnosticsLog].
  final List<SalahPrayer> failedPrayers;

  /// Calendar days skipped entirely because [PrayerTimeService] could not
  /// establish a chronologically valid five-prayer sequence (see
  /// [PrayerCalculationException]). Should never happen for real Earth
  /// coordinates; each is also recorded in [DiagnosticsLog].
  final List<DateTime> invalidCalculationDays;

  const RescheduleReport({
    required this.alarmKitCount,
    required this.notificationCount,
    required this.failedPrayers,
    required this.invalidCalculationDays,
  });

  const RescheduleReport.empty()
    : alarmKitCount = 0,
      notificationCount = 0,
      failedPrayers = const [],
      invalidCalculationDays = const [];

  bool get hasFailures =>
      failedPrayers.isNotEmpty || invalidCalculationDays.isNotEmpty;
}

/// Platform-specific scheduling limits.
///
/// iOS keeps only the 64 soonest pending local notifications and silently
/// discards the rest, so the app must own a hard cap well under that. Android
/// has no comparable limit.
class SchedulingPolicy {
  /// Maximum days of primary prayer reminders considered for scheduling.
  /// On capped platforms the coverage is dynamic: after the guaranteed
  /// [baselineDays] of primaries and the reserved snooze/follow-up/refresh
  /// slots, every remaining slot is filled with further primaries,
  /// chronologically, up to this horizon.
  final int daysToSchedule;

  /// Days of primary reminders that are guaranteed: within this window a
  /// primary is NEVER removed to make room for an automatic follow-up
  /// (follow-ups are trimmed furthest-out first instead).
  final int baselineDays;

  /// How far ahead automatic missed-prayer follow-ups may be scheduled.
  /// Null means the full [daysToSchedule] window (Android).
  final Duration? followUpHorizon;

  /// Hard cap on pending notifications owned by this app. Null means no cap
  /// (Android).
  final int? maxPending;

  const SchedulingPolicy({
    required this.daysToSchedule,
    int? baselineDays,
    this.followUpHorizon,
    this.maxPending,
  }) : baselineDays = baselineDays ?? daysToSchedule;

  /// Android: no OS pending limit; schedule the full week of everything.
  const SchedulingPolicy.android() : this(daysToSchedule: 7);

  /// iOS: stay safely under the OS limit of 64 pending notifications.
  /// 7 guaranteed baseline days (~34 primaries) + 48 h of follow-ups (~10)
  /// + active snoozes + one refresh warning ≈ 45; the ~15 remaining slots
  /// are filled with days 8+ primaries, giving roughly 9–10 days of real
  /// coverage instead of a hardcoded 7 — never exceeding the cap of 60.
  const SchedulingPolicy.ios()
    : this(
        daysToSchedule: 12,
        baselineDays: 7,
        followUpHorizon: const Duration(hours: 48),
        maxPending: 60,
      );

  /// The policy for the current platform.
  factory SchedulingPolicy.forPlatform() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return const SchedulingPolicy.ios();
    }
    return const SchedulingPolicy.android();
  }
}

/// Coordinates prayer time calculation and notification scheduling.
///
/// Guarantees:
/// - Schedules the next [SchedulingPolicy.daysToSchedule] days of reminders.
/// - Skips prayer times that have already passed.
/// - Never schedules duplicates (deterministic IDs + cancellation of all
///   previously persisted reminders before rescheduling).
/// - Scheduling priority: primary prayer reminders, then user-requested
///   snoozes, then automatic follow-ups. Primaries are never dropped to make
///   room for lower-priority notifications.
/// - Persists scheduled IDs and calculation bookkeeping.
/// - Schedules a safety notification after the last primary reminder so the
///   schedule never runs out silently; it is cancelled and pushed forward on
///   every successful reschedule.
/// - On capped platforms (iOS), reconciles against the OS's actual pending
///   notifications before recomputing the batch, so an untracked leftover
///   can never silently occupy a slot the budget math doesn't know about.
///   Single-notification operations between reschedules (Decline snoozes)
///   go through [NotificationBudgetCoordinator] instead, which enforces the
///   same cap incrementally — see notification_budget.dart.
class PrayerSchedulerService {
  /// How long after a prayer enters the missed-prayer follow-up fires,
  /// provided the prayer window is still open at that point.
  static const Duration followUpDelay = Duration(minutes: 20);

  /// How long after the final scheduled prayer the refresh safety
  /// notification fires (only if no reschedule happened by then).
  static const Duration refreshReminderDelay = Duration(minutes: 30);

  final PrayerTimeService prayerTimeService;
  final NotificationScheduler notificationScheduler;
  final PrayerSettingsRepository repository;
  final SchedulingPolicy policy;

  /// Overridable clock for tests.
  final DateTime Function() now;

  PrayerSchedulerService({
    required this.prayerTimeService,
    required this.notificationScheduler,
    required this.repository,
    SchedulingPolicy? policy,
    DateTime Function()? now,
  }) : policy = policy ?? SchedulingPolicy.forPlatform(),
       now = now ?? DateTime.now;

  /// Aggregated channel/failure breakdown from the most recent
  /// [rescheduleAll] call. Null until the first call completes.
  RescheduleReport? lastRescheduleReport;

  /// Cancels all previously scheduled reminders (except still-pending
  /// user-requested snoozes, which survive a reschedule) and schedules the
  /// next [SchedulingPolicy.daysToSchedule] days of prayers. Returns the
  /// newly persisted reminders.
  Future<List<ScheduledReminder>> rescheduleAll(PrayerSettings settings) async {
    final enabled =
        settings.notificationsEnabled &&
        settings.hasLocation &&
        settings.timezone != null;

    // Cross-restart bookkeeping: the hybrid scheduler's notificationId →
    // AlarmKit UUID map is in-memory only, so a fresh process must rebuild
    // it from the persisted schedule BEFORE anything below queries
    // pendingIds() or cancels by id — otherwise a still-active AlarmKit
    // primary from a previous session would look stale/orphaned.
    final hybrid = notificationScheduler;
    if (hybrid is IosHybridNotificationScheduler) {
      hybrid.restoreTrackedAlarmIds(repository.loadScheduledReminders());
    }

    // On capped platforms, cancel any OS-pending notification unknown to
    // our persistence FIRST, before deciding what to cancel/keep below.
    // Ground truth is the OS: an untracked leftover (an old code path, a
    // race) would otherwise silently consume a slot under iOS's own limit
    // without the budget math ever seeing it.
    if (policy.maxPending != null) {
      await _cancelOrphans();
    }

    // On iOS 26+, primary prayer alerts live in AlarmKit (not the 64-cap
    // notification pool). Clear them before rebuilding so outdated prayer
    // times never fire after a location/settings/day change.
    if (hybrid is IosHybridNotificationScheduler) {
      await hybrid.cancelAllAlarmKitAlarms();
    }

    // Cancel old reminders first, so stale times never fire even if
    // notifications get disabled or the location changes. Pending snoozes
    // are user-requested and carry over — unless reminders were disabled.
    final carriedSnoozes = await _cancelPersisted(keepFutureSnoozes: enabled);

    if (!enabled) {
      await repository.saveScheduledReminders([]);
      return [];
    }

    final location = tz.getLocation(settings.timezone!);
    final current = tz.TZDateTime.from(now(), location);

    final invalidCalculationDays = <DateTime>[];
    final days = prayerTimeService.calculateRange(
      settings,
      from: current,
      days: policy.daysToSchedule,
      onInvalidDay: (date, error) {
        invalidCalculationDays.add(date);
        debugPrint(
          'Skipping $date: no valid prayer sequence could be calculated '
          '($error).',
        );
        // Fire-and-forget: this callback is synchronous, but recordError
        // is safe to run detached — never blocks scheduling on I/O.
        unawaited(
          DiagnosticsLog.recordError(
            repository.prefs,
            'scheduling',
            'no valid prayer sequence for $date: $error',
          ),
        );
      },
    );

    // Flatten to a chronological list so each prayer knows when the next one
    // enters (the follow-up must never fire after the window closes).
    final allPrayers = <(SalahPrayer, DateTime)>[
      for (final day in days)
        for (final entry in day.orderedEntries) (entry.key, entry.value),
    ];

    final usedIds = <int>{for (final s in carriedSnoozes) s.notificationId};

    // ---- Priority 1: primary prayer reminders (never trimmed). ----
    final primaries = <ScheduledReminder>[];
    for (final (prayer, prayerTime) in allPrayers) {
      if (!prayerTime.isAfter(current)) continue;
      final id = LocalNotificationService.notificationIdFor(prayer, prayerTime);
      // Deterministic IDs make duplicates impossible; the guard below is a
      // safety net in case two computed times collide on the same minute.
      if (!usedIds.add(id)) continue;
      primaries.add(
        ScheduledReminder(
          notificationId: id,
          prayer: prayer,
          scheduledAtMillis: prayerTime.millisecondsSinceEpoch,
        ),
      );
    }

    // ---- Priority 3: automatic follow-ups (short horizon, capped). ----
    final followUpLimit =
        policy.followUpHorizon == null
            ? null
            : current.add(policy.followUpHorizon!);
    final followUps = <ScheduledReminder>[];
    for (var i = 0; i < allPrayers.length; i++) {
      final (prayer, prayerTime) = allPrayers[i];
      final nextPrayerTime =
          i + 1 < allPrayers.length ? allPrayers[i + 1].$2 : null;
      final followUpAt = prayerTime.add(followUpDelay);
      if (nextPrayerTime == null ||
          !followUpAt.isAfter(current) ||
          !followUpAt.isBefore(nextPrayerTime)) {
        continue;
      }
      if (followUpLimit != null && followUpAt.isAfter(followUpLimit)) {
        continue;
      }
      final followUpId = LocalNotificationService.notificationIdFor(
        prayer,
        prayerTime,
        followUp: true,
      );
      if (!usedIds.add(followUpId)) continue;
      followUps.add(
        ScheduledReminder(
          notificationId: followUpId,
          prayer: prayer,
          scheduledAtMillis: followUpAt.millisecondsSinceEpoch,
          kind: ReminderKind.followUp,
        ),
      );
    }

    // Enforce the pending cap dynamically:
    //   reserved slots = carried snoozes (actual count) + one refresh
    //   warning + the short-horizon follow-ups;
    //   guaranteed     = baseline primaries (policy.baselineDays);
    //   remainder      = filled with further primaries, chronologically.
    // Coverage is therefore as many days as safely fit under the cap, not a
    // hardcoded week. If the guaranteed set itself does not fit, follow-ups
    // are trimmed furthest-out first — a baseline primary is NEVER removed
    // to make room for an automatic follow-up.
    if (policy.maxPending != null) {
      const refreshSlot = 1;
      final slots = policy.maxPending! - carriedSnoozes.length - refreshSlot;

      final baselineCutoffMillis =
          current
              .add(Duration(days: policy.baselineDays))
              .millisecondsSinceEpoch;
      final extension = <ScheduledReminder>[];
      primaries.removeWhere((r) {
        if (r.scheduledAtMillis >= baselineCutoffMillis) {
          extension.add(r);
          return true;
        }
        return false;
      });

      // 1. Fit baseline primaries + follow-ups; follow-ups yield first.
      var overflow = primaries.length + followUps.length - slots;
      if (overflow > 0) {
        final followUpCut =
            overflow < followUps.length ? overflow : followUps.length;
        followUps.removeRange(followUps.length - followUpCut, followUps.length);
        overflow -= followUpCut;
        if (overflow > 0) {
          // Degenerate cap smaller than one week of primaries: cap the
          // horizon itself (furthest-out first).
          primaries.removeRange(primaries.length - overflow, primaries.length);
        }
      }

      // 2. Fill every remaining slot with extension primaries.
      final remaining = slots - primaries.length - followUps.length;
      if (remaining > 0 && extension.isNotEmpty) {
        primaries.addAll(extension.take(remaining));
      }
    }

    // Schedule in priority order. Each primary is scheduled independently
    // — a single failure (AlarmKit AND its local fallback both failing) is
    // recorded and skipped, but must never abort the remaining primaries in
    // this batch.
    var alarmKitCount = 0;
    var notificationCount = 0;
    final failedPrayers = <SalahPrayer>[];
    final failedIds = <int>{};
    for (var i = 0; i < primaries.length; i++) {
      final r = primaries[i];
      PrimaryReminderOutcome outcome;
      try {
        outcome = await notificationScheduler.schedulePrayerReminder(
          id: r.notificationId,
          prayer: r.prayer,
          scheduledAt: tz.TZDateTime.from(r.scheduledAt, location),
          callStyle: true,
        );
      } catch (e) {
        // Defensive: NotificationScheduler implementations are contracted
        // not to throw (see its docs), but a single bad primary must never
        // be able to abort the rest of the batch regardless.
        outcome = PrimaryReminderOutcome.failed(e);
      }
      switch (outcome.channel) {
        case PrimaryReminderChannel.alarmKit:
          alarmKitCount++;
          primaries[i] = r.copyWith(alarmKitId: outcome.alarmKitId);
        case PrimaryReminderChannel.notification:
          notificationCount++;
          if (r.alarmKitId != null) {
            primaries[i] = r.copyWith(clearAlarmKitId: true);
          }
        case PrimaryReminderChannel.failed:
          failedPrayers.add(r.prayer);
          failedIds.add(r.notificationId);
          await DiagnosticsLog.recordError(
            repository.prefs,
            'scheduling',
            'primary reminder failed for ${r.prayer.name} at '
                '${r.scheduledAt}: ${outcome.error}',
          );
      }
    }
    lastRescheduleReport = RescheduleReport(
      alarmKitCount: alarmKitCount,
      notificationCount: notificationCount,
      failedPrayers: failedPrayers,
      invalidCalculationDays: invalidCalculationDays,
    );
    // Exclude failed primaries from persistence/stats — neither channel
    // actually carries an alert for them, so recording one would falsely
    // suggest the prayer has a pending reminder.
    final persistedPrimaries =
        failedIds.isEmpty
            ? primaries
            : primaries
                .where((r) => !failedIds.contains(r.notificationId))
                .toList();
    for (final r in followUps) {
      await notificationScheduler.scheduleFollowUpReminder(
        id: r.notificationId,
        prayer: r.prayer,
        scheduledAt: tz.TZDateTime.from(r.scheduledAt, location),
        callStyle: true,
      );
    }

    // Safety net: if the user never opens the app again, tell them the
    // schedule is about to run out instead of going silent. Rescheduling
    // (which happens on every launch/resume/settings change) pushes this
    // notification forward, so it only ever fires when it is truly needed.
    final scheduled = <ScheduledReminder>[
      ...persistedPrimaries,
      ...carriedSnoozes,
      ...followUps,
    ];
    if (persistedPrimaries.isNotEmpty) {
      final lastPrimary = persistedPrimaries.last;
      final refreshAt = lastPrimary.scheduledAt.add(refreshReminderDelay);
      await notificationScheduler.scheduleRefreshReminder(
        id: LocalNotificationService.refreshReminderId,
        scheduledAt: tz.TZDateTime.from(refreshAt, location),
      );
      scheduled.add(
        ScheduledReminder(
          notificationId: LocalNotificationService.refreshReminderId,
          prayer: lastPrimary.prayer,
          scheduledAtMillis: refreshAt.millisecondsSinceEpoch,
          kind: ReminderKind.refresh,
        ),
      );
    }

    assert(
      policy.maxPending == null || scheduled.length <= policy.maxPending!,
      'Scheduled ${scheduled.length} notifications, exceeding the platform '
      'cap of ${policy.maxPending}.',
    );
    if (kDebugMode && policy.maxPending != null) {
      debugPrint(
        'Scheduler: ${scheduled.length}/${policy.maxPending} pending '
        '(${primaries.length} primary, ${carriedSnoozes.length} snooze, '
        '${followUps.length} follow-up, '
        '${primaries.isEmpty ? 0 : 1} refresh).',
      );
    }

    await repository.saveScheduledReminders(scheduled);
    await repository.saveLastCalculationDate(now());
    await repository.saveLastKnownTimezone(settings.timezone!);
    await repository.saveLastKnownCoordinates(
      settings.latitude!,
      settings.longitude!,
    );

    return scheduled;
  }

  /// The next main prayer reminder that has not fired yet, from the
  /// persisted schedule. Follow-ups and snoozes are excluded — they are
  /// supporting reminders, not the "next reminder" the user cares about.
  ScheduledReminder? nextScheduledReminder() {
    final reminders = repository.loadScheduledReminders();
    final nowMillis = now().millisecondsSinceEpoch;
    ScheduledReminder? next;
    for (final r in reminders) {
      if (r.kind != ReminderKind.prayer) continue;
      if (r.scheduledAtMillis <= nowMillis) continue;
      if (next == null || r.scheduledAtMillis < next.scheduledAtMillis) {
        next = r;
      }
    }
    return next;
  }

  /// Whether a recalculation is due because the calendar day rolled over
  /// since the last calculation (in the user's timezone).
  bool isRecalculationDue(PrayerSettings settings) {
    final last = repository.loadLastCalculationDate();
    if (last == null) return true;
    final timezone = settings.timezone;
    if (timezone == null) return true;
    final location = tz.getLocation(timezone);
    final lastLocal = tz.TZDateTime.from(last, location);
    final nowLocal = tz.TZDateTime.from(now(), location);
    return lastLocal.year != nowLocal.year ||
        lastLocal.month != nowLocal.month ||
        lastLocal.day != nowLocal.day;
  }

  /// Whether the device has moved far enough (> ~10 km) that prayer times
  /// should be recalculated.
  bool hasLocationChangedSignificantly(double latitude, double longitude) {
    final last = repository.loadLastKnownCoordinates();
    if (last == null) return true;
    // ~0.1 degrees is roughly 11 km; ample precision for prayer times.
    return (last.latitude - latitude).abs() > 0.1 ||
        (last.longitude - longitude).abs() > 0.1;
  }

  /// Cancels OS-pending notifications with no matching persisted record.
  /// Best-effort: a failed query is logged and skipped rather than blocking
  /// scheduling on a transient platform-channel error.
  Future<void> _cancelOrphans() async {
    List<int> actualIds;
    try {
      actualIds = await notificationScheduler.pendingIds();
    } catch (e) {
      debugPrint('pendingIds query failed during reconciliation: $e');
      return;
    }
    final persisted = repository.loadScheduledReminders();
    final recon = reconcile(
      persisted: persisted,
      actualPendingIds: actualIds.toSet(),
      ignoredIds: const {LocalNotificationService.testNotificationId},
    );
    for (final id in recon.orphanedInOs) {
      await notificationScheduler.cancel(id);
    }
  }

  /// Cancels persisted reminders and returns the future snoozes that were
  /// kept (when [keepFutureSnoozes] is true) so they can be carried into the
  /// next persisted schedule.
  Future<List<ScheduledReminder>> _cancelPersisted({
    required bool keepFutureSnoozes,
  }) async {
    final old = repository.loadScheduledReminders();
    final nowMillis = now().millisecondsSinceEpoch;
    final kept = <ScheduledReminder>[];
    for (final reminder in old) {
      if (keepFutureSnoozes &&
          reminder.kind == ReminderKind.snooze &&
          reminder.scheduledAtMillis > nowMillis) {
        kept.add(reminder);
        continue;
      }
      await notificationScheduler.cancel(reminder.notificationId);
    }
    await repository.saveScheduledReminders(kept);
    return kept;
  }
}
