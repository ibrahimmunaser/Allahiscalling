import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/city.dart';
import '../models/prayer_day_times.dart';
import '../models/prayer_response.dart';
import '../models/prayer_settings.dart';
import '../models/salah_prayer.dart';
import '../models/scheduled_reminder.dart';
import '../repositories/prayer_settings_repository.dart';
import '../services/city_database.dart';
import '../services/decline_flow.dart';
import '../services/diagnostics_log.dart';
import '../services/geocoding_service.dart';
import '../services/local_notification_service.dart';
import '../services/location_service.dart';
import '../services/ios_alarmkit_service.dart';
import '../services/prayer_scheduler_service.dart';
import '../services/prayer_time_service.dart';
import '../services/timezone_service.dart';

/// Central app state: owns settings, today's prayer times, and coordinates
/// recalculation + rescheduling on every relevant trigger:
/// app launch, midnight rollover, location change, timezone change,
/// settings change, and manual "Recalculate".
class AppController extends ChangeNotifier with WidgetsBindingObserver {
  final PrayerSettingsRepository repository;
  final PrayerTimeService prayerTimeService;
  final LocationService locationService;
  final TimezoneService timezoneService;
  final LocalNotificationService notificationService;

  /// The same [NotificationScheduler] passed to [schedulerService] (the
  /// hybrid AlarmKit/local scheduler on iOS 26+, or [notificationService]
  /// itself elsewhere). Cancellation of a primary reminder MUST go through
  /// this rather than [notificationService] directly — a primary occurrence
  /// may be backed by an AlarmKit alarm, which [notificationService] alone
  /// cannot cancel. Defaults to [notificationService] so existing callers
  /// (and every non-iOS platform) are unaffected.
  final NotificationScheduler notificationScheduler;
  final PrayerSchedulerService schedulerService;
  final GeocodingService geocodingService;

  /// iOS 26+ AlarmKit bridge. Null on Android / when unused.
  final IosAlarmKitService? alarmKitService;

  /// Set by the app shell so notification taps can navigate.
  /// [actionId] is the notification action that was tapped (e.g. "Pray Now"),
  /// or null for a plain body tap.
  void Function(SalahNotificationPayload payload, String? actionId)?
  onOpenReminder;

  /// Set by the app shell when AlarmKit Answer delivers a pending payload
  /// (cold start / resume).
  void Function(AlarmKitAnswer answer)? onAlarmKitAnswer;

  /// Set by the app shell: called when a prayer enters while the app is in
  /// the foreground, so the incoming call screen can be presented with zero
  /// taps. This is the only zero-tap path iOS allows (a notification there
  /// can never auto-open UI); on Android it complements the full-screen
  /// intent, which the OS typically downgrades to a heads-up banner while
  /// the app is already visible.
  void Function(SalahPrayer prayer)? onPrayerEntered;

  PrayerSettings _settings = const PrayerSettings();
  PrayerDayTimes? _today;
  ScheduledReminder? _nextReminder;
  bool _initialized = false;
  String? _statusMessage;
  LocationResultStatus? _lastLocationStatus;
  bool _notificationsPermitted = false;
  bool _exactAlarmsAvailable = true;
  bool _alarmKitAvailable = false;
  String _alarmKitAuthStatus = 'unavailable';

  /// Memoized next prayer so the per-second countdown never triggers a full
  /// astronomical recalculation. Invalidated when the cached prayer's time
  /// passes or when settings/location/timezone change.
  MapEntry<SalahPrayer, DateTime>? _cachedNextPrayer;

  Timer? _midnightTimer;
  Timer? _prayerWatchTimer;

  /// Whether the app is currently visible. The foreground prayer watch only
  /// presents the call screen while this is true.
  bool _inForeground = true;

  AppController({
    required this.repository,
    required this.prayerTimeService,
    required this.locationService,
    required this.timezoneService,
    required this.notificationService,
    required this.schedulerService,
    required this.geocodingService,
    NotificationScheduler? notificationScheduler,
    this.alarmKitService,
  }) : notificationScheduler = notificationScheduler ?? notificationService;

  PrayerSettings get settings => _settings;
  PrayerDayTimes? get today => _today;
  ScheduledReminder? get nextReminder => _nextReminder;
  bool get initialized => _initialized;
  String? get statusMessage => _statusMessage;
  LocationResultStatus? get lastLocationStatus => _lastLocationStatus;
  bool get notificationsPermitted => _notificationsPermitted;

  /// Whether AlarmKit is present on this device (iOS 26+ SDK / runtime).
  bool get alarmKitAvailable => _alarmKitAvailable;

  /// `authorized` | `denied` | `notDetermined` | `unavailable`
  String get alarmKitAuthStatus => _alarmKitAuthStatus;

  bool get alarmKitAuthorized => _alarmKitAuthStatus == 'authorized';

  /// Whether Android exact alarms are available. When false, reminders use
  /// inexact scheduling and may be delayed by the OS — surfaced honestly in
  /// Settings instead of pretending reminders are precise.
  bool get exactAlarmsAvailable => _exactAlarmsAvailable;

  /// Next prayer of today/tomorrow with its time, or null when the location
  /// is not configured yet. Memoized: recalculated only when the cached
  /// value expires (its time passes) or settings change, so per-second UI
  /// ticks stay cheap.
  MapEntry<SalahPrayer, DateTime>? get nextPrayer {
    if (!_settings.hasLocation || _settings.timezone == null) return null;
    final cached = _cachedNextPrayer;
    if (cached != null && cached.value.isAfter(nowInUserZone())) {
      return cached;
    }
    try {
      _cachedNextPrayer = prayerTimeService.nextPrayer(_settings);
      return _cachedNextPrayer;
    } catch (_) {
      return null;
    }
  }

  DateTime nowInUserZone() {
    final timezone = _settings.timezone;
    if (timezone == null) return DateTime.now();
    try {
      return tz.TZDateTime.now(tz.getLocation(timezone));
    } catch (_) {
      return DateTime.now();
    }
  }

  // ------------------------------------------------------------------- init

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    TimezoneService.ensureInitialized();

    _settings = repository.loadSettings();

    notificationService.onNotificationTap = (payload, actionId) {
      // Defensive: "Decline" is normally handled in the background
      // isolate, but if the platform routes it here, snooze without any UI.
      if (actionId == LocalNotificationService.actionDecline ||
          actionId == 'remind_later') {
        final prayer = payload.prayer;
        if (prayer != null) snooze(prayer);
        return;
      }
      onOpenReminder?.call(payload, actionId);
    };
    await notificationService.initialize();
    _notificationsPermitted = await notificationService.requestPermissions();
    _exactAlarmsAvailable = await notificationService.canScheduleExactAlarms();

    final alarmKit = alarmKitService;
    if (alarmKit != null) {
      alarmKit.ensureListening();
      _alarmKitAvailable = await alarmKit.isAvailable();
      _alarmKitAuthStatus = await alarmKit.authorizationStatus();
    }

    // Detect timezone (handles first run and timezone changes while closed).
    final detectedTimezone = await timezoneService.detectTimezone();
    final isFirstRun = _settings.timezone == null;
    if (_settings.timezone != detectedTimezone &&
        (_settings.locationSource == LocationSource.device || isFirstRun)) {
      _settings = _settings.copyWith(timezone: detectedTimezone);
      if (isFirstRun) {
        _settings = _settings.copyWith(
          calculationMethod: PrayerSettings.suggestMethodForTimezone(
            detectedTimezone,
          ),
        );
      }
      await repository.saveSettings(_settings);
    }

    // Try device location if that is the chosen source. Lifecycle paths are
    // passive: they never show a permission prompt. Prompts happen only on
    // explicit user actions ("Use current location" buttons).
    if (_settings.locationSource == LocationSource.device) {
      await _refreshDeviceLocation(silent: true, mayPrompt: false);
    }

    await recalculateAndReschedule();

    // If the app was launched from a notification, open the reminder screen.
    final launch = await notificationService.getLaunchDetails();
    if (launch != null) {
      // Defer until the first frame so navigation is available.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onOpenReminder?.call(launch.payload, launch.actionId);
      });
    }

    _scheduleMidnightRecalculation();
    _schedulePrayerWatch();
    _initialized = true;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _onAppResumed();
    }
  }

  Future<void> _onAppResumed() async {
    // Timezone may have changed while the app was backgrounded (travel/DST
    // zone updates), and the day may have rolled over.
    var needsReschedule = false;

    final detected = await timezoneService.detectTimezone();
    if (_settings.locationSource == LocationSource.device &&
        detected != _settings.timezone) {
      _settings = _settings.copyWith(timezone: detected);
      await repository.saveSettings(_settings);
      needsReschedule = true;
    } else if (_settings.locationSource != LocationSource.device &&
        detected != _settings.timezone) {
      // Device timezone differs from the selected city's timezone (e.g. the
      // user travelled). Keep the city timezone -- prayer times belong to the
      // city -- but recalculate so schedules and countdowns stay correct.
      needsReschedule = true;
    }

    if (schedulerService.isRecalculationDue(_settings)) {
      needsReschedule = true;
    }

    if (_settings.locationSource == LocationSource.device) {
      // Passive: refreshes only when permission is already granted. Never
      // launches a permission prompt from the resume lifecycle.
      final result = await locationService.getCurrentLocationIfPermitted();
      if (result.isSuccess &&
          schedulerService.hasLocationChangedSignificantly(
            result.latitude!,
            result.longitude!,
          )) {
        _settings = _settings.copyWith(
          latitude: result.latitude,
          longitude: result.longitude,
          locationLabel: await _labelForCoordinates(
            result.latitude!,
            result.longitude!,
          ),
        );
        await repository.saveSettings(_settings);
        needsReschedule = true;
      }
    }

    if (needsReschedule) {
      await recalculateAndReschedule();
    }
    await refreshAlarmKitAuthorization();
    final pendingAnswer = await alarmKitService?.getPendingAnswer();
    if (pendingAnswer != null) {
      onAlarmKitAnswer?.call(pendingAnswer);
    }
    _scheduleMidnightRecalculation();
    _schedulePrayerWatch();
  }

  void _scheduleMidnightRecalculation() {
    _midnightTimer?.cancel();
    final now = nowInUserZone();
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 0, 1);
    _midnightTimer = Timer(tomorrow.difference(now), () async {
      await recalculateAndReschedule();
      _scheduleMidnightRecalculation();
    });
  }

  /// Arms a timer for the next prayer so the incoming call screen can be
  /// auto-presented (zero taps) if the app is still in the foreground when
  /// the prayer enters. Re-armed after every reschedule and after each fire.
  ///
  /// The scheduled OS notification for the same prayer still fires — it is
  /// the only path that works when the app is backgrounded, locked, or
  /// closed. When the user responds on the auto-presented screen, the
  /// now-redundant delivered notification is cancelled (see
  /// [_cancelDeliveredPrimary]).
  void _schedulePrayerWatch() {
    _prayerWatchTimer?.cancel();
    final next = nextPrayer;
    if (next == null) return;
    final delay =
        next.value.difference(nowInUserZone()) +
        // Slightly after the minute so the OS notification (exact alarm) and
        // persisted bookkeeping agree the prayer has entered.
        const Duration(seconds: 2);
    if (delay.isNegative) return;
    _prayerWatchTimer = Timer(delay, () {
      final prayer = next.key;
      // Only while visible, and only if this occurrence has no response yet
      // (e.g. answered already from the notification banner).
      if (_inForeground &&
          repository.prayerResponse(nowInUserZone(), prayer) == null) {
        onPrayerEntered?.call(prayer);
      }
      _cachedNextPrayer = null;
      _schedulePrayerWatch();
    });
  }

  /// Cancels the already-delivered primary notification for [prayer]'s
  /// current occurrence. Called after the user responds on the
  /// auto-presented (foreground) call screen, where the OS notification for
  /// the same prayer is still sitting in the shade; notification-originated
  /// responses clean themselves up via the platform's auto-cancel instead.
  Future<void> _cancelDeliveredPrimary(SalahPrayer prayer) async {
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    for (final r in repository.loadScheduledReminders()) {
      if (r.kind == ReminderKind.prayer &&
          r.prayer == prayer &&
          r.scheduledAtMillis <= nowMillis &&
          nowMillis - r.scheduledAtMillis < Duration.millisecondsPerDay) {
        // Goes through the hybrid scheduler (not notificationService
        // directly): on iOS 26+ this occurrence may be an AlarmKit alarm,
        // not a local notification, and only the hybrid scheduler knows
        // which — and can cancel — the right one.
        await notificationScheduler.cancel(r.notificationId);
      }
    }
  }

  // ------------------------------------------------------------ calculation

  /// Lightweight refresh when a prayer enters while the app is open:
  /// invalidates the memoized next prayer and repaints. No notification
  /// rescheduling (the schedule already covers the coming days).
  void refreshNextPrayer() {
    _cachedNextPrayer = null;
    notifyListeners();
  }

  /// Recalculates today's times and reschedules the reminder window.
  Future<void> recalculateAndReschedule() async {
    _cachedNextPrayer = null;
    if (_settings.hasLocation && _settings.timezone != null) {
      try {
        _today = prayerTimeService.calculateForDate(_settings, nowInUserZone());
        _statusMessage = null;
      } catch (e) {
        _today = null;
        _statusMessage = 'Could not calculate prayer times: $e';
      }
      try {
        await schedulerService.rescheduleAll(_settings);
      } catch (e) {
        debugPrint('Scheduling failed: $e');
        // Surface in the beta diagnostics report (no user data in entry).
        await DiagnosticsLog.recordError(
          repository.prefs,
          'scheduling',
          'rescheduleAll failed: $e',
        );
      }
      _nextReminder = schedulerService.nextScheduledReminder();
    } else {
      _today = null;
      _nextReminder = null;
      _statusMessage = 'Set your location to see prayer times.';
    }
    _schedulePrayerWatch();
    notifyListeners();
  }

  // --------------------------------------------------------------- location

  /// Explicit user action: may show the OS permission prompt.
  Future<LocationResultStatus> useCurrentLocation() async {
    final status = await _refreshDeviceLocation(silent: false, mayPrompt: true);
    await recalculateAndReschedule();
    return status;
  }

  Future<LocationResultStatus> _refreshDeviceLocation({
    required bool silent,
    required bool mayPrompt,
  }) async {
    final result =
        mayPrompt
            ? await locationService.getCurrentLocation()
            : await locationService.getCurrentLocationIfPermitted();
    _lastLocationStatus = result.status;
    if (result.isSuccess) {
      // GPS is the top priority source. The device timezone is authoritative
      // when the user is physically at the location.
      final detectedTimezone = await timezoneService.detectTimezone();
      _settings = _settings.copyWith(
        latitude: result.latitude,
        longitude: result.longitude,
        locationLabel: await _labelForCoordinates(
          result.latitude!,
          result.longitude!,
        ),
        locationSource: LocationSource.device,
        timezone: detectedTimezone,
      );
      await repository.saveSettings(_settings);
    }
    if (!silent) notifyListeners();
    return result.status;
  }

  /// Sets location from a searched city. The city only provides coordinates;
  /// timezone comes from GeoNames when valid, else is resolved from the
  /// coordinates themselves. Prayer times are always computed from lat/lng.
  Future<void> setCityLocation(City city) async {
    final timezone =
        city.timezone.isNotEmpty &&
                timezoneService.isValidTimezone(city.timezone)
            ? city.timezone
            : timezoneService.timezoneForCoordinates(
              city.latitude,
              city.longitude,
            );
    _settings = _settings.copyWith(
      latitude: city.latitude,
      longitude: city.longitude,
      locationLabel: city.label,
      locationSource: LocationSource.manualCity,
      timezone: timezone,
    );
    await repository.saveSettings(_settings);
    await recalculateAndReschedule();
  }

  Future<void> setManualCoordinates(
    double latitude,
    double longitude,
    String? timezone,
  ) async {
    final resolved =
        timezone ?? timezoneService.timezoneForCoordinates(latitude, longitude);
    _settings = _settings.copyWith(
      latitude: latitude,
      longitude: longitude,
      locationLabel: await _labelForCoordinates(latitude, longitude),
      locationSource: LocationSource.manualCoordinates,
      timezone: resolved,
    );
    await repository.saveSettings(_settings);
    await recalculateAndReschedule();
  }

  /// Names coordinates using the offline city database (nearest city),
  /// falling back to raw numbers when the database is unavailable.
  Future<String> _labelForCoordinates(double latitude, double longitude) async {
    try {
      final nearest = await CityDatabase.instance.nearest(latitude, longitude);
      if (nearest != null) {
        return 'Near ${nearest.shortLabel}';
      }
    } catch (e) {
      debugPrint('Nearest-city lookup failed: $e');
    }
    return _coordinatesLabel(latitude, longitude);
  }

  String _coordinatesLabel(double latitude, double longitude) =>
      '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';

  // --------------------------------------------------------------- settings

  Future<void> updateSettings(PrayerSettings updated) async {
    _settings = updated;
    await repository.saveSettings(_settings);
    await recalculateAndReschedule();
  }

  Future<void> setManualAdjustment(SalahPrayer prayer, int minutes) async {
    final adjustments = Map<SalahPrayer, int>.from(_settings.manualAdjustments)
      ..[prayer] = minutes;
    await updateSettings(_settings.copyWith(manualAdjustments: adjustments));
  }

  // ------------------------------------------------------------ notifications

  Future<void> requestNotificationPermission() async {
    _notificationsPermitted = await notificationService.requestPermissions();
    notifyListeners();
  }

  /// Requests AlarmKit authorization from a clear user action. Does not
  /// re-prompt after denial — use [openAlarmKitSettings] instead.
  Future<String> requestAlarmKitPermission() async {
    final alarmKit = alarmKitService;
    if (alarmKit == null) return 'unavailable';
    final current = await alarmKit.authorizationStatus();
    if (current == 'denied') {
      _alarmKitAuthStatus = current;
      notifyListeners();
      return current;
    }
    _alarmKitAuthStatus = await alarmKit.requestAuthorization();
    notifyListeners();
    if (_alarmKitAuthStatus == 'authorized') {
      await recalculateAndReschedule();
    }
    return _alarmKitAuthStatus;
  }

  Future<void> refreshAlarmKitAuthorization() async {
    final alarmKit = alarmKitService;
    if (alarmKit == null) return;
    _alarmKitAvailable = await alarmKit.isAvailable();
    _alarmKitAuthStatus = await alarmKit.authorizationStatus();
    notifyListeners();
  }

  Future<void> openAlarmKitSettings() async {
    await alarmKitService?.openSystemSettings();
  }

  /// Debug-only: schedule an AlarmKit prayer alert ~1 minute ahead.
  Future<bool> scheduleAlarmKitDebugInOneMinute() async {
    final alarmKit = alarmKitService;
    if (alarmKit == null || !_alarmKitAvailable) return false;
    if (_alarmKitAuthStatus != 'authorized') {
      final status = await requestAlarmKitPermission();
      if (status != 'authorized') return false;
    }
    final prayer = nextPrayer?.key ?? SalahPrayer.dhuhr;
    await alarmKit.scheduleDebugAlarm(prayer: prayer);
    return true;
  }

  Future<void> sendTestNotification() =>
      notificationService.showTestNotification();

  /// Full Decline flow for [prayer]: cancels the pending missed-prayer
  /// follow-up and schedules the configured snooze (idempotently).
  ///
  /// Delegates to the same shared implementation the background notification
  /// action uses, so foreground and background Decline cannot drift apart.
  Future<void> snooze(SalahPrayer prayer) async {
    await repository.savePrayerResponse(
      nowInUserZone(),
      prayer,
      PrayerResponseState.declined,
      DateTime.now(),
    );
    await performDecline(
      prefs: repository.prefs,
      notificationService: notificationService,
      notificationScheduler: notificationScheduler,
      prayer: prayer,
    );
    // If this Decline came from the auto-presented (foreground) call screen,
    // the OS notification for the same prayer is still in the shade; remove
    // it. No-op when the response came from the notification itself.
    await _cancelDeliveredPrimary(prayer);
    notifyListeners();
  }

  /// Records that the reminder UI was closed without choosing Answer or
  /// Decline. Deliberately does NOT schedule a snooze (dismissal is not a
  /// Decline) and does NOT cancel the automatic unanswered follow-up (the
  /// user never chose). Only called where the platform genuinely reports
  /// the dismissal (backing out of the full-screen reminder); shade
  /// swipe-aways provide no reliable callback and are never inferred.
  Future<void> markPrayerDismissed(SalahPrayer prayer) async {
    await repository.savePrayerResponse(
      nowInUserZone(),
      prayer,
      PrayerResponseState.dismissed,
      DateTime.now(),
    );
    notifyListeners();
  }

  // ------------------------------------------------------- prayer completion

  /// Records that the user answered the reminder for [prayer] (they intend
  /// to pray). Cancels the pending "You have not answered yet" follow-up —
  /// they did answer. Completion is confirmed later, never immediately.
  Future<void> markPrayerAnswered(SalahPrayer prayer) async {
    await repository.savePrayerResponse(
      nowInUserZone(),
      prayer,
      PrayerResponseState.answered,
      DateTime.now(),
    );
    await cancelCurrentFollowUp(prayer);
    // Remove the delivered notification if the answer came from the
    // auto-presented (foreground) call screen; no-op otherwise.
    await _cancelDeliveredPrimary(prayer);
    notifyListeners();
  }

  /// Marks [prayer] completed for today and cancels its pending follow-up.
  Future<void> markPrayerCompleted(SalahPrayer prayer) async {
    await repository.savePrayerCompletion(nowInUserZone(), prayer);
    await cancelCurrentFollowUp(prayer);
    notifyListeners();
  }

  bool isPrayerCompletedToday(SalahPrayer prayer) =>
      repository.isPrayerCompleted(nowInUserZone(), prayer);

  /// How long after answering before the app gently asks about completion.
  static const Duration completionPromptDelay = Duration(minutes: 10);

  /// The prayer whose completion should be gently confirmed now: the user
  /// answered it today, at least [completionPromptDelay] ago, has not marked
  /// it complete, and its window is still open (the next prayer has not
  /// entered). Null when there is nothing to ask about.
  SalahPrayer? get pendingCompletionPrayer {
    final now = nowInUserZone();
    for (final prayer in SalahPrayer.values) {
      final answeredAt = repository.prayerAnsweredAt(now, prayer);
      if (answeredAt == null) continue;
      if (repository.isPrayerCompleted(now, prayer)) continue;
      if (DateTime.now().difference(answeredAt) < completionPromptDelay) {
        continue;
      }
      // Window check: only ask while this prayer is still the current one.
      final times = _today?.times;
      if (times != null) {
        final prayerTime = times[prayer];
        if (prayerTime == null || now.isBefore(prayerTime)) continue;
        final next = nextPrayer;
        if (next != null && !now.isBefore(next.value)) continue;
        // If another prayer has entered since, the window is closed.
        final entered = times.entries
            .where((e) => !now.isBefore(e.value))
            .map((e) => e.value)
            .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
        if (entered != null && entered.isAfter(prayerTime)) continue;
      }
      return prayer;
    }
    return null;
  }

  /// Cancels the follow-up for the prayer window that is currently open
  /// (i.e. the prayer already entered but its follow-up has not fired yet).
  /// Follow-ups for future days remain scheduled.
  Future<void> cancelCurrentFollowUp(SalahPrayer prayer) async {
    final followUpMillis = PrayerSchedulerService.followUpDelay.inMilliseconds;
    final reminders = repository.loadScheduledReminders();
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final remaining = <ScheduledReminder>[];
    var changed = false;
    for (final r in reminders) {
      final isCurrentWindowFollowUp =
          r.kind == ReminderKind.followUp &&
          r.prayer == prayer &&
          r.scheduledAtMillis > nowMillis &&
          r.scheduledAtMillis - followUpMillis <= nowMillis;
      if (isCurrentWindowFollowUp) {
        await notificationService.cancel(r.notificationId);
        changed = true;
      } else {
        remaining.add(r);
      }
    }
    if (changed) await repository.saveScheduledReminders(remaining);
  }

  // --------------------------------------------------------- debug/insight

  /// Persisted schedule, exposed through the controller so screens never
  /// reach into the repository directly.
  List<ScheduledReminder> get scheduledReminders =>
      repository.loadScheduledReminders();

  DateTime? get lastSchedulingTime => repository.loadLastCalculationDate();

  /// Scheduling health snapshot for the debug screen.
  ({
    int primary,
    int followUps,
    int snoozes,
    DateTime? lastPrimaryAt,
    double daysOfCoverage,
  })
  get schedulingStats {
    final reminders = repository.loadScheduledReminders();
    var primary = 0, followUps = 0, snoozes = 0;
    DateTime? lastPrimaryAt;
    for (final r in reminders) {
      switch (r.kind) {
        case ReminderKind.prayer:
          primary++;
          if (lastPrimaryAt == null || r.scheduledAt.isAfter(lastPrimaryAt)) {
            lastPrimaryAt = r.scheduledAt;
          }
        case ReminderKind.followUp:
          followUps++;
        case ReminderKind.snooze:
          snoozes++;
        case ReminderKind.refresh:
          break;
      }
    }
    final coverage =
        lastPrimaryAt == null
            ? 0.0
            : lastPrimaryAt.difference(DateTime.now()).inMinutes / (60 * 24);
    return (
      primary: primary,
      followUps: followUps,
      snoozes: snoozes,
      lastPrimaryAt: lastPrimaryAt,
      daysOfCoverage: coverage < 0 ? 0.0 : coverage,
    );
  }

  // ------------------------------------------------------ one-time guidance

  /// Whether the Android full-screen intent guidance dialog should be shown.
  /// Only Android 14+ (SDK 34) requires the user-granted special permission;
  /// older versions grant USE_FULL_SCREEN_INTENT at install, so the dialog
  /// would be noise there.
  Future<bool> needsFullScreenGuidance() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    if (repository.flagSet(PrayerSettingsRepository.fullScreenGuidanceFlag)) {
      return false;
    }
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt >= 34;
    } catch (e) {
      debugPrint('SDK version detection failed: $e');
      // Unknown SDK: show the guidance rather than risk silent breakage.
      return true;
    }
  }

  /// User accepted the guidance: mark shown and route to system settings.
  Future<void> acceptFullScreenGuidance() async {
    await repository.setFlag(PrayerSettingsRepository.fullScreenGuidanceFlag);
    await notificationService.requestFullScreenIntent();
  }

  Future<void> dismissFullScreenGuidance() =>
      repository.setFlag(PrayerSettingsRepository.fullScreenGuidanceFlag);

  /// Returns the device manufacturer name if it is one of the aggressive
  /// battery-killer OEMs and the guidance has not been shown yet, else null.
  Future<String?> pendingBatteryGuidance() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    if (repository.flagSet(PrayerSettingsRepository.batteryGuidanceFlag)) {
      return null;
    }
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final manufacturer = info.manufacturer.toLowerCase();
      const aggressive = {
        'xiaomi', 'redmi', 'poco', // Xiaomi family
        'huawei', 'honor', // Huawei family
        'samsung',
        'oneplus',
        'oppo', 'realme', // Oppo family
        'vivo', 'iqoo', // Vivo family
      };
      if (aggressive.contains(manufacturer)) return info.manufacturer;
    } catch (e) {
      debugPrint('Manufacturer detection failed: $e');
    }
    return null;
  }

  Future<void> markBatteryGuidanceShown() =>
      repository.setFlag(PrayerSettingsRepository.batteryGuidanceFlag);

  @override
  void dispose() {
    _midnightTimer?.cancel();
    _prayerWatchTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
