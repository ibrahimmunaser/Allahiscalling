import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/salah_prayer.dart';
import '../utils/app_strings.dart';
import 'decline_flow.dart';
import 'diagnostics_log.dart';
import 'timezone_service.dart';

/// Payload attached to every notification so taps can route to the
/// incoming-salah screen.
class SalahNotificationPayload {
  static const typePrayer = 'prayer';
  static const typeSnooze = 'snooze';
  static const typeTest = 'test';
  static const typeRefresh = 'refresh';

  final String type;
  final SalahPrayer? prayer;

  const SalahNotificationPayload({required this.type, this.prayer});

  String encode() =>
      jsonEncode({'type': type, 'prayer': prayer?.name});

  static SalahNotificationPayload? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return SalahNotificationPayload(
        type: map['type'] as String? ?? typePrayer,
        prayer: map['prayer'] == null
            ? null
            : SalahPrayer.fromName(map['prayer'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Abstraction over the platform notification plugin so the scheduler can be
/// unit-tested with a fake implementation.
abstract class NotificationScheduler {
  Future<void> schedulePrayerReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  });

  /// A gentle follow-up while the prayer window is still open (missed-prayer
  /// recovery). Never scheduled past the next prayer's entry.
  Future<void> scheduleFollowUpReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  });

  /// Safety notification fired only if the app never refreshed its schedule
  /// before the reminder window ran out (cancelled and rescheduled on every
  /// successful reschedule).
  Future<void> scheduleRefreshReminder({
    required int id,
    required tz.TZDateTime scheduledAt,
  });

  Future<void> cancel(int id);

  /// Notification IDs the OS actually still has pending right now. Used to
  /// reconcile against persisted bookkeeping before capacity-sensitive
  /// operations (see notification_reconciliation.dart /
  /// notification_budget.dart) — ground truth for what is really scheduled,
  /// which can drift from persistence (already-fired entries, or platform
  /// caps silently dropping something).
  Future<List<int>> pendingIds();
}

/// Handles permissions, channels, and scheduling of all local notifications.
class LocalNotificationService implements NotificationScheduler {
  static const String prayerChannelId = 'salah_reminders';
  static const String prayerChannelName = 'Salah Reminders';
  static const String prayerChannelDescription =
      'Reminders when prayer time enters';

  /// Notification action identifiers (Android actions / iOS category actions).
  static const String actionPrayNow = 'pray_now';
  static const String actionDecline = 'decline';

  /// iOS notification category carrying the two actions.
  static const String darwinSalahCategory = 'salah_reminder_category';

  static const int testNotificationId = 1;

  /// Fixed ID for the schedule-refresh safety notification.
  static const int refreshReminderId = 2;

  final FlutterLocalNotificationsPlugin _plugin;

  /// Called when the user taps a notification or its "Pray Now" action while
  /// the app is running (foreground/background). [actionId] is null for a
  /// plain body tap.
  void Function(SalahNotificationPayload payload, String? actionId)?
      onNotificationTap;

  LocalNotificationService([FlutterLocalNotificationsPlugin? plugin])
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// Deterministic ID per prayer occurrence: identical inputs always produce
  /// the same ID, so rescheduling replaces instead of duplicating.
  /// Layout: (minutes since epoch, cyclic) * 20 + slot.
  /// Slots 0-4 = prayer reminders, 5-9 = snoozes, 10-14 = follow-ups.
  static int notificationIdFor(SalahPrayer prayer, DateTime scheduledAt,
      {bool snooze = false, bool followUp = false}) {
    assert(!(snooze && followUp));
    final minutes = scheduledAt.toUtc().millisecondsSinceEpoch ~/ 60000;
    final slot = prayer.index + (snooze ? 5 : (followUp ? 10 : 0));
    return (minutes % 100000000) * 20 + slot;
  }

  Future<void> initialize() async {
    TimezoneService.ensureInitialized();

    final initializationSettings = InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        // Permissions are requested explicitly via requestPermissions().
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        notificationCategories: [
          DarwinNotificationCategory(
            darwinSalahCategory,
            actions: [
              DarwinNotificationAction.plain(
                actionPrayNow,
                AppStrings.prayNow,
                options: {DarwinNotificationActionOption.foreground},
              ),
              DarwinNotificationAction.plain(
                actionDecline,
                AppStrings.declineLabel,
              ),
            ],
          ),
        ],
      ),
    );

    await _plugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (response) {
        final payload = SalahNotificationPayload.decode(response.payload);
        if (payload != null) {
          onNotificationTap?.call(payload, response.actionId);
        }
      },
      onDidReceiveBackgroundNotificationResponse: notificationActionBackground,
    );

    if (!kIsWeb && Platform.isAndroid) {
      await _androidImpl?.createNotificationChannel(
        const AndroidNotificationChannel(
          prayerChannelId,
          prayerChannelName,
          description: prayerChannelDescription,
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        ),
      );
    }
  }

  AndroidFlutterLocalNotificationsPlugin? get _androidImpl =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  IOSFlutterLocalNotificationsPlugin? get _iosImpl =>
      _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();

  /// If the app was launched by tapping a notification (or an action on
  /// one), returns its payload and the action that launched it.
  Future<({SalahNotificationPayload payload, String? actionId})?>
      getLaunchDetails() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    final payload = SalahNotificationPayload.decode(
        details!.notificationResponse?.payload);
    if (payload == null) return null;
    return (payload: payload, actionId: details.notificationResponse?.actionId);
  }

  // ------------------------------------------------------------- permissions

  Future<bool> requestPermissions() async {
    if (kIsWeb) return false;
    if (Platform.isAndroid) {
      final android = _androidImpl;
      final granted = await android?.requestNotificationsPermission() ?? false;
      // Exact alarms make reminders land on the minute; gracefully degrade
      // to inexact scheduling if the user does not grant it.
      if (await android?.canScheduleExactNotifications() == false) {
        await android?.requestExactAlarmsPermission();
      }
      // Note: the full-screen intent permission is intentionally NOT
      // requested here. It routes the user out to system settings, so the UI
      // first explains why via a guidance dialog, then calls
      // requestFullScreenIntent().
      return granted;
    }
    if (Platform.isIOS) {
      final granted = await _iosImpl?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
      return granted;
    }
    return false;
  }

  /// Requests the Android 14+ full-screen intent special permission (routes
  /// to system settings). Call only after showing the guidance dialog.
  Future<void> requestFullScreenIntent() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _androidImpl?.requestFullScreenIntentPermission();
    } catch (e) {
      debugPrint('Full-screen intent permission request failed: $e');
    }
  }

  Future<bool> areNotificationsEnabled() async {
    if (kIsWeb) return false;
    if (Platform.isAndroid) {
      return await _androidImpl?.areNotificationsEnabled() ?? false;
    }
    if (Platform.isIOS) {
      final settings = await _iosImpl?.checkPermissions();
      return settings?.isEnabled ?? false;
    }
    return false;
  }

  Future<bool> canScheduleExactAlarms() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    return await _androidImpl?.canScheduleExactNotifications() ?? false;
  }

  // -------------------------------------------------------------- scheduling

  NotificationDetails _prayerDetails(
      {required bool callStyle, bool withActions = true}) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        prayerChannelId,
        prayerChannelName,
        channelDescription: prayerChannelDescription,
        importance: Importance.max,
        priority: Priority.max,
        category: callStyle
            ? AndroidNotificationCategory.call
            : AndroidNotificationCategory.reminder,
        // Platform-compliant call-style presentation: shows over the lock
        // screen / as heads-up where the user has allowed it.
        fullScreenIntent: callStyle,
        visibility: NotificationVisibility.public,
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
        actions: withActions
            ? [
                const AndroidNotificationAction(
                  actionPrayNow,
                  AppStrings.prayNow,
                  showsUserInterface: true,
                  cancelNotification: true,
                ),
                const AndroidNotificationAction(
                  actionDecline,
                  AppStrings.declineLabel,
                  cancelNotification: true,
                ),
              ]
            : null,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        presentBanner: true,
        categoryIdentifier: withActions ? darwinSalahCategory : null,
        // Time-sensitive delivery. Requires the Time Sensitive Notifications
        // entitlement (ios/Runner/Runner.entitlements) and a provisioning
        // profile that supports it. Degradation is graceful and automatic:
        // if the entitlement is missing or the user disables Time Sensitive
        // delivery for this app, iOS delivers the reminder as an ordinary
        // notification — it is never dropped.
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
  }

  @override
  Future<void> schedulePrayerReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  }) async {
    await _zonedSchedule(
      id: id,
      title: AppStrings.notificationTitle,
      body: AppStrings.prayerEnteredBody(prayer.displayName),
      scheduledAt: scheduledAt,
      details: _prayerDetails(callStyle: callStyle),
      payload: SalahNotificationPayload(
        type: SalahNotificationPayload.typePrayer,
        prayer: prayer,
      ).encode(),
    );
  }

  @override
  Future<void> scheduleFollowUpReminder({
    required int id,
    required SalahPrayer prayer,
    required tz.TZDateTime scheduledAt,
    required bool callStyle,
  }) async {
    await _zonedSchedule(
      id: id,
      title: AppStrings.followUpTitle,
      body: AppStrings.followUpBody(prayer.displayName),
      scheduledAt: scheduledAt,
      // Follow-ups are gentler: never full-screen, standard category.
      details: _prayerDetails(callStyle: false),
      payload: SalahNotificationPayload(
        type: SalahNotificationPayload.typeSnooze,
        prayer: prayer,
      ).encode(),
    );
  }

  @override
  Future<void> scheduleRefreshReminder({
    required int id,
    required tz.TZDateTime scheduledAt,
  }) async {
    await _zonedSchedule(
      id: id,
      title: AppStrings.refreshReminderTitle,
      body: AppStrings.refreshReminderBody,
      scheduledAt: scheduledAt,
      // Plain notification: no call presentation, no Answer/Decline actions.
      details: _prayerDetails(callStyle: false, withActions: false),
      payload: const SalahNotificationPayload(
        type: SalahNotificationPayload.typeRefresh,
      ).encode(),
    );
  }

  /// Schedules a user-requested Decline snooze. Returns the notification ID.
  ///
  /// [userTimezone] is the IANA timezone of the user's selected location.
  /// Passing it ensures the "fire at" instant is correct even when the
  /// device timezone differs from the city the user has selected.
  ///
  /// [fireAt] pins the exact fire instant (used by the shared Decline flow so
  /// the persisted record and the scheduled notification agree); when null,
  /// it is now + [minutes].
  ///
  /// When [windowStillOpen] is false (the next prayer will have entered by
  /// the time the snooze fires), generic copy is used so the notification
  /// never implies an expired prayer window is still open.
  Future<int> scheduleSnooze({
    required SalahPrayer prayer,
    required int minutes,
    required bool callStyle,
    String? userTimezone,
    bool windowStillOpen = true,
    DateTime? fireAt,
  }) async {
    TimezoneService.ensureInitialized();
    tz.Location zone;
    try {
      zone = userTimezone != null ? tz.getLocation(userTimezone) : tz.local;
    } catch (_) {
      zone = tz.local;
    }
    final fireAtZoned = fireAt != null
        ? tz.TZDateTime.from(fireAt, zone)
        : tz.TZDateTime.now(zone).add(Duration(minutes: minutes));
    final id = notificationIdFor(prayer, fireAtZoned, snooze: true);
    await _zonedSchedule(
      id: id,
      title: windowStillOpen
          ? AppStrings.snoozeTitle
          : AppStrings.genericReminderTitle,
      body: windowStillOpen
          ? AppStrings.snoozeBody(prayer.displayName)
          : AppStrings.genericReminderBody,
      scheduledAt: fireAtZoned,
      details: _prayerDetails(callStyle: callStyle),
      payload: SalahNotificationPayload(
        type: SalahNotificationPayload.typeSnooze,
        prayer: prayer,
      ).encode(),
    );
    return id;
  }

  Future<void> _zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledAt,
    required NotificationDetails details,
    required String payload,
  }) async {
    final exact = await canScheduleExactAlarms();
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        scheduledAt,
        details,
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );
    } on PlatformException catch (e) {
      // Exact alarm permission may have been revoked between the check and
      // the call; retry inexact so the reminder is never silently dropped.
      debugPrint('Exact schedule failed ($e); retrying inexact.');
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        scheduledAt,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );
    }
  }

  /// Shows an immediate test notification.
  Future<void> showTestNotification() async {
    await _plugin.show(
      testNotificationId,
      AppStrings.notificationTitle,
      AppStrings.testNotificationBody,
      _prayerDetails(callStyle: true),
      payload: const SalahNotificationPayload(
        type: SalahNotificationPayload.typeTest,
        prayer: SalahPrayer.dhuhr,
      ).encode(),
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id);

  Future<void> cancelAll() => _plugin.cancelAll();

  Future<List<PendingNotificationRequest>> pendingNotifications() =>
      _plugin.pendingNotificationRequests();

  @override
  Future<List<int>> pendingIds() async =>
      (await pendingNotifications()).map((p) => p.id).toList();
}

/// Handles notification action taps delivered while the app is not running
/// in the foreground. Runs in a separate background isolate, so it cannot
/// touch the widget tree or the AppController — it works directly against
/// SharedPreferences and the notification plugin.
///
/// Only "Decline" is handled here; "Pray Now" opens the app and is
/// routed through the normal foreground/launch flow.
///
/// Decline performs exactly the same logical operation as the in-app
/// Decline: cancel the pending follow-up for this prayer window, schedule
/// the configured snooze (idempotently), and persist both changes. The
/// shared implementation lives in decline_flow.dart so the two paths cannot
/// drift apart.
// Initialization audit for this entry point (runs in a fresh background
// isolate with no Flutter app, possibly with the app terminated):
//   1. @pragma('vm:entry-point')     — below; required so AOT keeps this
//                                      function reachable for the plugin's
//                                      background isolate.
//   2. Plugin registration           — flutter_local_notifications registers
//                                      its own background channel; no other
//                                      plugins are touched except
//                                      shared_preferences (isolate-safe).
//   3. Timezone database             — TimezoneService.ensureInitialized()
//                                      (idempotent) before any scheduling.
//   4. SharedPreferences freshness   — prefs.reload() so this isolate sees
//                                      what the main isolate last persisted.
//   5. Notification plugin           — service.initialize() before
//                                      scheduling the snooze.
//   6. Payload parsing               — a malformed/missing payload aborts
//                                      WITHOUT scheduling anything (an
//                                      incorrect snooze is worse than none)
//                                      and is logged.
//   7. Follow-up cancellation +
//      idempotency                   — shared performDecline() (same code
//                                      as foreground; see decline_flow.dart).
//   8. Error logging                 — failures are never swallowed: logged
//                                      to the console AND to the persistent
//                                      DiagnosticsLog ring buffer (no prayer
//                                      names or personal data in entries).
@pragma('vm:entry-point')
Future<void> notificationActionBackground(NotificationResponse response) async {
  if (response.actionId != LocalNotificationService.actionDecline &&
      response.actionId != 'remind_later') {
    return;
  }

  final payload = SalahNotificationPayload.decode(response.payload);
  final prayer = payload?.prayer;
  if (prayer == null) {
    // Never schedule a snooze from an unparseable payload.
    debugPrint('[bg-action] Decline received with malformed payload; '
        'no snooze scheduled.');
    try {
      final prefs = await SharedPreferences.getInstance();
      await DiagnosticsLog.recordError(
          prefs, 'notification_action', 'malformed payload on Decline');
    } catch (_) {}
    return;
  }

  SharedPreferences? prefs;
  try {
    TimezoneService.ensureInitialized();
    prefs = await SharedPreferences.getInstance();
    // This isolate may hold a stale cache; reload so we see the reminder
    // list the main isolate persisted.
    await prefs.reload();

    final service = LocalNotificationService();
    await service.initialize();
    await performDecline(
      prefs: prefs,
      notificationService: service,
      prayer: prayer,
    );
    debugPrint('[bg-action] Decline handled in background isolate.');
  } catch (e, st) {
    debugPrint('[bg-action] Background Decline FAILED: $e\n$st');
    if (prefs != null) {
      await DiagnosticsLog.recordError(
          prefs, 'notification_action', 'background Decline failed: $e');
    }
  }
}
