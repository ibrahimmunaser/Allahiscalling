import '../models/scheduled_reminder.dart';
import '../repositories/prayer_settings_repository.dart';
import 'diagnostics_log.dart';
import 'local_notification_service.dart';
import 'notification_reconciliation.dart';
import 'prayer_scheduler_service.dart' show SchedulingPolicy;

/// Result of admitting a single candidate reminder onto an already-
/// reconciled pending list.
class AdmissionPlan {
  /// True when [candidate] replaces an existing reminder with the same
  /// notification ID — a net-zero change in pending count, and therefore
  /// never a reason to evict anything.
  final bool isReplacement;

  /// Notification IDs evicted (lowest priority first) to make room.
  final List<int> idsToEvict;

  /// The reconciled list with [candidate] applied (added, or swapped in for
  /// a replacement) and any evicted entries removed. When [admitted] is
  /// false this is the reconciled list unchanged — [candidate] is NOT
  /// included, and nothing was evicted for it.
  final List<ScheduledReminder> updatedReminders;

  /// False only when every evictable entry (follow-ups, the refresh
  /// warning, then user snoozes, in that order) has been removed and the
  /// candidate still would not fit. Primary prayer reminders are never
  /// evicted to admit another notification — when this happens the
  /// candidate is simply not scheduled, which is safer than displacing a
  /// prayer reminder.
  final bool admitted;

  const AdmissionPlan({
    required this.isReplacement,
    required this.idsToEvict,
    required this.updatedReminders,
    required this.admitted,
  });
}

/// Pure admission-control logic: no plugin, no I/O.
///
/// Eviction priority when [candidate] would push the pending count over
/// [maxPending] (null means uncapped, e.g. Android — always admitted):
///   1. Automatic follow-ups, furthest-in-the-future first.
///   2. The schedule-refresh safety warning (it is recreated correctly on
///      the next successful reschedule, so losing it temporarily is safe).
///   3. User-requested snoozes, furthest-out first — preserved wherever
///      reasonably possible; only touched once every follow-up and the
///      refresh warning are already gone.
/// Primary prayer reminders are never evicted by this function.
AdmissionPlan planAdmission({
  required List<ScheduledReminder> reconciled,
  required ScheduledReminder candidate,
  required int? maxPending,
}) {
  final existingIndex = reconciled.indexWhere(
    (r) => r.notificationId == candidate.notificationId,
  );
  if (existingIndex != -1) {
    final updated = [...reconciled];
    updated[existingIndex] = candidate;
    return AdmissionPlan(
      isReplacement: true,
      idsToEvict: const [],
      updatedReminders: updated,
      admitted: true,
    );
  }

  if (maxPending == null || reconciled.length + 1 <= maxPending) {
    return AdmissionPlan(
      isReplacement: false,
      idsToEvict: const [],
      updatedReminders: [...reconciled, candidate],
      admitted: true,
    );
  }

  var overflow = reconciled.length + 1 - maxPending;
  final toEvict = <int>[];
  final remaining = [...reconciled];

  void evictFrom(ReminderKind kind) {
    if (overflow <= 0) return;
    final candidates =
        remaining.where((r) => r.kind == kind).toList()
          ..sort((a, b) => b.scheduledAtMillis.compareTo(a.scheduledAtMillis));
    for (final r in candidates) {
      if (overflow <= 0) break;
      toEvict.add(r.notificationId);
      remaining.remove(r);
      overflow--;
    }
  }

  evictFrom(ReminderKind.followUp);
  evictFrom(ReminderKind.refresh);
  evictFrom(ReminderKind.snooze);
  // Deliberately no evictFrom(ReminderKind.prayer): primaries are never
  // sacrificed to admit another notification.

  final admitted = overflow <= 0;
  return AdmissionPlan(
    isReplacement: false,
    idsToEvict: admitted ? toEvict : const [],
    updatedReminders: admitted ? [...remaining, candidate] : reconciled,
    admitted: admitted,
  );
}

/// Enforces the platform's pending-notification cap for every operation
/// that adds or replaces a single notification outside bulk scheduling —
/// foreground/background Decline snoozes today, and any future one-off
/// reminder that goes through [admit].
///
/// Bulk scheduling ([PrayerSchedulerService.rescheduleAll]) already
/// computes a whole fresh batch under budget in one pass; this coordinator
/// covers everything scheduled one at a time in between reschedules.
///
/// Caveat — not a transactional OS-level lock: [admit] is a read-then-write
/// sequence (query pending → decide → cancel evictions → schedule →
/// persist), not an atomic transaction. If the foreground app and a
/// background/terminated-app isolate each ran an admission at the same
/// instant, both could observe the same headroom and both proceed to add a
/// notification — `SharedPreferences` provides no cross-process locking,
/// and neither platform's notification API offers a compare-and-swap
/// primitive to build one on top of. In practice this window is narrow
/// (Decline is a discrete, infrequent user action, and `planDecline`'s
/// duplicate-callback idempotency already prevents the *same* action from
/// being admitted twice — see decline_flow.dart), and
/// [SchedulingPolicy.maxPending] is deliberately kept several slots under
/// iOS's own 64-notification hard limit specifically to absorb this kind of
/// race without visible harm. That margin is practical protection, not a
/// guarantee: true mutual exclusion would require a platform-level lock,
/// which is not implemented here because the residual risk is bounded and
/// rare enough not to justify the added complexity.
class NotificationBudgetCoordinator {
  final NotificationScheduler notificationScheduler;
  final PrayerSettingsRepository repository;
  final SchedulingPolicy policy;

  /// Used only when the pending-notification query itself fails (see
  /// [_admitWithoutReconciliation]): a genuinely new, non-primary candidate
  /// is refused once persisted usage is already this close to the cap,
  /// rather than trusting a possibly-stale count that close to the edge.
  static const int _queryFailureSafetyMargin = 5;

  const NotificationBudgetCoordinator({
    required this.notificationScheduler,
    required this.repository,
    required this.policy,
  });

  /// Admits [candidate] onto [persisted], enforcing the pending cap:
  ///
  /// 1. Reconciles [persisted] against the OS's actual pending IDs (queried
  ///    fresh, so decisions are based on ground truth, not a possibly-stale
  ///    persisted list): stale persisted entries are dropped, and OS
  ///    entries unknown to persistence are cancelled.
  /// 2. Decides whether [candidate] is a same-ID replacement (net-zero) or
  ///    a genuine addition.
  /// 3. If admitting it would exceed the cap, evicts by priority (see
  ///    [planAdmission]) — never removing a primary prayer reminder.
  /// 4. Calls [schedule] only when the candidate is actually admitted.
  /// 5. Persists the final reconciled + evicted + admitted state, so
  ///    persistence and the OS never drift apart.
  ///
  /// Idempotent: admitting the same candidate ID twice in a row is a
  /// replacement the second time (it is already in the persisted list from
  /// the first call), never a second addition or a second eviction.
  ///
  /// On platforms with no cap ([SchedulingPolicy.maxPending] is null) this
  /// skips the OS query entirely and just schedules + persists — no reason
  /// to pay for reconciliation where nothing can overflow.
  ///
  /// If the OS query fails, see [_admitWithoutReconciliation]: trusting
  /// persistence outright would let an unnoticed orphan (or a second,
  /// concurrent admission) combine with a blind "admit" to breach the cap,
  /// so a brand-new non-primary candidate is refused once persisted usage
  /// is already close to the limit; same-ID replacements are always safe
  /// (net-zero pending count) and remain unconditional.
  Future<bool> admit({
    required List<ScheduledReminder> persisted,
    required ScheduledReminder candidate,
    required Future<void> Function() schedule,
    Set<int> ignoredIds = const {},
  }) async {
    if (policy.maxPending == null) {
      await schedule();
      final updated = [
        for (final r in persisted)
          if (r.notificationId != candidate.notificationId) r,
        candidate,
      ];
      await repository.saveScheduledReminders(updated);
      return true;
    }

    final actualPendingIds = await _queryPendingIds();
    if (actualPendingIds == null) {
      return _admitWithoutReconciliation(
        persisted: persisted,
        candidate: candidate,
        schedule: schedule,
      );
    }

    final recon = reconcile(
      persisted: persisted,
      actualPendingIds: actualPendingIds,
      ignoredIds: ignoredIds,
    );
    for (final orphanId in recon.orphanedInOs) {
      await notificationScheduler.cancel(orphanId);
    }

    final plan = planAdmission(
      reconciled: recon.confirmed,
      candidate: candidate,
      maxPending: policy.maxPending,
    );

    for (final id in plan.idsToEvict) {
      await notificationScheduler.cancel(id);
    }

    if (plan.admitted) {
      await schedule();
    } else {
      await DiagnosticsLog.recordError(
        repository.prefs,
        'scheduling',
        'notification budget exhausted (cap ${policy.maxPending}); '
            'skipped adding a ${candidate.kind.name} reminder',
      );
    }

    await repository.saveScheduledReminders(plan.updatedReminders);
    return plan.admitted;
  }

  Future<Set<int>?> _queryPendingIds() async {
    try {
      return (await notificationScheduler.pendingIds()).toSet();
    } catch (e) {
      await DiagnosticsLog.recordError(
        repository.prefs,
        'scheduling',
        'pendingIds query failed during admission: $e',
      );
      return null;
    }
  }

  /// Fallback for when the OS pending-notification query fails, so
  /// reconciliation and priority-based eviction cannot run against ground
  /// truth at all.
  ///
  /// A same-ID replacement is admitted unconditionally — it cannot change
  /// the pending count regardless of what the OS actually holds, so it
  /// carries no risk of breaching the cap. A genuinely new, non-primary
  /// candidate is refused once [persisted] is already within
  /// [_queryFailureSafetyMargin] of the cap: flying blind that close to the
  /// limit means an unnoticed orphan, or a second concurrent admission (see
  /// the class-level "not a transactional lock" note), could have already
  /// consumed the remaining headroom. Primaries are never evicted or
  /// blocked by this coordinator, so refusing here only ever costs a
  /// lower-priority notification (e.g. a Decline snooze), never a prayer
  /// reminder.
  Future<bool> _admitWithoutReconciliation({
    required List<ScheduledReminder> persisted,
    required ScheduledReminder candidate,
    required Future<void> Function() schedule,
  }) async {
    final existingIndex = persisted.indexWhere(
      (r) => r.notificationId == candidate.notificationId,
    );
    final isReplacement = existingIndex != -1;

    if (!isReplacement &&
        candidate.kind != ReminderKind.prayer &&
        persisted.length >= policy.maxPending! - _queryFailureSafetyMargin) {
      await DiagnosticsLog.recordError(
        repository.prefs,
        'scheduling',
        'pendingIds query failed and persisted usage '
            '(${persisted.length}/${policy.maxPending}) is too close to the '
            'cap to safely add a new ${candidate.kind.name} reminder blind; '
            'skipped.',
      );
      // Keep persistence explicitly in sync even on refusal — it already
      // matches [persisted] here, but every admit() call guarantees this
      // rather than leaving it implicit.
      await repository.saveScheduledReminders(persisted);
      return false;
    }

    await schedule();
    final updated =
        isReplacement
            ? [
              for (var i = 0; i < persisted.length; i++)
                i == existingIndex ? candidate : persisted[i],
            ]
            : [...persisted, candidate];
    await repository.saveScheduledReminders(updated);
    return true;
  }
}
