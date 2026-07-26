import 'package:timezone/timezone.dart' as tz;

import '../models/salah_prayer.dart';
import '../models/scheduled_reminder.dart';
import 'ios_alarmkit_service.dart';
import 'local_notification_service.dart';

/// iOS-aware [NotificationScheduler] that routes primary prayer reminders
/// through AlarmKit on iOS 26+ when authorized, and falls back to the
/// existing local-notification path otherwise.
///
/// Follow-ups, snoozes, and the refresh reminder always use
/// [LocalNotificationService] so Android behavior and the existing Decline
/// / budget logic stay unchanged. Only primary prayer alerts use AlarmKit,
/// avoiding a second conflicting scheduler.
///
/// Failure handling (never lose a primary alert):
/// - The existing local notification for an occurrence is cancelled ONLY
///   after AlarmKit confirms the alarm scheduled successfully.
/// - If AlarmKit is unavailable, unauthorized, or the schedule call itself
///   fails, the local-notification path is used instead — the prayer is
///   never left without any alert. See [schedulePrayerReminder].
///
/// Cross-restart bookkeeping: [_alarmIdsByNotificationId] is in-memory only
/// and would normally be empty after a fresh app launch, which would make
/// [pendingIds] blind to AlarmKit-backed primaries that are still
/// legitimately scheduled from a previous session. Callers must call
/// [restoreTrackedAlarmIds] with the persisted schedule (which now carries
/// each primary's `alarmKitId`, see `ScheduledReminder`) before relying on
/// [pendingIds] or [cancel] after a process restart — `rescheduleAll` does
/// this automatically at the start of every reschedule.
class IosHybridNotificationScheduler implements NotificationScheduler {
  /// The local-notification fallback path. Typed as the abstract
  /// [NotificationScheduler] (not the concrete [LocalNotificationService])
  /// purely so tests can inject a fake — production code always passes the
  /// real [LocalNotificationService].
  final NotificationScheduler notifications;
  final AlarmKitClient alarmKit;

  /// Maps deterministic notification IDs → AlarmKit UUIDs for cancel/pending.
  /// Rebuilt from persistence via [restoreTrackedAlarmIds]; do not treat as
  /// authoritative until that has run at least once this process.
  final Map<int, String> _alarmIdsByNotificationId = {};

  /// Optional sound file base name from the iOS bundle (caf/wav/…).
  String? preferredSoundName;

  IosHybridNotificationScheduler({
    required this.notifications,
    required this.alarmKit,
  });

  /// The real [IosAlarmKitService.isAvailable] already encodes the
  /// `Platform.isIOS` / OS-version gate, so this is the single source of
  /// truth for whether AlarmKit can be used — no separate platform check
  /// here. Keeping the gate solely in [AlarmKitClient] is also what makes
  /// this routing logic testable with a fake on a non-iOS host.
  Future<bool> get _useAlarmKit async {
    return await alarmKit.isAvailable() && await alarmKit.isAuthorized;
  }

  /// Rebuilds the in-memory notificationId → AlarmKit UUID map from a
  /// persisted reminder list. Must be called after every process restart,
  /// before any cancellation/pending-id decision is trusted — otherwise a
  /// still-active AlarmKit primary from a previous session would look like
  /// an ordinary (or missing) local notification. Idempotent; safe to call
  /// repeatedly.
  void restoreTrackedAlarmIds(List<ScheduledReminder> persisted) {
    _alarmIdsByNotificationId.clear();
    for (final r in persisted) {
      final alarmId = r.alarmKitId;
      if (r.kind == ReminderKind.prayer && alarmId != null) {
        _alarmIdsByNotificationId[r.notificationId] = alarmId;
      }
    }
  }

  @override
  Future<PrimaryReminderOutcome> schedulePrayerReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  }) async {
    if (await _useAlarmKit) {
      final result = await alarmKit.schedulePrayerAlarm(
        prayer: prayer,
        scheduledAt: scheduledAt.toUtc(),
        soundName: preferredSoundName,
      );
      if (result.success) {
        // Cancel the local fallback only now that AlarmKit has confirmed
        // success — never before. A no-op if none was scheduled.
        await notifications.cancel(id);
        _alarmIdsByNotificationId[id] = result.alarmId;
        return PrimaryReminderOutcome.alarmKit(result.alarmId);
      }
      // AlarmKit unavailable / unauthorized / failed: restore or keep the
      // local-notification fallback so this prayer is never left silent.
      _alarmIdsByNotificationId.remove(id);
      return notifications.schedulePrayerReminder(
        id: id,
        prayer: prayer,
        scheduledAt: scheduledAt,
        callStyle: callStyle,
      );
    }
    _alarmIdsByNotificationId.remove(id);
    return notifications.schedulePrayerReminder(
      id: id,
      prayer: prayer,
      scheduledAt: scheduledAt,
      callStyle: callStyle,
    );
  }

  @override
  Future<void> scheduleFollowUpReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  }) {
    return notifications.scheduleFollowUpReminder(
      id: id,
      prayer: prayer,
      scheduledAt: scheduledAt,
      callStyle: callStyle,
    );
  }

  @override
  Future<void> scheduleRefreshReminder({
    required int id,
    required tz.TZDateTime scheduledAt,
  }) {
    return notifications.scheduleRefreshReminder(
      id: id,
      scheduledAt: scheduledAt,
    );
  }

  @override
  Future<void> cancel(int id) async {
    final alarmId = _alarmIdsByNotificationId.remove(id);
    if (alarmId != null) {
      await alarmKit.cancelAlarmId(alarmId);
    }
    // Always also cancel any local notification with this id: a primary
    // may have fallen back to (or previously used) the local path, and
    // cancelling an id with nothing scheduled is a harmless no-op.
    await notifications.cancel(id);
  }

  /// IDs the OS actually still has pending: local notifications plus every
  /// notification ID this scheduler currently tracks as backed by a live
  /// AlarmKit alarm. Without the AlarmKit half, reconciliation
  /// (`notification_reconciliation.dart`) would see an AlarmKit-backed
  /// primary as vanished and could treat it as stale — see class docs on
  /// [restoreTrackedAlarmIds].
  @override
  Future<List<int>> pendingIds() async {
    final local = await notifications.pendingIds();
    return {...local, ..._alarmIdsByNotificationId.keys}.toList();
  }

  /// Cancels every AlarmKit prayer alarm this hybrid scheduler tracked and
  /// clears native bookkeeping. Call before a full reschedule when AlarmKit
  /// is the active primary path.
  Future<void> cancelAllAlarmKitAlarms() async {
    _alarmIdsByNotificationId.clear();
    await alarmKit.cancelAll();
  }
}
