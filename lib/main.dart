import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config/app_config.dart';
import 'models/salah_prayer.dart';
import 'repositories/prayer_settings_repository.dart';
import 'screens/home_screen.dart';
import 'screens/incoming_salah_screen.dart';
import 'services/diagnostics_log.dart';
import 'services/geocoding_service.dart';
import 'services/ios_alarmkit_service.dart';
import 'services/ios_hybrid_notification_scheduler.dart';
import 'services/local_notification_service.dart';
import 'services/location_service.dart';
import 'services/prayer_scheduler_service.dart';
import 'services/prayer_time_service.dart';
import 'services/timezone_service.dart';
import 'state/app_controller.dart';
import 'utils/app_strings.dart';
import 'utils/app_theme.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  TimezoneService.ensureInitialized();

  // Never throws/crashes (see AppConfig docs): logs a warning if the
  // privacy policy URL is missing or invalid, which should already have
  // been caught before packaging by tool/check_release_config.dart.
  final hasValidPrivacyPolicyUrl = AppConfig.validateForRelease();

  final repository = await PrayerSettingsRepository.create();
  if (!hasValidPrivacyPolicyUrl) {
    // Best-effort: now that SharedPreferences is available, also surface
    // this in the in-app diagnostics log (visible from Settings), not just
    // the console. Never blocks or fails startup.
    unawaited(
      DiagnosticsLog.recordError(
        repository.prefs,
        'config',
        'PRIVACY_POLICY_URL is missing or invalid at runtime',
      ),
    );
  }
  final prayerTimeService = PrayerTimeService();
  final notificationService = LocalNotificationService();
  final timezoneService = TimezoneService();

  // iOS 26+: primary prayer alerts go through AlarmKit when authorized;
  // Android and older iOS keep the existing local-notification path.
  final IosAlarmKitService? alarmKitService =
      (!kIsWeb && Platform.isIOS) ? IosAlarmKitService() : null;
  final NotificationScheduler notificationScheduler =
      alarmKitService != null
          ? IosHybridNotificationScheduler(
            notifications: notificationService,
            alarmKit: alarmKitService,
          )
          : notificationService;

  final controller = AppController(
    repository: repository,
    prayerTimeService: prayerTimeService,
    locationService: LocationService(),
    timezoneService: timezoneService,
    notificationService: notificationService,
    notificationScheduler: notificationScheduler,
    alarmKitService: alarmKitService,
    schedulerService: PrayerSchedulerService(
      prayerTimeService: prayerTimeService,
      notificationScheduler: notificationScheduler,
      repository: repository,
    ),
    geocodingService: GeocodingService(
      prefs: repository.prefs,
      timezoneService: timezoneService,
    ),
  );

  // Note: the offline city database is loaded lazily on first use (city
  // search or GPS labeling), never eagerly at startup — it is a large asset.

  // Re-entrancy guard: the incoming call screen can be requested by two
  // paths at nearly the same moment (the foreground prayer watch and a tap
  // on the simultaneously delivered notification). Only one may be shown.
  var incomingScreenOpen = false;

  Future<void> presentIncomingScreen(
    SalahPrayer prayer, {
    DateTime? scheduledAt,
    String? alarmId,
  }) async {
    if (incomingScreenOpen) return;
    incomingScreenOpen = true;
    try {
      final result = await navigatorKey.currentState?.push<IncomingSalahResult>(
        MaterialPageRoute(
          builder:
              (_) => IncomingSalahScreen(
                prayer: prayer,
                scheduledAt: scheduledAt,
                alarmId: alarmId,
              ),
          fullscreenDialog: true,
        ),
      );
      switch (result) {
        case IncomingSalahResult.prayNow:
          // Answer means "I am going to pray" — not "I have prayed". Record
          // the answer and ask about completion later (home-screen card after
          // a respectful delay), instead of interrupting again right away.
          await controller.markPrayerAnswered(prayer);
        case IncomingSalahResult.declined:
          // The screen already ran the Decline flow (snooze + follow-up
          // cancellation) and recorded the response.
          break;
        case null:
          // Backed out without choosing: dismissed, NOT declined. No snooze;
          // the automatic unanswered follow-up stays in place.
          await controller.markPrayerDismissed(prayer);
      }
    } finally {
      incomingScreenOpen = false;
    }
  }

  Future<void> presentFromAlarmKit(AlarmKitAnswer answer) async {
    await alarmKitService?.clearPendingAnswer();
    await presentIncomingScreen(
      answer.prayer,
      scheduledAt: answer.scheduledAt,
      alarmId: answer.alarmId,
    );
  }

  controller.onOpenReminder = (payload, actionId) async {
    final prayer = payload.prayer ?? SalahPrayer.dhuhr;

    // Ignore taps on the refresh safety notification: opening the app has
    // already triggered the reschedule it asked for.
    if (payload.type == SalahNotificationPayload.typeRefresh) return;

    // "Pray Now" / iOS "Answer" on the notification shade.
    //
    // iOS: open the full call UI (same as tapping the notification body).
    // Apple cannot auto-present that screen when the app is backgrounded or
    // locked, so this one-tap action is the primary immersive path there —
    // alongside the zero-tap path when the app is already open
    // (onPrayerEntered). Both coexist; neither replaces the other.
    //
    // Android: the full-screen intent already handles the immersive moment
    // when the phone is locked; the action records the answer immediately
    // without a second full-screen step.
    if (actionId == LocalNotificationService.actionPrayNow) {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await presentIncomingScreen(prayer);
      } else {
        await controller.markPrayerAnswered(prayer);
      }
      return;
    }

    // Notification body tap (or Android full-screen intent launch): full
    // call UI with Answer / Decline.
    await presentIncomingScreen(prayer);
  };

  // Zero-tap path: a prayer entered while the app is in the foreground, so
  // present the full call screen directly — no notification tap needed.
  // This is the closest-to-a-real-call experience iOS permits; on Android
  // it complements the lock-screen full-screen intent.
  controller.onPrayerEntered = (prayer) => presentIncomingScreen(prayer);

  // AlarmKit Answer: foreground / background while Flutter is alive.
  if (alarmKitService != null) {
    alarmKitService.ensureListening();
    alarmKitService.onAnswered.listen(presentFromAlarmKit);
    controller.onAlarmKitAnswer = presentFromAlarmKit;
  }

  runApp(SalahApp(controller: controller));

  // Initialize after runApp so the first frame is not blocked on
  // permission dialogs and location lookups.
  controller
      .initialize()
      .then((_) async {
        // Terminated → Answer: consume any pending AlarmKit payload after init.
        final pending = await alarmKitService?.getPendingAnswer();
        if (pending != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            presentFromAlarmKit(pending);
          });
        }
      })
      .catchError((Object e, StackTrace st) {
        // Errors here are non-fatal but must not be silently swallowed; the app
        // will still render and the user can retry via Settings → Recalculate.
        debugPrint('AppController.initialize failed: $e\n$st');
      });
}

class SalahApp extends StatelessWidget {
  final AppController controller;

  const SalahApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        title: AppStrings.appTitle,
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        theme: AppTheme.light(),
        home: const HomeScreen(),
      ),
    );
  }
}
