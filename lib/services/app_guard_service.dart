import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// An installed app the user could choose to guard. Phone/default SMS are
/// already excluded by the native side (see AppGuardPlugin, Android).
class GuardableApp {
  final String package;
  final String label;

  /// Coarse Android category: `social`, `video`, `game`, `audio`, `image`,
  /// `news`, or `other`. Used by quick-select presets.
  final String category;

  const GuardableApp({
    required this.package,
    required this.label,
    this.category = 'other',
  });

  factory GuardableApp.fromMap(Map<dynamic, dynamic> map) => GuardableApp(
    package: map['package'] as String,
    label: map['label'] as String,
    category: (map['category'] as String?) ?? 'other',
  );
}

/// Android-only bridge to App Guard: covers an app the user chose with the
/// "Allah is calling" screen for 15 minutes after a prayer enters, every
/// time they open it, until they Answer (goes home) or Decline (allowed for
/// the rest of this window).
///
/// A no-op shell on every other platform so callers never need `Platform.isAndroid`
/// guards of their own.
class AppGuardService {
  static const MethodChannel _channel = MethodChannel(
    'com.salahinvite.allah_invites_you_to_salah/app_guard',
  );

  bool get isSupported => !kIsWeb && Platform.isAndroid;

  Future<bool> hasUsageAccess() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasUsageAccess') ?? false;
    } catch (e) {
      debugPrint('AppGuard hasUsageAccess failed: $e');
      return false;
    }
  }

  Future<void> requestUsageAccess() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('requestUsageAccess');
    } catch (e) {
      debugPrint('AppGuard requestUsageAccess failed: $e');
    }
  }

  Future<bool> hasOverlayPermission() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasOverlayPermission') ??
          false;
    } catch (e) {
      debugPrint('AppGuard hasOverlayPermission failed: $e');
      return false;
    }
  }

  Future<void> requestOverlayPermission() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('requestOverlayPermission');
    } catch (e) {
      debugPrint('AppGuard requestOverlayPermission failed: $e');
    }
  }

  /// Both special permissions the guard feature needs to actually work.
  Future<bool> hasAllPermissions() async {
    if (!isSupported) return false;
    final usage = await hasUsageAccess();
    final overlay = await hasOverlayPermission();
    return usage && overlay;
  }

  Future<List<GuardableApp>> getInstalledApps() async {
    if (!isSupported) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'getInstalledApps',
      );
      return (raw ?? const [])
          .map((e) => GuardableApp.fromMap(e as Map<dynamic, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('AppGuard getInstalledApps failed: $e');
      return const [];
    }
  }

  Future<void> setGuardEnabled(bool enabled) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setGuardEnabled', {'enabled': enabled});
    } catch (e) {
      debugPrint('AppGuard setGuardEnabled failed: $e');
    }
  }

  Future<void> setGuardedPackages(List<String> packages) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setGuardedPackages', {
        'packages': packages,
      });
    } catch (e) {
      debugPrint('AppGuard setGuardedPackages failed: $e');
    }
  }

  /// Schedules the 15-minute guard window to start at [triggerAt] (the
  /// prayer's entry time), keyed by the same deterministic [id] as the
  /// prayer's primary notification, so cancelling one id cancels both.
  Future<void> scheduleGuardWindow({
    required int id,
    required String prayer,
    required DateTime triggerAt,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('scheduleGuardWindow', {
        'id': id,
        'prayer': prayer,
        'triggerAtMillis': triggerAt.toUtc().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('AppGuard scheduleGuardWindow failed: $e');
    }
  }

  Future<void> cancelGuardWindow(int id) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('cancelGuardWindow', {'id': id});
    } catch (e) {
      debugPrint('AppGuard cancelGuardWindow failed: $e');
    }
  }

  Future<void> cancelAllGuardWindows() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('cancelAllGuardWindows');
    } catch (e) {
      debugPrint('AppGuard cancelAllGuardWindows failed: $e');
    }
  }
}
