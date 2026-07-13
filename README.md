# Allah Invites You to Salah

A Muslim prayer reminder app built with Flutter. When a prayer time enters, the
user receives a platform-compliant, call-style reminder titled
**"Allah Invites You to Salah"**. The incoming screen always presents exactly
two actions — **Answer** and **Decline** — creating a real, conscious decision
at every prayer. Declining is respectful in behavior: it schedules the
configured snooze. The app never uses "Call from Allah" or implies a literal
phone call.

> Prayer times are estimates. Please verify with your local masjid.

## Features

- Offline prayer time calculation (adhan_dart) for Fajr, Dhuhr, Asr, Maghrib, Isha
- Calculation methods (mainstream Sunni only): ISNA (default), Muslim World
  League, Umm al-Qura, Karachi, Egyptian, Diyanet (Turkiye), JAKIM (Malaysia),
  MUIS (Singapore), Kemenag (Indonesia), Tunisia, Algeria, Russia, Custom
  Sunni Angles. Sect-specific methods (Jafari/Ithna-Ashari, Ahmadiyya, etc.)
  are not offered.
- Asr methods: Standard and Hanafi; high-latitude rules
- Manual minute adjustments per prayer
- Location priority: GPS → searchable offline city database (~170k GeoNames
  places, fuzzy search, alternate names, region/country qualifiers) → online
  geocoding fallback (platform geocoder, cached) → manual coordinates
- Timezone always resolved from coordinates (offline boundary lookup), never
  trusted from the city name; correct DST handling (IANA tz database)
- Schedules the next 7 days of reminders; skips passed times; no duplicates
- Recalculates on app launch, after midnight, on location/timezone change, on
  settings change, and on manual "Recalculate"
- Gentle snooze ("Your Salah Reminder"), configurable duration (default 10 min)
- In-app call-style reminder screen, test notification, and a debug screen

## Project structure

```
lib/
  models/         PrayerSettings, SalahPrayer, PrayerDayTimes, ScheduledReminder
  repositories/   PrayerSettingsRepository (shared_preferences persistence)
  services/       PrayerTimeService, LocationService, TimezoneService,
                  LocalNotificationService, PrayerSchedulerService,
                  CityDatabase (offline GeoNames search), GeocodingService
  screens/        HomeScreen, IncomingSalahScreen, SettingsScreen,
                  DebugPrayerScreen, ManualLocationScreen
  state/          AppController (ChangeNotifier, recalculation triggers)
  widgets/        PrayerTimesList, location feedback helpers
  utils/          strings, theme, formatting
assets/geonames/  cities.tsv.gz (offline city database, ~3.6 MB)
tool/             build_city_db.dart (regenerates the city database asset)
```

## Offline city database

The searchable city database is built from [GeoNames](https://www.geonames.org/)
`cities1000` (all places with population > 1000; CC BY 4.0). To regenerate:

1. Download `cities1000.zip`, `admin1CodesASCII.txt`, and `countryInfo.txt`
   from <https://download.geonames.org/export/dump/> into `tool/geodata/`
   and unzip `cities1000.zip`.
2. Run `dart run tool/build_city_db.dart`.

City search only supplies coordinates; prayer times are always calculated
from latitude/longitude, and the timezone is resolved from coordinates.

## Getting started

```bash
flutter pub get
flutter run
```

Run the tests:

```bash
flutter test
```

## Platform setup notes

### Android (already configured in this repo)

- `AndroidManifest.xml`: location, `POST_NOTIFICATIONS`,
  `SCHEDULE_EXACT_ALARM`, `USE_FULL_SCREEN_INTENT`, `RECEIVE_BOOT_COMPLETED`
  permissions; notification receivers; `showWhenLocked`/`turnScreenOn` on the
  main activity.
- `app/build.gradle.kts`: core library desugaring enabled (required by
  flutter_local_notifications), NDK 27 pinned.
- Exact alarms and full-screen intent permissions are requested at runtime and
  degrade gracefully when not granted.

### iOS (requires a Mac with Xcode for these optional steps)

- `Info.plist` already contains `NSLocationWhenInUseUsageDescription`.
- Notifications use the `timeSensitive` interruption level. To activate it,
  add the **Time Sensitive Notifications** capability in Xcode
  (Signing & Capabilities → + Capability). Without it, notifications are
  delivered at the default level — still functional.
- No CallKit usage: faking incoming calls would violate App Store policy, so
  iOS shows a time-sensitive local notification that opens the in-app
  call-style screen.

## Religious/UX guidelines enforced

- The reminder never uses "Call from Allah" or implies a literal phone call.
- The incoming screen always shows exactly two actions: **Answer** (green)
  and **Decline** (red), mirroring a real incoming call. This is the single,
  consistent experience for every user — there are no alternative modes.
- "Decline" is a label only; its behavior is the configured snooze, never a
  rejection. No guilt-tripping copy anywhere.
- Notification shade action buttons are "Pray Now" and "Decline".
- Decline snooze copy is "Your Salah Reminder — Return for [Prayer]." (or the
  generic "Your salah reminder." when the prayer window will have closed).
- Automatic missed-prayer follow-up copy is "You have not answered yet —
  [Prayer] time is still open.", only ever scheduled strictly before the next
  prayer enters.
- Answer records the intent to pray; completion is confirmed later via a
  gentle home-screen card ("Mark as Prayed"), never an immediate second
  interruption.
