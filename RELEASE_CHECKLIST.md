# Release Checklist — Allah Invites You to Salah

Nothing on this list is optional. Items marked **BLOCKER** will fail the
build or the store review until resolved.

---

## 1. Production configuration (BLOCKER — enforced at build time, on both platforms, automatically)

Validation happens **before packaging on both platforms, automatically —
this is not a manual step that can be skipped or forgotten**:

1. **Android**: `android/app/build.gradle.kts` decodes the `--dart-define`
   values and fails any `*Release`/`*Bundle` Gradle task at configuration
   time if `PRIVACY_POLICY_URL` or `SUPPORT_EMAIL` is missing or invalid, or
   if the applicationId is a `com.example` placeholder. **Verified
   2026-07-25**: a `flutter build appbundle --release` with no dart-defines
   fails immediately with `RELEASE CONFIGURATION INVALID`; with a valid
   `PRIVACY_POLICY_URL`/`SUPPORT_EMAIL` and the real upload keystore
   configured, it builds and signs a genuine release `.aab` (confirmed with
   `jarsigner -verify`).
2. **iOS**: Xcode has no built-in dart-define hook, so a Run Script build
   phase named **"Check Release Configuration"** was added to the Runner
   target (`ios/Runner.xcodeproj/project.pbxproj`, script body in
   `ios/Runner/check_release_config.sh`) — it is the **first** build phase,
   runs on every `xcodebuild` invocation (`flutter build ios`,
   `flutter build ipa`, Xcode's own Build/Run, and Archive all go through
   `xcodebuild`), decodes Flutter's `DART_DEFINES` build setting, and fails
   the build with a real Xcode build error if `PRIVACY_POLICY_URL` /
   `SUPPORT_EMAIL` are missing or invalid **on Release configuration only**
   (Debug/Profile are never blocked, matching the Android gate). This has
   been logic-tested with Git Bash on Windows (missing / placeholder /
   valid / mixed-defines cases) but the pbxproj edit itself has **not** been
   opened in Xcode yet — verify on first Mac open that the "Check Release
   Configuration" phase appears under Runner → Build Phases with no errors.
3. **CI**, if/when configured, should additionally run
   `dart run tool/check_release_config.dart` (reads env vars or
   `--privacy-policy-url=... --support-email=...` args, exits non-zero when
   invalid) as an early, fast-fail step before invoking either platform's
   build — this is a convenience/fail-fast layer on top of #1/#2, not a
   replacement for them.

The in-app startup check (`lib/config/app_config.dart`) remains only as a
tertiary safeguard for any build that somehow slipped past both of the
above; debug builds show a visible dev warning instead of failing.

### Exact production build commands

```
:: Android (App Bundle for Play Store)
dart run tool/check_release_config.dart --privacy-policy-url=https://yourdomain.com/privacy --support-email=support@yourdomain.com
flutter build appbundle ^
  --dart-define=PRIVACY_POLICY_URL=https://yourdomain.com/privacy ^
  --dart-define=SUPPORT_EMAIL=support@yourdomain.com ^
  --dart-define=WEBSITE_URL=https://yourdomain.com

:: iOS (App Store / TestFlight)
dart run tool/check_release_config.dart --privacy-policy-url=https://yourdomain.com/privacy --support-email=support@yourdomain.com
flutter build ipa ^
  --dart-define=PRIVACY_POLICY_URL=https://yourdomain.com/privacy ^
  --dart-define=SUPPORT_EMAIL=support@yourdomain.com ^
  --dart-define=WEBSITE_URL=https://yourdomain.com
```

- [ ] Privacy policy written, reviewed, and hosted (HTTPS, not example.com)
- [ ] `PRIVACY_POLICY_URL` and `SUPPORT_EMAIL` passed via `--dart-define` in
      every release build (Gradle enforces this on Android)
- [ ] CI runs `dart run tool/check_release_config.dart` before every
      release/ipa build
- [ ] Support email configured and monitored
- [ ] The same privacy policy URL entered in Play Console and App Store Connect

## 2. Android signing (BLOCKER)

Release builds fail with `RELEASE SIGNING NOT CONFIGURED` until a real
upload keystore is provided. Debug keys are never used for release.

1. Create the upload keystore (once, store it somewhere safe and backed up):

   ```
   keytool -genkey -v -keystore %USERPROFILE%\upload-keystore.jks ^
     -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```

2. Copy `android/key.properties.example` to `android/key.properties` and
   fill in the paths/passwords. Alternatively set `ANDROID_KEYSTORE_PATH`,
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
   `ANDROID_KEY_PASSWORD` environment variables (CI).

3. Verify `key.properties` and `*.jks` are **not** tracked by git
   (both are gitignored).

- [ ] Upload keystore created and backed up offline
- [ ] `android/key.properties` configured locally / env vars configured in CI
- [ ] `flutter build appbundle` succeeds and is signed with the upload key
- [ ] Keystore and passwords are NOT in git history

## 3. Play Console

### Exact alarm declaration

The app requests `SCHEDULE_EXACT_ALARM` (Android 12–13, revocable) and
`USE_EXACT_ALARM` (Android 14+). Precise timing is core functionality:
a prayer reminder that arrives 15 minutes late has failed its purpose —
the entire product is the moment a prayer *enters*. This is the argument
to make in the declaration. **Approval is not guaranteed**; if Google
rejects `USE_EXACT_ALARM`, remove it and rely on `SCHEDULE_EXACT_ALARM`
plus the in-app "Alarms & reminders" prompt. The app already detects
unavailable exact alarms and falls back to inexact scheduling (with an
honest notice in Settings).

- [ ] Complete the "Exact alarms" declaration in Play Console policy section
- [ ] Data safety form: no data collected, no data shared, location processed
      on-device only
- [ ] Full-screen intent: declare use for prayer-time reminders (alarm-like)
- [ ] Content rating questionnaire
- [ ] Store listing (screenshots, descriptions) contains no claims of
      guaranteed delivery on all devices
- [ ] Internal testing track pass on at least one physical device
      (notifications, reboot, Doze)

## 4. iOS signing & distribution (BLOCKER until physical-device pass)

iOS has NOT been verified on a physical device. Simulators cannot validate
notifications, Time Sensitive delivery, or restart behavior. Do not ship
iOS until every item in `IOS_REAL_DEVICE_TESTING.md` passes.

- [ ] Apple Developer Program membership active
- [ ] Bundle identifier registered (`com.salahinvite.allahInvitesYouToSalah`
      — change if the final identifier differs)
- [ ] In Xcode (`ios/Runner.xcworkspace`) → Runner → Signing & Capabilities:
  - [ ] Development team selected
  - [ ] **Time Sensitive Notifications** capability shown (backed by
        `ios/Runner/Runner.entitlements`)
  - [ ] Provisioning profile supports the capability (no signing warnings)
  - [ ] **AlarmKit** — no entitlement has been added, because it is not
        actually confirmed that one is required (Apple's own AlarmKit docs
        describe setup as only `NSAlarmKitUsageDescription` +
        `requestAuthorization()` — see `IOS_ALARMKIT_ENTITLEMENT.md` for the
        full evidence review). On first Mac build: run the app on a real
        iOS 26+ device and check whether authorization/scheduling actually
        works. Only if it fails with `error 1`, check Xcode's **+ Capability**
        list for an "AlarmKit" entry — if present, follow Xcode's own
        guidance (it writes the entitlement key itself); if absent, the
        error has a different cause. Do not hand-add a guessed entitlement
        key. The app already runs correctly on every iOS
        version via the local-notification fallback without this.
- [ ] App Store provisioning profile / automatic signing for Release
- [ ] `flutter build ipa` succeeds
- [ ] TestFlight build uploaded and installed on a physical iPhone
- [ ] Full `IOS_REAL_DEVICE_TESTING.md` checklist passed on that device

## 5. Functional release gate

- [ ] `flutter analyze` clean
- [ ] `flutter test` fully green
- [ ] Full `ANDROID_REAL_DEVICE_TESTING.md` matrix passed (includes the
      force-stop caveat: Android cancels all alarms for force-stopped apps
      until the user reopens them — an OS rule, not a bug)
- [ ] `BETA_TEST_PLAN.md` executed (20–50 testers, two weeks)
- [ ] Android physical device: reminder fires when app is terminated
- [ ] Android physical device: reminder fires after reboot
- [ ] Decline from the notification shade schedules exactly ONE snooze and
      cancels the follow-up (no double reminder)
- [ ] Prayer times sanity-checked against a trusted source for at least two
      cities (e.g. Detroit/ISNA, Istanbul/Diyanet)
- [ ] Disclaimer "Prayer times are estimates…" visible in the app

## 6. Known deferrals (tracked, not blockers)

- Background refresh tasks (WorkManager / BGTaskScheduler) as a best-effort
  supplement to the reschedule-on-open strategy. The current design never
  relies on background execution: the schedule always covers the maximum
  safe horizon, and a safety notification asks the user to open the app
  before the window runs out.
- Dark/light theme toggle, iPad layout optimization, localization, custom
  adhan audio.
