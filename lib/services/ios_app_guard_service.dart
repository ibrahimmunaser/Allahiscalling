import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/salah_prayer.dart';

/// iOS-only bridge to App Guard (Screen Time): FamilyControls authorization,
/// the system app/category picker, and keeping the 5 daily
/// `DeviceActivitySchedule`s in sync with today's prayer times.
///
/// Unlike Android's [AppGuardService] (per-package list + a custom block
/// screen), iOS shields whatever the user picked in Apple's own
/// `FamilyActivityPicker` with Apple's own shield UI — this app never learns
/// which real apps were chosen (see GuardShared.swift for why). It is a
/// no-op shell on every other platform, and also degrades to reporting
/// "unsupported" on-device until Apple approves the Family Controls
/// entitlement and the extension targets are enabled — see
/// IOS_SCREEN_TIME_SETUP.md.
class IosAppGuardService {
  static const MethodChannel _channel = MethodChannel(
    'com.salahinvite.allah_invites_you_to_salah/app_guard_ios',
  );

  bool get isPlatformIOS => !kIsWeb && Platform.isIOS;

  /// Whether the running build actually has the Screen Time extensions
  /// compiled in (false until ENABLE_SCREEN_TIME_EXTENSIONS=1 ships — see
  /// IOS_SCREEN_TIME_SETUP.md). Checked live rather than assumed, since the
  /// same Dart code ships before and after that flag flips.
  Future<bool> isSupported() async {
    if (!isPlatformIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (e) {
      debugPrint('IosAppGuard isSupported failed: $e');
      return false;
    }
  }

  /// `"approved"`, `"denied"`, `"notDetermined"`, or `"unavailable"`.
  Future<String> authorizationStatus() async {
    if (!isPlatformIOS) return 'unavailable';
    try {
      return await _channel.invokeMethod<String>('authorizationStatus') ??
          'unavailable';
    } catch (e) {
      debugPrint('IosAppGuard authorizationStatus failed: $e');
      return 'unavailable';
    }
  }

  /// Prompts the user for FamilyControls authorization. Returns the
  /// resulting status (same values as [authorizationStatus]).
  Future<String> requestAuthorization() async {
    if (!isPlatformIOS) return 'unavailable';
    try {
      return await _channel.invokeMethod<String>('requestAuthorization') ??
          'unavailable';
    } catch (e) {
      debugPrint('IosAppGuard requestAuthorization failed: $e');
      return 'unavailable';
    }
  }

  /// Presents Apple's `FamilyActivityPicker` modally. Returns how many
  /// apps/categories ended up selected (never which ones — Apple never
  /// tells this app that), or null if the user cancelled/it failed.
  Future<({int appsCount, int categoriesCount})?> presentPicker() async {
    if (!isPlatformIOS) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'presentPicker',
      );
      if (raw == null) return null;
      return (
        appsCount: raw['appsCount'] as int? ?? 0,
        categoriesCount: raw['categoriesCount'] as int? ?? 0,
      );
    } catch (e) {
      debugPrint('IosAppGuard presentPicker failed: $e');
      return null;
    }
  }

  Future<void> setGuardEnabled(bool enabled) async {
    if (!isPlatformIOS) return;
    try {
      await _channel.invokeMethod('setGuardEnabled', {'enabled': enabled});
    } catch (e) {
      debugPrint('IosAppGuard setGuardEnabled failed: $e');
    }
  }

  /// Replaces all 5 prayers' `DeviceActivitySchedule`s with [nextByPrayer]'s
  /// times (local wall-clock hour/minute — DeviceActivitySchedule itself
  /// repeats daily, so only today's upcoming time per prayer is needed).
  /// A no-op on the native side when guarding is disabled.
  Future<void> syncSchedule(Map<SalahPrayer, DateTime> nextByPrayer) async {
    if (!isPlatformIOS) return;
    try {
      await _channel.invokeMethod('scheduleGuardWindows', {
        'windows': [
          for (final entry in nextByPrayer.entries)
            {
              'prayer': entry.key.displayName,
              'hour': entry.value.hour,
              'minute': entry.value.minute,
            },
        ],
      });
    } catch (e) {
      debugPrint('IosAppGuard scheduleGuardWindows failed: $e');
    }
  }

  Future<void> cancelAllGuardWindows() async {
    if (!isPlatformIOS) return;
    try {
      await _channel.invokeMethod('cancelAllGuardWindows');
    } catch (e) {
      debugPrint('IosAppGuard cancelAllGuardWindows failed: $e');
    }
  }
}
