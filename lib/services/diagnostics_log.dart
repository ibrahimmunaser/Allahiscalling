import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Privacy-conscious diagnostics log for beta testing.
///
/// Stores only the most recent error events (source tag + exception text +
/// timestamp) in a small ring buffer. Deliberately contains NO prayer
/// history, NO coordinates, and NO personal identifiers, so its contents
/// are safe to include in a shared diagnostics report.
class DiagnosticsLog {
  static const String _key = 'diagnostics_error_log_v1';
  static const int _maxEntries = 20;

  /// Records an error event. [source] is a short machine tag such as
  /// 'scheduling' or 'notification_action'. Never throws — diagnostics must
  /// not be able to break the feature it is observing.
  static Future<void> recordError(
    SharedPreferences prefs,
    String source,
    Object error,
  ) async {
    try {
      final entries = load(prefs);
      entries.add({
        'at': DateTime.now().toIso8601String(),
        'source': source,
        // Error text only — call sites never put prayer names or user data
        // in the exception message.
        'error': error.toString(),
      });
      while (entries.length > _maxEntries) {
        entries.removeAt(0);
      }
      await prefs.setString(_key, jsonEncode(entries));
    } catch (e) {
      debugPrint('DiagnosticsLog write failed: $e');
    }
  }

  /// Recent error events, oldest first.
  static List<Map<String, dynamic>> load(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in list)
          if (e is Map) Map<String, dynamic>.from(e)
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> clear(SharedPreferences prefs) => prefs.remove(_key);
}
