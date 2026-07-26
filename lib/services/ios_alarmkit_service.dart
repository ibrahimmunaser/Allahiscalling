import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/salah_prayer.dart';

/// Pending Answer payload delivered from the native AlarmKit App Intent.
class AlarmKitAnswer {
  final String alarmId;
  final SalahPrayer prayer;
  final DateTime? scheduledAt;
  final String prayerDisplayName;

  const AlarmKitAnswer({
    required this.alarmId,
    required this.prayer,
    required this.scheduledAt,
    required this.prayerDisplayName,
  });

  factory AlarmKitAnswer.fromMap(Map<dynamic, dynamic> map) {
    final prayerName = map['prayerName'] as String? ?? 'dhuhr';
    final iso = map['scheduledAtISO'] as String?;
    DateTime? scheduledAt;
    if (iso != null && iso.isNotEmpty) {
      scheduledAt = DateTime.tryParse(iso);
    }
    return AlarmKitAnswer(
      alarmId: map['alarmId'] as String? ?? '',
      prayer: SalahPrayer.fromName(prayerName) ?? SalahPrayer.dhuhr,
      scheduledAt: scheduledAt,
      prayerDisplayName:
          map['prayerDisplayName'] as String? ?? '$prayerName Prayer',
    );
  }
}

/// Outcome of a single [IosAlarmKitService.schedulePrayerAlarm] attempt.
enum AlarmKitOutcome {
  /// The native alarm was scheduled successfully.
  scheduled,

  /// AlarmKit is not present on this device/OS version.
  unavailable,

  /// AlarmKit is present but the user has not authorized it.
  notAuthorized,

  /// AlarmKit is present and authorized, but the native schedule call
  /// itself failed (platform channel error).
  failed,
}

/// Result of [IosAlarmKitService.schedulePrayerAlarm]. [alarmId] is always
/// populated (even on failure) so a caller that wants to attempt
/// cancellation/cleanup for this occurrence still can.
class AlarmKitScheduleResult {
  final AlarmKitOutcome outcome;
  final String alarmId;
  final Object? error;

  const AlarmKitScheduleResult({
    required this.outcome,
    required this.alarmId,
    this.error,
  });

  bool get success => outcome == AlarmKitOutcome.scheduled;
}

/// Minimal AlarmKit surface [IosHybridNotificationScheduler] depends on.
///
/// Exists so the hybrid scheduler's AlarmKit routing/success/fallback logic
/// can be unit-tested with a fake: the real [IosAlarmKitService] gates
/// every operation on `Platform.isIOS` and can therefore never exercise its
/// "available and authorized" branches on a non-iOS test host — this
/// repository's CI has no Mac/Xcode (see IOS_STRESS_TEST_REPORT.md).
/// Production code always constructs the concrete [IosAlarmKitService];
/// only tests supply a fake implementation of this interface.
abstract class AlarmKitClient {
  Future<bool> isAvailable();

  Future<bool> get isAuthorized;

  Future<AlarmKitScheduleResult> schedulePrayerAlarm({
    required SalahPrayer prayer,
    required DateTime scheduledAt,
    String? soundName,
  });

  Future<void> cancelAlarmId(String alarmId);

  Future<void> cancelAll();
}

/// Dart side of the iOS AlarmKit MethodChannel bridge.
///
/// On Android / web / older iOS this reports unavailable and never schedules.
class IosAlarmKitService implements AlarmKitClient {
  static const _channel = MethodChannel(
    'com.salahinvite.allah_invites_you_to_salah/alarmkit',
  );

  /// Fired when the native Answer intent opens the app (or the app was
  /// already running and received the pending payload).
  final _answerController = StreamController<AlarmKitAnswer>.broadcast();

  Stream<AlarmKitAnswer> get onAnswered => _answerController.stream;

  bool _listening = false;

  void ensureListening() {
    if (_listening || kIsWeb || !Platform.isIOS) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAlarmAnswered' && call.arguments is Map) {
        _answerController.add(AlarmKitAnswer.fromMap(call.arguments as Map));
      }
    });
  }

  @override
  Future<bool> isAvailable() async {
    if (kIsWeb || !Platform.isIOS) return false;
    try {
      final value = await _channel.invokeMethod<bool>('isAlarmKitAvailable');
      return value ?? false;
    } catch (_) {
      return false;
    }
  }

  /// `authorized` | `denied` | `notDetermined` | `unavailable`
  Future<String> authorizationStatus() async {
    if (kIsWeb || !Platform.isIOS) return 'unavailable';
    try {
      return await _channel.invokeMethod<String>('authorizationStatus') ??
          'unavailable';
    } catch (_) {
      return 'unavailable';
    }
  }

  @override
  Future<bool> get isAuthorized async =>
      (await authorizationStatus()) == 'authorized';

  /// Requests AlarmKit permission. Returns the resulting status string.
  /// Does not re-prompt when already denied — callers should open Settings.
  Future<String> requestAuthorization() async {
    if (kIsWeb || !Platform.isIOS) return 'unavailable';
    final current = await authorizationStatus();
    if (current == 'denied' || current == 'unavailable') return current;
    try {
      return await _channel.invokeMethod<String>('requestAuthorization') ??
          current;
    } catch (_) {
      return current;
    }
  }

  Future<void> openSystemSettings() async {
    if (kIsWeb || !Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('openSystemSettings');
    } catch (_) {}
  }

  /// Stable UUID derived from prayer + scheduled instant so reschedules
  /// replace instead of duplicating.
  static String stableAlarmId(SalahPrayer prayer, DateTime scheduledAt) {
    final utc = scheduledAt.toUtc();
    final minutes = utc.millisecondsSinceEpoch ~/ 60000;
    final hex = minutes.toRadixString(16).padLeft(11, '0');
    final prayerNibble = prayer.index.toRadixString(16);
    return 'a11a000$prayerNibble-0000-4000-8000-${hex.padLeft(12, '0').substring(0, 12)}';
  }

  /// Attempts to schedule a native AlarmKit alarm for [prayer] at
  /// [scheduledAt]. Never throws — every failure mode (unavailable,
  /// unauthorized, or a platform-channel error) is reported through the
  /// returned [AlarmKitScheduleResult] so the caller (the hybrid scheduler)
  /// can restore/keep the local-notification fallback instead of silently
  /// losing the alert.
  @override
  Future<AlarmKitScheduleResult> schedulePrayerAlarm({
    required SalahPrayer prayer,
    required DateTime scheduledAt,
    String? soundName,
  }) async {
    final alarmId = stableAlarmId(prayer, scheduledAt);
    if (!await isAvailable()) {
      return AlarmKitScheduleResult(
        outcome: AlarmKitOutcome.unavailable,
        alarmId: alarmId,
      );
    }
    if (!await isAuthorized) {
      return AlarmKitScheduleResult(
        outcome: AlarmKitOutcome.notAuthorized,
        alarmId: alarmId,
      );
    }
    try {
      await _channel.invokeMethod<void>('schedulePrayerAlarm', {
        'alarmId': alarmId,
        'prayerName': prayer.name,
        'prayerDisplayName': prayer.displayName,
        'title': 'Allah Is Calling',
        'scheduledAtMs': scheduledAt.millisecondsSinceEpoch,
        'scheduledAtISO': scheduledAt.toUtc().toIso8601String(),
        if (soundName != null) 'soundName': soundName,
      });
      return AlarmKitScheduleResult(
        outcome: AlarmKitOutcome.scheduled,
        alarmId: alarmId,
      );
    } catch (e) {
      return AlarmKitScheduleResult(
        outcome: AlarmKitOutcome.failed,
        alarmId: alarmId,
        error: e,
      );
    }
  }

  Future<void> cancelAlarm({
    required SalahPrayer prayer,
    required DateTime scheduledAt,
  }) async {
    if (!await isAvailable()) return;
    try {
      await _channel.invokeMethod<void>('cancelAlarm', {
        'alarmId': stableAlarmId(prayer, scheduledAt),
      });
    } catch (_) {}
  }

  @override
  Future<void> cancelAlarmId(String alarmId) async {
    if (!await isAvailable()) return;
    try {
      await _channel.invokeMethod<void>('cancelAlarm', {'alarmId': alarmId});
    } catch (_) {}
  }

  @override
  Future<void> cancelAll() async {
    if (!await isAvailable()) return;
    try {
      await _channel.invokeMethod<void>('cancelAllAlarms');
    } catch (_) {}
  }

  Future<List<String>> pendingAlarmIds() async {
    if (!await isAvailable()) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('pendingAlarmIds');
      return raw?.cast<String>() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  Future<AlarmKitAnswer?> getPendingAnswer() async {
    if (kIsWeb || !Platform.isIOS) return null;
    try {
      final raw = await _channel.invokeMethod<dynamic>('getPendingAnswer');
      if (raw is Map) return AlarmKitAnswer.fromMap(raw);
    } catch (_) {}
    return null;
  }

  Future<void> clearPendingAnswer() async {
    if (kIsWeb || !Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('clearPendingAnswer');
    } catch (_) {}
  }

  /// Schedules a one-off AlarmKit alert [delay] ahead for debugging.
  Future<void> scheduleDebugAlarm({
    SalahPrayer prayer = SalahPrayer.dhuhr,
    Duration delay = const Duration(minutes: 1),
  }) async {
    final when = DateTime.now().add(delay);
    await schedulePrayerAlarm(prayer: prayer, scheduledAt: when);
  }

  void dispose() {
    _answerController.close();
  }
}
