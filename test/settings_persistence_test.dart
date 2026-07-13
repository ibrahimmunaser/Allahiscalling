import 'package:allah_invites_you_to_salah/models/prayer_settings.dart';
import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/models/scheduled_reminder.dart';
import 'package:allah_invites_you_to_salah/repositories/prayer_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PrayerSettingsRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repository =
        PrayerSettingsRepository(await SharedPreferences.getInstance());
  });

  group('settings persistence', () {
    test('defaults are returned when nothing is stored', () {
      final settings = repository.loadSettings();
      expect(settings.calculationMethod,
          CalculationMethodOption.isna);
      expect(settings.asrMethod, AsrMethod.standard);
      expect(settings.snoozeMinutes, 10);
      expect(settings.notificationsEnabled, isTrue);
      expect(settings.hasLocation, isFalse);
    });

    test('full round-trip preserves every field', () async {
      const original = PrayerSettings(
        latitude: 21.4225,
        longitude: 39.8262,
        locationLabel: 'Makkah, Saudi Arabia',
        locationSource: LocationSource.manualCity,
        timezone: 'Asia/Riyadh',
        calculationMethod: CalculationMethodOption.ummAlQura,
        asrMethod: AsrMethod.hanafi,
        highLatitudeRule: HighLatitudeRuleOption.seventhOfTheNight,
        customFajrAngle: 19.0,
        customIshaAngle: 16.5,
        manualAdjustments: {
          SalahPrayer.fajr: 2,
          SalahPrayer.asr: -1,
          SalahPrayer.isha: 3,
        },
        notificationsEnabled: false,
        snoozeMinutes: 15,
        hijriAdjustmentDays: -1,
      );

      await repository.saveSettings(original);
      final loaded = repository.loadSettings();

      expect(loaded.latitude, original.latitude);
      expect(loaded.longitude, original.longitude);
      expect(loaded.locationLabel, original.locationLabel);
      expect(loaded.locationSource, original.locationSource);
      expect(loaded.timezone, original.timezone);
      expect(loaded.calculationMethod, original.calculationMethod);
      expect(loaded.asrMethod, original.asrMethod);
      expect(loaded.highLatitudeRule, original.highLatitudeRule);
      expect(loaded.customFajrAngle, original.customFajrAngle);
      expect(loaded.customIshaAngle, original.customIshaAngle);
      expect(loaded.manualAdjustments, original.manualAdjustments);
      expect(loaded.notificationsEnabled, original.notificationsEnabled);
      expect(loaded.snoozeMinutes, original.snoozeMinutes);
      expect(loaded.hijriAdjustmentDays, original.hijriAdjustmentDays);
    });

    test('hijri adjustment defaults to 0 and clamps to -2..+2', () async {
      expect(repository.loadSettings().hijriAdjustmentDays, 0);

      SharedPreferences.setMockInitialValues(
          {'prayer_settings': '{"hijriAdjustmentDays": 9}'});
      final repo =
          PrayerSettingsRepository(await SharedPreferences.getInstance());
      expect(repo.loadSettings().hijriAdjustmentDays, 2);
    });

    test('corrupted stored JSON falls back to defaults', () async {
      SharedPreferences.setMockInitialValues(
          {'prayer_settings': 'not json at all'});
      final repo =
          PrayerSettingsRepository(await SharedPreferences.getInstance());
      expect(repo.loadSettings().calculationMethod,
          CalculationMethodOption.isna);
    });
  });

  group('scheduled reminder persistence', () {
    test('round-trips reminder list', () async {
      final reminders = [
        const ScheduledReminder(
          notificationId: 12345,
          prayer: SalahPrayer.fajr,
          scheduledAtMillis: 1780000000000,
        ),
        const ScheduledReminder(
          notificationId: 67890,
          prayer: SalahPrayer.isha,
          scheduledAtMillis: 1780050000000,
        ),
      ];

      await repository.saveScheduledReminders(reminders);
      final loaded = repository.loadScheduledReminders();

      expect(loaded, hasLength(2));
      expect(loaded[0].notificationId, 12345);
      expect(loaded[0].prayer, SalahPrayer.fajr);
      expect(loaded[1].notificationId, 67890);
      expect(loaded[1].prayer, SalahPrayer.isha);
      expect(loaded[1].scheduledAtMillis, 1780050000000);
    });
  });

  group('default method suggestions', () {
    test('always returns ISNA as the Sunni default', () {
      expect(PrayerSettings.suggestMethodForTimezone('America/New_York'),
          CalculationMethodOption.isna);
      expect(PrayerSettings.suggestMethodForTimezone('Asia/Riyadh'),
          CalculationMethodOption.isna);
      expect(PrayerSettings.suggestMethodForTimezone('Europe/London'),
          CalculationMethodOption.isna);
      expect(PrayerSettings.suggestMethodForTimezone(null),
          CalculationMethodOption.isna);
    });
  });
}
