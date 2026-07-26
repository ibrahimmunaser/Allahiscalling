import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/prayer_response.dart';
import '../models/prayer_settings.dart';
import '../models/salah_prayer.dart';
import '../models/scheduled_reminder.dart';

/// Persists prayer settings, scheduled notification IDs, and calculation
/// bookkeeping (last calculation date, last known timezone/coordinates).
class PrayerSettingsRepository {
  // Public so the notification background isolate (which cannot construct the
  // full repository graph) can read the same keys directly.
  static const settingsKey = 'prayer_settings';
  static const scheduledRemindersKey = 'scheduled_reminders';

  static const _settingsKey = settingsKey;
  static const _scheduledRemindersKey = scheduledRemindersKey;
  static const _lastCalculationDateKey = 'last_calculation_date';
  static const _lastTimezoneKey = 'last_known_timezone';
  static const _lastLatitudeKey = 'last_known_latitude';
  static const _lastLongitudeKey = 'last_known_longitude';
  static const _completionsKey = 'prayer_completions_v1';
  static const _answersKey = 'prayer_answers_v1';

  /// One-time UX flags.
  static const fullScreenGuidanceFlag = 'fsi_guidance_shown_v1';
  static const batteryGuidanceFlag = 'oem_battery_guidance_shown_v1';

  final SharedPreferences _prefs;

  PrayerSettingsRepository(this._prefs);

  /// Shared preferences instance, reused by other services (e.g. the
  /// geocoding cache) so the app has a single storage handle.
  SharedPreferences get prefs => _prefs;

  static Future<PrayerSettingsRepository> create() async {
    return PrayerSettingsRepository(await SharedPreferences.getInstance());
  }

  // ---------------------------------------------------------------- settings

  PrayerSettings loadSettings() {
    final raw = _prefs.getString(_settingsKey);
    if (raw == null) return const PrayerSettings();
    try {
      return PrayerSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const PrayerSettings();
    }
  }

  Future<void> saveSettings(PrayerSettings settings) async {
    await _prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
  }

  // ---------------------------------------------------- scheduled reminders

  List<ScheduledReminder> loadScheduledReminders() {
    final raw = _prefs.getString(_scheduledRemindersKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => ScheduledReminder.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveScheduledReminders(List<ScheduledReminder> reminders) async {
    await _prefs.setString(
      _scheduledRemindersKey,
      jsonEncode(reminders.map((r) => r.toJson()).toList()),
    );
  }

  // -------------------------------------------------------------- bookkeeping

  DateTime? loadLastCalculationDate() {
    final millis = _prefs.getInt(_lastCalculationDateKey);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> saveLastCalculationDate(DateTime date) async {
    await _prefs.setInt(_lastCalculationDateKey, date.millisecondsSinceEpoch);
  }

  String? loadLastKnownTimezone() => _prefs.getString(_lastTimezoneKey);

  Future<void> saveLastKnownTimezone(String timezone) async {
    await _prefs.setString(_lastTimezoneKey, timezone);
  }

  ({double latitude, double longitude})? loadLastKnownCoordinates() {
    final lat = _prefs.getDouble(_lastLatitudeKey);
    final lng = _prefs.getDouble(_lastLongitudeKey);
    if (lat == null || lng == null) return null;
    return (latitude: lat, longitude: lng);
  }

  Future<void> saveLastKnownCoordinates(
    double latitude,
    double longitude,
  ) async {
    await _prefs.setDouble(_lastLatitudeKey, latitude);
    await _prefs.setDouble(_lastLongitudeKey, longitude);
  }

  // ----------------------------------------------------------- one-time flags

  bool flagSet(String key) => _prefs.getBool(key) ?? false;

  Future<void> setFlag(String key) async {
    await _prefs.setBool(key, true);
  }

  // ------------------------------------------------------- prayer completions

  /// Marks [prayer] completed on the local calendar day of [localDate].
  /// Only the last 60 days are retained.
  Future<void> savePrayerCompletion(
    DateTime localDate,
    SalahPrayer prayer,
  ) async {
    final map = _loadCompletionsRaw();
    final key = _dateKey(localDate);
    final existing =
        (map[key] as List<dynamic>? ?? const []).cast<String>().toSet();
    existing.add(prayer.name);
    map[key] = existing.toList();

    // Prune anything older than 60 days.
    final cutoff = _dateKey(localDate.subtract(const Duration(days: 60)));
    map.removeWhere((k, _) => k.compareTo(cutoff) < 0);

    await _prefs.setString(_completionsKey, jsonEncode(map));
  }

  bool isPrayerCompleted(DateTime localDate, SalahPrayer prayer) {
    final list = _loadCompletionsRaw()[_dateKey(localDate)];
    return list is List && list.contains(prayer.name);
  }

  Map<String, dynamic> _loadCompletionsRaw() {
    final raw = _prefs.getString(_completionsKey);
    if (raw == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  // ------------------------------------------------------ prayer responses

  /// Records how the user responded to [prayer]'s reminder on the local
  /// calendar day of [localDate]: answered, declined, or dismissed. The
  /// latest response wins (e.g. dismissing first, then answering from the
  /// follow-up, ends as answered).
  ///
  /// Completion ("marked complete") is stored separately via
  /// [savePrayerCompletion] — it is an outcome, not a reminder response.
  Future<void> savePrayerResponse(
    DateTime localDate,
    SalahPrayer prayer,
    PrayerResponseState state,
    DateTime at,
  ) async {
    final map = _loadResponsesRaw();
    final key = _dateKey(localDate);
    final day = Map<String, dynamic>.from(map[key] as Map? ?? {});
    day[prayer.name] = {'state': state.name, 'at': at.millisecondsSinceEpoch};
    map[key] = day;

    // Prune anything older than 3 days; responses only matter same-day.
    final cutoff = _dateKey(localDate.subtract(const Duration(days: 3)));
    map.removeWhere((k, _) => k.compareTo(cutoff) < 0);

    await _prefs.setString(_answersKey, jsonEncode(map));
  }

  /// The latest recorded response for [prayer] on the day of [localDate].
  PrayerResponseState? prayerResponse(DateTime localDate, SalahPrayer prayer) {
    final entry = _responseEntry(localDate, prayer);
    if (entry == null) return null;
    final stateName = entry['state'];
    for (final s in PrayerResponseState.values) {
      if (s.name == stateName) return s;
    }
    return null;
  }

  /// When [prayer] was answered on the day of [localDate], or null when the
  /// latest response is not "answered".
  DateTime? prayerAnsweredAt(DateTime localDate, SalahPrayer prayer) {
    final entry = _responseEntry(localDate, prayer);
    if (entry == null || entry['state'] != PrayerResponseState.answered.name) {
      return null;
    }
    final millis = entry['at'];
    if (millis is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis.toInt());
  }

  Map<String, dynamic>? _responseEntry(DateTime localDate, SalahPrayer prayer) {
    final day = _loadResponsesRaw()[_dateKey(localDate)];
    if (day is! Map) return null;
    final entry = day[prayer.name];
    if (entry is! Map) return null;
    return Map<String, dynamic>.from(entry);
  }

  Map<String, dynamic> _loadResponsesRaw() {
    final raw = _prefs.getString(_answersKey);
    if (raw == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
