import '../models/scheduled_reminder.dart';

/// Result of comparing the app's persisted reminder bookkeeping against the
/// notification IDs the OS actually still has pending.
///
/// Ground truth is the OS, not persistence: a scheduled notification can
/// vanish from the OS without the app knowing (already fired, or silently
/// dropped by a platform-level cap), and — more rarely — an OS notification
/// can exist with no matching persisted record (a leftover from an older
/// code path, a bug, or a race). Reconciling before every capacity decision
/// keeps eviction choices honest.
class ReconciliationResult {
  /// Persisted reminders confirmed still pending in the OS. Safe to reason
  /// about for capacity/eviction decisions.
  final List<ScheduledReminder> confirmed;

  /// Persisted reminders the OS no longer has. Already gone (fired, or
  /// dropped) — nothing to cancel; the app simply forgets them.
  final List<ScheduledReminder> staleInPersistence;

  /// OS notification IDs with no matching persisted record. Unknown to the
  /// app's bookkeeping; the safest action is to cancel them rather than let
  /// them silently consume a slot under the platform's own cap.
  final List<int> orphanedInOs;

  const ReconciliationResult({
    required this.confirmed,
    required this.staleInPersistence,
    required this.orphanedInOs,
  });
}

/// Pure reconciliation: no plugin, no I/O. [ignoredIds] excludes OS
/// notification IDs the app schedules outside the persisted-reminder
/// bookkeeping (e.g. the one-off "send test notification"), so they are
/// never mistaken for orphans and cancelled.
ReconciliationResult reconcile({
  required List<ScheduledReminder> persisted,
  required Set<int> actualPendingIds,
  Set<int> ignoredIds = const {},
}) {
  final confirmed = <ScheduledReminder>[];
  final stale = <ScheduledReminder>[];
  for (final r in persisted) {
    if (actualPendingIds.contains(r.notificationId)) {
      confirmed.add(r);
    } else {
      stale.add(r);
    }
  }

  final knownIds = persisted.map((r) => r.notificationId).toSet();
  final orphans =
      actualPendingIds
          .where((id) => !knownIds.contains(id) && !ignoredIds.contains(id))
          .toList();

  return ReconciliationResult(
    confirmed: confirmed,
    staleInPersistence: stale,
    orphanedInOs: orphans,
  );
}
