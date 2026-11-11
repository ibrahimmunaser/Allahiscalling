import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/salah_prayer.dart';

/// Android-only bridge to a direct-launch native alarm (see
/// `IncomingCallAlarmReceiver.kt`) that force-foregrounds the app the
/// instant a prayer enters, when "Display over other apps" is granted.
///
/// Why this exists: the ordinary prayer notification's `fullScreenIntent`
/// only auto-presents as a full screen while the device is locked/off —
/// while unlocked and in another app, Android downgrades it to a heads-up
/// banner the user must tap, so the "incoming call" never visibly takes
/// over. This alarm closes that gap, the same way App Guard's block screen
/// already bypasses it. A no-op shell on every other platform.
class IncomingCallAlarmService {
  static const MethodChannel _channel = MethodChannel(
    'com.salahinvite.allah_invites_you_to_salah/incoming_call',
  );

  bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// Schedules the direct-launch alarm for [triggerAt], keyed by the same
  /// deterministic [id] as the prayer's primary notification so cancelling
  /// one id cancels both.
  Future<void> schedule({
    required int id,
    required SalahPrayer prayer,
    required DateTime triggerAt,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('schedule', {
        'id': id,
        'prayer': prayer.name,
        'triggerAtMillis': triggerAt.toUtc().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('IncomingCallAlarm schedule failed: $e');
    }
  }

  Future<void> cancel(int id) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('cancel', {'id': id});
    } catch (e) {
      debugPrint('IncomingCallAlarm cancel failed: $e');
    }
  }

  Future<void> cancelAll() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('cancelAll');
    } catch (e) {
      debugPrint('IncomingCallAlarm cancelAll failed: $e');
    }
  }

  /// Whether "Display over other apps" is granted — without it, this alarm
  /// can only record the pending prayer, never force-launch the app.
  Future<bool> hasOverlayPermission() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasOverlayPermission') ??
          false;
    } catch (e) {
      debugPrint('IncomingCallAlarm hasOverlayPermission failed: $e');
      return false;
    }
  }

  /// Consumes (reads and clears) a pending direct-launch prayer recorded by
  /// the native alarm, if any. Call at cold start and on every app resume —
  /// whichever observes it first wins; the native side clears it so it is
  /// only ever presented once.
  Future<SalahPrayer?> consumePending() async {
    if (!isSupported) return null;
    try {
      final raw = await _channel.invokeMethod<String>('consumePending');
      if (raw == null) return null;
      return SalahPrayer.fromName(raw);
    } catch (e) {
      debugPrint('IncomingCallAlarm consumePending failed: $e');
      return null;
    }
  }
}
