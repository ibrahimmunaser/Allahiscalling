import 'salah_prayer.dart';

/// What a scheduled notification represents, in scheduling priority order:
/// primary prayer reminders always win, then user-requested snoozes, then
/// automatic follow-ups.
enum ReminderKind {
  /// The main reminder fired when the prayer enters. Highest priority.
  prayer,

  /// A user-requested Decline snooze.
  snooze,

  /// A gentle automatic follow-up fired while the prayer window is still
  /// open, in case the first reminder was missed or ignored. Lowest priority.
  followUp,

  /// The safety notification asking the user to open the app before the
  /// scheduled reminder window runs out.
  refresh,
}

/// A scheduled local notification, persisted so it can be cancelled later.
class ScheduledReminder {
  final int notificationId;
  final SalahPrayer prayer;

  /// The scheduled fire time (millisecondsSinceEpoch, UTC-based instant).
  final int scheduledAtMillis;

  final ReminderKind kind;

  const ScheduledReminder({
    required this.notificationId,
    required this.prayer,
    required this.scheduledAtMillis,
    this.kind = ReminderKind.prayer,
  });

  DateTime get scheduledAt =>
      DateTime.fromMillisecondsSinceEpoch(scheduledAtMillis);

  Map<String, dynamic> toJson() => {
        'notificationId': notificationId,
        'prayer': prayer.name,
        'scheduledAtMillis': scheduledAtMillis,
        'kind': kind.name,
      };

  factory ScheduledReminder.fromJson(Map<String, dynamic> json) {
    return ScheduledReminder(
      notificationId: (json['notificationId'] as num).toInt(),
      prayer: SalahPrayer.fromName(json['prayer'] as String) ??
          SalahPrayer.fajr,
      scheduledAtMillis: (json['scheduledAtMillis'] as num).toInt(),
      kind: ReminderKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => ReminderKind.prayer,
      ),
    );
  }
}
