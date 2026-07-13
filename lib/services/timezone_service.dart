import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:lat_lng_to_timezone/lat_lng_to_timezone.dart' as tz_lookup;
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Detects the device timezone and initializes the IANA timezone database.
///
/// DST is handled automatically: all conversions go through the `timezone`
/// package which applies the correct UTC offset for each instant.
class TimezoneService {
  static bool _initialized = false;

  /// Loads the timezone database. Safe to call repeatedly.
  static void ensureInitialized() {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    _initialized = true;
  }

  /// Returns the device's IANA timezone identifier, e.g. "America/New_York".
  Future<String> detectTimezone() async {
    ensureInitialized();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      final identifier = info.identifier;
      // Validate against the database; fall back to UTC if unknown.
      tz.getLocation(identifier);
      return identifier;
    } catch (e) {
      debugPrint('Timezone detection failed: $e');
      return 'UTC';
    }
  }

  /// Resolves the IANA timezone for coordinates using an offline boundary
  /// lookup. City names are never trusted for this; coordinates are.
  String timezoneForCoordinates(double latitude, double longitude) {
    ensureInitialized();
    try {
      final identifier = tz_lookup.latLngToTimezoneString(latitude, longitude);
      tz.getLocation(identifier);
      return identifier;
    } catch (e) {
      debugPrint('Coordinate timezone lookup failed: $e');
      return 'UTC';
    }
  }

  /// Whether the timezone identifier is valid in the bundled database.
  bool isValidTimezone(String identifier) {
    ensureInitialized();
    try {
      tz.getLocation(identifier);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// True when the detected timezone differs from the stored one.
  Future<bool> hasTimezoneChanged(String? lastKnownTimezone) async {
    if (lastKnownTimezone == null) return true;
    final current = await detectTimezone();
    return current != lastKnownTimezone;
  }
}
