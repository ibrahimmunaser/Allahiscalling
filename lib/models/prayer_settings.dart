import 'salah_prayer.dart';

/// Supported calculation methods (app-level, mapped to adhan_dart in the
/// prayer time service).
///
/// Only mainstream Sunni conventions are exposed. Sect-specific methods
/// (Jafari / Ithna-Ashari / Qum / Tehran, Ahmadiyya, etc.) are intentionally
/// excluded and must not be added to this list.
enum CalculationMethodOption {
  isna('North America (ISNA)'),
  muslimWorldLeague('Muslim World League'),
  ummAlQura('Umm al-Qura (Makkah)'),
  karachi('Karachi (Univ. of Islamic Sciences)'),
  egyptian('Egyptian General Authority'),
  diyanet('Diyanet (Turkiye)'),
  jakim('JAKIM (Malaysia)'),
  muis('MUIS (Singapore)'),
  kemenag('Kemenag (Indonesia)'),
  tunisia('Tunisia Ministry of Religious Affairs'),
  algeria('Algeria Ministry of Religious Affairs'),
  russia('Spiritual Administration of Muslims of Russia'),
  custom('Custom Sunni Angles');

  final String displayName;

  const CalculationMethodOption(this.displayName);
}

/// Asr juristic method.
enum AsrMethod {
  standard("Standard (Shafi'i, Maliki, Hanbali)"),
  hanafi('Hanafi');

  final String displayName;

  const AsrMethod(this.displayName);
}

/// Rule for Fajr/Isha at high latitudes where twilight may persist.
enum HighLatitudeRuleOption {
  middleOfTheNight('Middle of the night'),
  seventhOfTheNight('One seventh of the night'),
  twilightAngle('Twilight angle');

  final String displayName;

  const HighLatitudeRuleOption(this.displayName);
}

/// How the location was chosen.
enum LocationSource {
  device('Device location'),
  manualCity('Manual city'),
  manualCoordinates('Manual coordinates');

  final String displayName;

  const LocationSource(this.displayName);
}

/// All user-configurable prayer calculation and reminder settings.
class PrayerSettings {
  final double? latitude;
  final double? longitude;

  /// Human-readable label for the location (city name or "lat, lng").
  final String? locationLabel;
  final LocationSource locationSource;

  /// IANA timezone identifier, e.g. "America/New_York".
  final String? timezone;

  final CalculationMethodOption calculationMethod;
  final AsrMethod asrMethod;
  final HighLatitudeRuleOption highLatitudeRule;

  /// Custom angles, used only when [calculationMethod] is custom.
  final double customFajrAngle;
  final double customIshaAngle;

  /// Manual minute offsets per prayer, e.g. {fajr: 2, asr: -1}.
  final Map<SalahPrayer, int> manualAdjustments;

  final bool notificationsEnabled;

  /// Snooze duration in minutes.
  final int snoozeMinutes;

  /// Displayed Hijri date offset in days (-2..+2) to match the local
  /// moon-sighting authority. Display only — never affects salah times.
  final int hijriAdjustmentDays;

  const PrayerSettings({
    this.latitude,
    this.longitude,
    this.locationLabel,
    this.locationSource = LocationSource.device,
    this.timezone,
    this.calculationMethod = CalculationMethodOption.isna,
    this.asrMethod = AsrMethod.standard,
    this.highLatitudeRule = HighLatitudeRuleOption.middleOfTheNight,
    this.customFajrAngle = 18.0,
    this.customIshaAngle = 17.0,
    this.manualAdjustments = const {},
    this.notificationsEnabled = true,
    this.snoozeMinutes = 10,
    this.hijriAdjustmentDays = 0,
  });

  bool get hasLocation => latitude != null && longitude != null;

  int adjustmentFor(SalahPrayer prayer) => manualAdjustments[prayer] ?? 0;

  PrayerSettings copyWith({
    double? latitude,
    double? longitude,
    String? locationLabel,
    LocationSource? locationSource,
    String? timezone,
    CalculationMethodOption? calculationMethod,
    AsrMethod? asrMethod,
    HighLatitudeRuleOption? highLatitudeRule,
    double? customFajrAngle,
    double? customIshaAngle,
    Map<SalahPrayer, int>? manualAdjustments,
    bool? notificationsEnabled,
    int? snoozeMinutes,
    int? hijriAdjustmentDays,
  }) {
    return PrayerSettings(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationLabel: locationLabel ?? this.locationLabel,
      locationSource: locationSource ?? this.locationSource,
      timezone: timezone ?? this.timezone,
      calculationMethod: calculationMethod ?? this.calculationMethod,
      asrMethod: asrMethod ?? this.asrMethod,
      highLatitudeRule: highLatitudeRule ?? this.highLatitudeRule,
      customFajrAngle: customFajrAngle ?? this.customFajrAngle,
      customIshaAngle: customIshaAngle ?? this.customIshaAngle,
      manualAdjustments: manualAdjustments ?? this.manualAdjustments,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      snoozeMinutes: snoozeMinutes ?? this.snoozeMinutes,
      hijriAdjustmentDays: hijriAdjustmentDays ?? this.hijriAdjustmentDays,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'locationLabel': locationLabel,
      'locationSource': locationSource.name,
      'timezone': timezone,
      'calculationMethod': calculationMethod.name,
      'asrMethod': asrMethod.name,
      'highLatitudeRule': highLatitudeRule.name,
      'customFajrAngle': customFajrAngle,
      'customIshaAngle': customIshaAngle,
      'manualAdjustments': manualAdjustments.map(
        (prayer, minutes) => MapEntry(prayer.name, minutes),
      ),
      'notificationsEnabled': notificationsEnabled,
      'snoozeMinutes': snoozeMinutes,
      'hijriAdjustmentDays': hijriAdjustmentDays,
    };
  }

  factory PrayerSettings.fromJson(Map<String, dynamic> json) {
    final rawAdjustments =
        (json['manualAdjustments'] as Map?)?.cast<String, dynamic>() ?? {};
    final adjustments = <SalahPrayer, int>{};
    for (final entry in rawAdjustments.entries) {
      final prayer = SalahPrayer.fromName(entry.key);
      if (prayer != null) {
        adjustments[prayer] = (entry.value as num).toInt();
      }
    }

    T enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
      if (name is! String) return fallback;
      for (final v in values) {
        if (v.name == name) return v;
      }
      return fallback;
    }

    return PrayerSettings(
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      locationLabel: json['locationLabel'] as String?,
      locationSource: enumByName(
        LocationSource.values,
        json['locationSource'],
        LocationSource.device,
      ),
      timezone: json['timezone'] as String?,
      calculationMethod: enumByName(
        CalculationMethodOption.values,
        json['calculationMethod'],
        CalculationMethodOption.isna,
      ),
      asrMethod: enumByName(
        AsrMethod.values,
        json['asrMethod'],
        AsrMethod.standard,
      ),
      highLatitudeRule: enumByName(
        HighLatitudeRuleOption.values,
        json['highLatitudeRule'],
        HighLatitudeRuleOption.middleOfTheNight,
      ),
      customFajrAngle: (json['customFajrAngle'] as num?)?.toDouble() ?? 18.0,
      customIshaAngle: (json['customIshaAngle'] as num?)?.toDouble() ?? 17.0,
      manualAdjustments: adjustments,
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      // Note: a legacy 'reminderStyle' key may exist in stored settings from
      // older builds; it is intentionally ignored. The call-style incoming
      // experience is the single, consistent experience for every user.
      snoozeMinutes: (json['snoozeMinutes'] as num?)?.toInt() ?? 10,
      hijriAdjustmentDays: ((json['hijriAdjustmentDays'] as num?)?.toInt() ?? 0)
          .clamp(-2, 2),
    );
  }

  /// Default calculation method for new users. ISNA is the app default;
  /// users can switch to other Sunni methods in Settings.
  static CalculationMethodOption suggestMethodForTimezone(String? timezone) {
    return CalculationMethodOption.isna;
  }
}
