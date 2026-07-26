# iOS Stress Test Report — Allah Invites You to Salah

**Audit date:** 2026-07-24 (America/New_York)  
**Fix-pass date:** 2026-07-25 (America/New_York) — see [§1a](#1a-fix-pass-update-2026-07-25)  
**Follow-up date:** 2026-07-25, later same day — see [§1b](#1b-follow-up-2026-07-25-android-verification--ios-release-gate--alarmkit-entitlement-correction)  
**Mac compile validation date:** 2026-07-25, later still (MacinCloud, Xcode 26) — see [§1c](#1c-mac-compile-validation-2026-07-25-macincloud--xcode-26--macos-sequoia-15737)  
**Host:** Windows 11 Pro (no Xcode, no iOS Simulator, no physical iPhone)  
**Flutter:** 3.44.7 stable / Dart 3.12.2  
**App version (Generated.xcconfig):** 1.0.3+4  
**Scope:** Existing Flutter app + AlarmKit integration — audit & testing only  
**Production code changed:** **Yes, as of the 2026-07-25 fix pass** — see §1a for the exact file list. (The original 2026-07-24 audit below made no production changes; it is kept verbatim as the historical baseline the fix pass responds to.)

> **Correction notice, read first:** every mention of "AlarmKit entitlement" below (§1, §1a, and the appendices/tables in §10–14) was written on the unverified assumption that AlarmKit requires a special Apple-granted entitlement, sourced from third-party blog posts rather than Apple's own documentation. **§1b below corrects this**: Apple's own AlarmKit docs describe setup as only `NSAlarmKitUsageDescription` + `requestAuthorization()`, with no entitlement mentioned anywhere. Whether an entitlement is required at all is now explicitly **unconfirmed**, not a known blocker — see `IOS_ALARMKIT_ENTITLEMENT.md` and §1b. Treat every older reference to "AlarmKit entitlement missing/not granted" in this document as shorthand for "AlarmKit's real-world authorization behavior has not been verified on a device yet," not as a confirmed Apple-approval gate.

---

## 1. Executive verdict (original 2026-07-24 audit — see §1a for current status)

### **Blocked from determination — Not release ready for iOS**

Windows unit tests cannot certify AlarmKit, lock-screen alerts, Answer from terminated state, signing, Archive, or physical-device behavior. Several **Critical / High** defects were identified by static analysis and by automated tests that encode production risk. Until Mac + physical iPhone + AlarmKit entitlement validation completes, **do not ship an iOS release claiming AlarmKit prayer alerts work**.

---

## 1a. Fix-pass update (2026-07-25)

**Verdict after this pass: Still blocked from determination — Not release ready for iOS.** Every Critical/High defect that is fixable in Dart/Swift-adjacent config from a Windows host has been fixed and covered by new tests (all green). What has **not** changed is the fundamental limitation of this host: **no Xcode, no Simulator, no physical iPhone**. No AlarmKit entitlement has been added (by design — see below, and see §1b for a correction to how that decision is framed), and nothing here constitutes Mac/Archive/TestFlight/device verification. Sections 10–14 below (Mac/Xcode tests, physical-device matrix, TestFlight, entitlement-dependent tests) are unchanged and still gate release.

### What was fixed, mapped to the original findings

| ID | Original finding | Resolution this pass | Verified by |
|----|-------------------|----------------------|-------------|
| C1 | AlarmKit entitlement missing | **Deliberately not added.** *(Corrected in §1b: it is not actually confirmed that AlarmKit requires an entitlement at all — Apple's own docs describe setup as only `NSAlarmKitUsageDescription` + `requestAuthorization()`. This row originally treated the entitlement requirement as settled fact, sourced from third-party blogs, not Apple. See `IOS_ALARMKIT_ENTITLEMENT.md` for the full evidence review and the on-device steps to actually resolve this.)* The local-notification fallback is fully functional regardless of how this resolves (see C2/C3 below), so the app builds/runs/reliably alerts on every iOS version either way. | Manual doc review; existing fallback tests |
| C2 | `schedulePrayerAlarm` had no try/catch; one native failure aborted the whole `rescheduleAll` batch | `IosAlarmKitService.schedulePrayerAlarm` now returns a typed `AlarmKitScheduleResult` (`scheduled` / `unavailable` / `notAuthorized` / `failed`) and never throws. `NotificationScheduler.schedulePrayerReminder` now returns `PrimaryReminderOutcome` instead of throwing; `PrayerSchedulerService.rescheduleAll` iterates every primary individually, catching and recording each failure without stopping the batch, and returns an aggregated `RescheduleReport` (AlarmKit count / notification count / failed prayers). | `test/scheduling_torture_test.dart`: *"one primary failing mid-batch does not abort the remaining prayers"*, *"partial AlarmKit failure cannot leave an enabled prayer without an alert…"* — both pass |
| C3 | No fallback when AlarmKit schedule failed — local notification was cancelled first, so a failure lost the reminder entirely | `IosHybridNotificationScheduler.schedulePrayerReminder` now **never cancels the existing local primary before AlarmKit has successfully scheduled**. On any non-`scheduled` `AlarmKitScheduleResult`, it schedules/keeps the local-notification fallback instead, and reports the real channel via `PrimaryReminderOutcome` (`alarmKit` / `notification` / `failed`). | `test/ios_hybrid_notification_scheduler_test.dart` — fallback-on-unavailable, fallback-on-unauthorized, fallback-on-native-error, and fallback-itself-fails groups all pass |
| C4 | Release build crashed via `StateError` if `PRIVACY_POLICY_URL` was unset | `AppConfig.validateForRelease()` no longer throws in any build mode; it logs via `debugPrint` and returns `bool`. `main.dart` records the same condition to the in-app `DiagnosticsLog` once `SharedPreferences` is available (visible from Settings), without blocking startup. `tool/check_release_config.dart` remains the pre-packaging gate that should catch this before it ever reaches a release build. | `test/app_config_test.dart` (valid / missing / empty / malformed / placeholder cases, plus "`validateForRelease` never throws") |
| C5 | AlarmKit / iOS builds Not Run on this host | **Unchanged — still true.** Nothing on a Windows host can compile against the Xcode 26 SDK or produce/verify an Archive. Not in scope for this fix pass; see §10. | `flutter doctor` (no Xcode) |
| H1 | Hybrid `pendingIds()` ignored AlarmKit primaries → reconciliation could wipe persisted AlarmKit-backed reminders | `IosHybridNotificationScheduler.pendingIds()` now unions local-notification IDs with the in-memory/tracked AlarmKit-backed IDs. `ScheduledReminder` gained an `alarmKitId` field (persisted in `toJson`/`fromJson`) and a new `restoreTrackedAlarmIds()` restores that tracking from persistence after a fresh scheduler instance is constructed (app restart / background isolate). | `test/ios_hybrid_notification_scheduler_test.dart` (`pendingIds` accuracy, cross-restart bookkeeping groups) |
| H2 | AlarmKit ID map was in-memory only — lost across process death | Same `alarmKitId` persistence + `restoreTrackedAlarmIds()` as H1 closes this: any code path that constructs a fresh hybrid scheduler (main isolate on launch, background notification-action isolate) restores tracking from the persisted reminder list before doing any cancellation/reconciliation. | Same tests as H1; also exercised via `decline_flow.dart`'s `performDecline`, which now calls `restoreTrackedAlarmIds` before reconciling |
| H3 | `AppController` cancelled via the raw `notificationService`, bypassing AlarmKit | `AppController.snooze()` now passes the hybrid `notificationScheduler` into `performDecline`; `performDecline` itself now accepts an optional `NotificationScheduler` used for **all** cancellation/reconciliation (defaulting to the plain service so Android/pre-AlarmKit iOS are unaffected). The background notification-action isolate (`notificationActionBackground` in `local_notification_service.dart`) now constructs the same hybrid scheduler main.dart uses before calling `performDecline`, so background Decline agrees with the foreground app about which channel owns each primary. | `test/ios_hybrid_notification_scheduler_test.dart`; `test/decline_flow_test.dart` (existing `planDecline` tests unaffected — pure logic untouched) |
| H4 | Native bookkeeping uses a UserDefaults array, not `AlarmManager.shared.alarms` | **Not in scope for this pass** (native Swift; no Mac to validate a change safely). Unchanged. | — |
| H5 | Fixed AlarmKit schedule vs zoned local notifications (DST/travel semantics) | **Not in scope for this pass** (would require native AlarmKit API changes only verifiable on a Mac). Unchanged. | — |
| H6 | No `PrivacyInfo.xcprivacy` | Added `ios/Runner/PrivacyInfo.xcprivacy`, declaring only what this app's own Swift code actually does: `NSPrivacyAccessedAPICategoryUserDefaults` / reason `CA92.1` for the AlarmKit Answer-bridge and alarm-ID tracking in `UserDefaults.standard`. No fabricated declarations (file-timestamp / disk-space / boot-time / keyboard APIs are not used anywhere in this target's own code and are deliberately omitted). Referenced in the Runner target's Resources build phase in `project.pbxproj`. | Manual audit of `AlarmKitPlugin.swift` / `AnswerPrayerAlarmIntent.swift`; XML well-formedness checked (cannot run `plutil`/Xcode's privacy-report tooling on Windows — recheck in Xcode's own privacy report on first Mac build) |
| H7 | `IPHONEOS_DEPLOYMENT_TARGET = 12.0` vs Time Sensitive (15+) / AlarmKit (26) | **Not in scope for this pass** (explicitly restricted: "do not update … deployment targets"). *(Later resolved in §1c: raised to 13.0 by explicit user decision, once Mac validation showed 12.0 no longer builds with current Flutter/CocoaPods anyway.)* | — |
| H8 | Polar high-latitude times could be unordered / cross incorrectly (Tromsø) | `PrayerTimeService` now validates every computed day's chronological sequence (`_isChronologicallyValid`, midnight-crossing aware). When direct computation for the requested day is invalid, it searches nearby days for the nearest one that *is* valid and re-stamps that day's time-of-day pattern onto the requested date ("Aqrab al-Ayyam" substitution) rather than just sorting mislabeled times. If no valid sequence can be found in the search window, it throws `PrayerCalculationException` instead of silently scheduling an incorrect alarm. Uses `adhan_dart`'s own supported `HighLatitudeRule` options — no invented math. | `test/prayer_calculation_stress_test.dart`: Tromsø summer/winter solstice (now chronologically valid, previously "KNOWN DEFECT"), Tromsø midnight-crossing Isha, every `HighLatitudeRuleOption` across both solstices, America/Detroit spring-forward/fall-back single days and full weeks, and every `CalculationMethodOption` × `AsrMethod` combination across Detroit/London/Makkah/Tromsø — all pass |
| H9 | Empty `RunnerTests` — zero native XCTest coverage | **Not in scope / cannot be executed on Windows.** No native Swift test coverage is claimed by this pass — see "Any failed or unexecuted tests" below. | — (requires Mac) |
| H10 | No custom prayer sounds bundled; AlarmKit always `.default` | **Not in scope for this pass** (Medium/product decision in the proposed-fixes doc, not part of the Critical/High list actioned here). Unchanged. | — |
| M10 | `dart format` reported 10 dirty files | All 10 files (plus the new test files added in this pass) now format clean. | `dart format --output=none --set-exit-if-changed .` → exit 0 |
| M11 | 2 `RadioListTile` deprecation infos | `settings_screen.dart`'s `_pickEnum` now wraps its `ListView` in a `RadioGroup<T>` ancestor (the current Flutter-recommended pattern) instead of passing `groupValue`/`onChanged` to each `RadioListTile`. Behavior is unchanged — same bottom sheet, same selection UX. | `flutter analyze` → 0 issues |

### Exact production files changed this pass

New files:
- `lib/services/ios_alarmkit_service.dart` — added the `AlarmKitClient` abstract interface (existing `IosAlarmKitService` now implements it); `schedulePrayerAlarm` returns `AlarmKitScheduleResult` instead of `void`/throwing.
- `lib/services/ios_hybrid_notification_scheduler.dart` — now depends on `AlarmKitClient` + `NotificationScheduler` interfaces (not concrete classes) for testability; fixed cancel-before-fallback ordering (C3); fixed `pendingIds()` (H1); added `restoreTrackedAlarmIds()` (H1/H2).
- `ios/Runner/PrivacyInfo.xcprivacy` — new privacy manifest (H6).
- `IOS_ALARMKIT_ENTITLEMENT.md` — new: exact provisioning steps for after Apple grants AlarmKit access (C1, documentation only).

Modified files:
- `lib/services/prayer_scheduler_service.dart` — `rescheduleAll` no longer aborts on a single primary failure; aggregates a `RescheduleReport` (C2).
- `lib/services/local_notification_service.dart` — `PrimaryReminderChannel` / `PrimaryReminderOutcome` types; `schedulePrayerReminder` returns an outcome instead of throwing; the background notification-action isolate now builds the same hybrid scheduler as the foreground app before calling `performDecline` (H3).
- `lib/services/decline_flow.dart` — `performDecline` accepts an optional hybrid `NotificationScheduler` used for all cancellation/reconciliation, and restores AlarmKit ID tracking before reconciling (H1/H2/H3).
- `lib/state/app_controller.dart` — `snooze()` passes the hybrid `notificationScheduler` into `performDecline` (H3).
- `lib/models/scheduled_reminder.dart` — added `alarmKitId` field + JSON (de)serialization (H1/H2).
- `lib/config/app_config.dart` — `validateForRelease()` never throws; returns `bool`; `isValidHttpsUrl` made public for direct testing (C4).
- `lib/main.dart` — captures `validateForRelease()`'s return value and records a `DiagnosticsLog` entry when invalid, after `SharedPreferences` is available (C4).
- `lib/services/prayer_time_service.dart` — added `PrayerCalculationException`, chronological-sequence validation, and the Aqrab al-Ayyam nearest-valid-day fallback for high-latitude computation (H8).
- `lib/screens/settings_screen.dart` — `_pickEnum`'s bottom sheet now uses `RadioGroup<T>` (M11).
- `ios/Runner/Runner.entitlements` — comment only, documents that the AlarmKit key is deliberately not added yet and points to `IOS_ALARMKIT_ENTITLEMENT.md`; **no entitlement key added, no signing behavior changed**.
- `ios/Runner.xcodeproj/project.pbxproj` — added `PrivacyInfo.xcprivacy` as a file reference and to the Runner target's Resources build phase only (H6). No build settings, deployment target, or signing configuration touched.
- `RELEASE_CHECKLIST.md` — added an AlarmKit-capability checklist item under iOS signing, pointing to `IOS_ALARMKIT_ENTITLEMENT.md`.

**Not touched this pass:** anything under `android/`, and every other iOS Swift file (`AppDelegate.swift`, `AlarmKitPlugin.swift`, `AnswerPrayerAlarmIntent.swift`, `AlarmKitBridgeKeys.swift`, `Info.plist`) — see "Android confirmation" below.

### Tests added / changed this pass

New test files:
- `test/ios_hybrid_notification_scheduler_test.dart` — `FakeAlarmKitClient` + `FakeLocalScheduler` drive the hybrid scheduler through: successful AlarmKit scheduling, fallback on AlarmKit unavailable/unauthorized/native-error, fallback-itself-fails, `pendingIds()` accuracy, `cancel()` routing, and cross-restart `restoreTrackedAlarmIds()` bookkeeping.
- `test/app_config_test.dart` — `isValidHttpsUrl`/`validateForRelease` against valid, missing, empty, malformed, `http://`, relative, and `example.com` placeholder URLs; asserts `validateForRelease()` never throws in any case.
- `test/ios_alarmkit_service_test.dart` — direct unit tests of the concrete `IosAlarmKitService` (not just the fake) covering every non-iOS platform-gated early-return branch: `isAvailable`, `authorizationStatus`, `isAuthorized`, `requestAuthorization`, `openSystemSettings`, `getPendingAnswer`, `clearPendingAnswer`, `pendingAlarmIds`, `ensureListening` idempotency, `schedulePrayerAlarm`'s `unavailable` outcome (with deterministic `alarmId` preserved), cancellation no-ops, `scheduleDebugAlarm`, and `AlarmKitScheduleResult.success` semantics.

Updated test files:
- `test/scheduling_torture_test.dart` — `TortureScheduler.schedulePrayerReminder` now returns `PrimaryReminderOutcome`; added *"one primary failing mid-batch does not abort the remaining prayers"* and *"partial AlarmKit failure cannot leave an enabled prayer without an alert…"*.
- `test/notification_budget_test.dart` — `FakeBudgetScheduler.schedulePrayerReminder` updated to the new `Future<PrimaryReminderOutcome>` return type (no behavioral change to the tests themselves).
- `test/platform_routing_contract_test.dart` — doc comment updated to reflect that the hybrid scheduler's AlarmKit routing is now directly testable with a fake (`AlarmKitClient`) rather than only mirrored in a contract table.
- `test/prayer_calculation_stress_test.dart` — removed the two "KNOWN DEFECT" Tromsø tests (now genuinely fixed, not just documented); added Tromsø summer/winter ordered-sequence tests, a dedicated midnight-crossing-Isha assertion, every `HighLatitudeRuleOption` across both solstices, America/Detroit spring-forward/fall-back (single days + full weeks), and the full `CalculationMethodOption` × `AsrMethod` matrix across Detroit/London/Makkah/Tromsø.

None of the pre-existing tests were weakened, skipped, or had their assertions loosened to make them pass.

### Before-and-after coverage (`flutter test --coverage`, same files)

| File | Before (2026-07-24) | After (2026-07-25) |
|------|---------------------|---------------------|
| `ios_hybrid_notification_scheduler.dart` | 0 / 27 — **0%** | 32 / 36 — **88.9%** |
| `ios_alarmkit_service.dart` | 16 / 77 — 20.8% | 51 / 83 — **61.4%** |
| `decline_flow.dart` | 27 / 63 — 42.9% | 27 / 65 — 41.5% (line count grew slightly with the new scheduler param; `performDecline`'s I/O body is still not directly unit-tested — see below) |
| `prayer_scheduler_service.dart` | 136 / 144 — 94.4% | 160 / 181 — 88.4% (denominator grew substantially with the new per-primary failure-handling / `RescheduleReport` code; absolute lines covered increased) |
| `prayer_time_service.dart` | 69 / 74 — 93.2% | 115 / 127 — 90.6% (denominator grew with the new exception/fallback logic; absolute lines covered increased) |
| `app_config.dart` | not previously tracked | 9 / 11 — **81.8%** (new) |
| `local_notification_service.dart` | 6 / 134 — 4.5% | 13 / 145 — 9.0% |

Full test count: **181 → 339** (all green). Remaining gaps are exactly where the earlier audit flagged them as requiring a Mac: the real `IosAlarmKitService` MethodChannel invoke branches (only reachable when `Platform.isIOS` is actually true), and the `flutter_local_notifications` plugin-channel call sites inside `LocalNotificationService`/`performDecline`'s I/O body — both are still 0%-reachable from a Windows unit test host by construction, not from a lack of effort this pass.

### Remaining Mac/Xcode/device blockers

Unchanged from the original audit (§10–§14) — none of this pass's changes reduce these requirements:
- No Xcode 26 SDK / Simulator / physical iPhone on this host — cannot compile against the SDK, run `flutter build ios`, Archive, or codesign-verify anything.
- Whether AlarmKit needs an entitlement at all is unconfirmed (see §1b) — none has been added. Every AlarmKit-authorized code path in this app is still **Not Run** in practice on this host; only its Dart-level routing/fallback logic is unit-tested via fakes.
- Native Swift (`AlarmKitPlugin.swift`, `AnswerPrayerAlarmIntent.swift`) has zero XCTest coverage and cannot be compiled or tested on Windows.
- Physical-device destruction matrix (§11), TestFlight tests (§12), and AlarmKit-entitlement-dependent tests (§13) are all still **Not Run**.

### Any failed or unexecuted tests

- **Failed tests: none.** `flutter test` and `flutter test --coverage` both report **339 / 339 passing**, exit code 0.
- **Unexecuted (structurally, not by omission):**
  - All native Swift / XCTest coverage (`ios/RunnerTests`) — requires a Mac; not claimed as covered by any Dart test in this pass.
  - The real `IosHybridNotificationScheduler` wired to the real `IosAlarmKitService` making an actual MethodChannel call — only the fake-backed logic and the concrete service's non-iOS early-return branches are exercised; the channel invoke code paths themselves need a device/Simulator.
  - `flutter build ios` / Archive / Simulator / physical-device / TestFlight flows — all blocked by the Windows host, exactly as before.

### Android confirmation

**No files under `android/` were read or modified during this fix pass**, and no Android-facing Dart behavior (Gradle-enforced release validation, notification scheduling on Android, exact-alarm handling) was changed — every production Dart change above is either iOS-only (`ios_alarmkit_service.dart`, `ios_hybrid_notification_scheduler.dart`) or platform-neutral code that Android already exercises through the plain `LocalNotificationService` path unaffected by the hybrid scheduler's existence (`decline_flow.dart`, `prayer_scheduler_service.dart`, `prayer_time_service.dart`, `app_config.dart`, `scheduled_reminder.dart`). `flutter analyze`/`flutter test` cover Android-shared code identically to before; nothing in this pass touched `AndroidManifest.xml`, Gradle files, or any `android/` Kotlin/Java source.

**Correction — this claim was verified empirically in §1b below** (not just reasoned about from an unchanged file list): a real Android release build was actually run, gated correctly, and produced a genuinely signed artifact.

---

## 1b. Follow-up (2026-07-25): Android verification, iOS release gate, AlarmKit entitlement correction

The user asked for three things after §1a: (1) actually run an Android release build and core scheduling tests rather than reasoning from "no `android/` files touched" alone, (2) make the privacy-URL gate hard-fail iOS packaging instead of only warning, and (3) verify — rather than assume — whether AlarmKit truly requires a separate entitlement before proceeding to Mac validation.

### 1. Android release build — actually run, not just inferred

Reasoning "no Android files changed" doesn't prove Android behavior is intact when shared Dart files did change. So the actual Gradle release pipeline was exercised on this Windows host (Android builds work on Windows, unlike iOS):

| Step | Command | Result |
|------|---------|--------|
| Gate fires on missing config | `flutter build appbundle --release` (no dart-defines) | **Failed correctly**, before packaging: `RELEASE CONFIGURATION INVALID — PRIVACY_POLICY_URL is missing / SUPPORT_EMAIL is missing or invalid` |
| Gate rejects placeholder | same, with `--dart-define=PRIVACY_POLICY_URL=https://example.com/privacy` | **Failed correctly**: `PRIVACY_POLICY_URL is not a valid production https URL` |
| Full release build with real config | same, with a valid production-shaped URL + email, and the real local upload keystore already present at `android/key.properties` | **Succeeded**: `app-release.aab` built (≈64.8 MiB) |
| Signature verification | `jarsigner -verify -verbose:summary app-release.aab` | **`jar verified`** — signed by the real upload key's self-signed cert (`CN=Allah Invites You to Salah, OU=Mobile, O=Salah Invite`), not a debug key; cert valid until 2053 |
| Core scheduling tests | `flutter test test/prayer_scheduler_service_test.dart test/scheduling_torture_test.dart test/notification_budget_test.dart test/decline_flow_test.dart test/prayer_time_service_test.dart test/prayer_calculation_stress_test.dart test/notification_id_test.dart test/prayer_response_test.dart test/settings_persistence_test.dart test/location_service_test.dart` | **252 / 252 passed** (subset of the full 339; these are exactly the shared-Dart-logic suites Android's `LocalNotificationService` path exercises) |

This is a real signed release artifact, not a simulated/dry-run claim. One incidental finding while doing this: **`android/key.properties` and `*.jks`/`*.keystore` were not excluded by the repository root `.gitignore`** (they were already covered by a separate `android/.gitignore`, and `git log` confirms the real keystore file was never committed — so there was no actual leak — but the root `.gitignore` was still missing this defense-in-depth entry). Added `/android/key.properties`, `*.jks`, `*.keystore` to the root `.gitignore` as a second layer.

### 2. iOS release-config gate strengthened from "warn" to "hard-fail packaging"

§1a's fix made `AppConfig.validateForRelease()` non-crashing at **runtime** (correct — a missing privacy URL should never crash a shipped app), but that alone doesn't stop a broken build from being packaged and uploaded. Android already had a hard packaging-time gate (`android/app/build.gradle.kts`, pre-existing). iOS did not — Xcode has no built-in dart-define hook, so `tool/check_release_config.dart` existed only as a script someone had to remember to run manually.

Fixed by adding a **Run Script build phase** to the Xcode project itself, so the gate cannot be skipped by forgetting a manual step:
- `ios/Runner.xcodeproj/project.pbxproj` — new `PBXShellScriptBuildPhase` named **"Check Release Configuration"**, inserted as the **first** build phase of the Runner target (runs before Flutter's own "Run Script"/"Thin Binary" phases).
- `ios/Runner/check_release_config.sh` — the actual logic: on `CONFIGURATION=Release` only (Debug/Profile are never blocked, matching Gradle's behavior), decodes the `DART_DEFINES` build setting (populated by Flutter into `Generated.xcconfig`, `#include`d by `Debug.xcconfig`/`Release.xcconfig`, and therefore a plain environment variable inside any Xcode build phase), and fails the build (`exit 1`, `error:`-prefixed output so Xcode surfaces it as a build error) if `PRIVACY_POLICY_URL`/`SUPPORT_EMAIL` are missing or invalid — same rules as the Dart/Gradle checks (https scheme, no `example.` placeholder host, email contains `@`).
- Because every iOS build path (`flutter build ios`, `flutter build ipa`, Xcode Run, and Archive) invokes `xcodebuild`, and `xcodebuild` runs every build phase, this phase executes on **all** of them — it is a real packaging-time gate, not a checklist item.

**Verification performed on this Windows host (logic only — the pbxproj edit itself has not been opened in Xcode yet):**
- `bash -n` syntax-checked the script (Git Bash for Windows) — clean.
- Ran it directly with `CONFIGURATION=Debug` → skips (exit 0), confirming Debug/Profile are never blocked.
- Ran it with `CONFIGURATION=Release` and no `DART_DEFINES` → fails with the expected message (exit 1).
- Ran it with `CONFIGURATION=Release` and a correctly base64-encoded, comma-joined `DART_DEFINES` (matching Flutter's actual `Generated.xcconfig` format, confirmed via Flutter/Stack Overflow source research) containing a valid production URL/email → passes (exit 0).
- Ran it with a placeholder `example.com` URL and an invalid email mixed into `DART_DEFINES` → fails, correctly reporting both problems.
- Ran it with an extra, unrelated dart-define mixed in alongside the two required ones → still passes, confirming the parser only inspects the two keys it cares about.
- `project.pbxproj` brace/parenthesis balance re-checked after the edit (81→82 matched braces, 56→59 matched parens, consistent with the objects added) and the new phase/file-reference blocks were re-read to confirm they follow the exact structure of the existing Flutter-authored phases byte-for-byte.

**What this does not and cannot verify from Windows:** whether Xcode actually accepts this hand-edited `pbxproj` without complaint, and whether `DART_DEFINES` is populated exactly the way research suggests on this specific Flutter/Xcode version pairing. **First action on the Mac must be: open `ios/Runner.xcworkspace`, confirm "Check Release Configuration" appears under Runner → Build Phases with no red/yellow warnings, then run the release-build sanity check now folded into `tool/ios_mac_validation.sh`** (attempts a release build with no dart-defines and asserts it fails with the expected message, before doing anything else).

`RELEASE_CHECKLIST.md` §1 was rewritten to describe both platforms' gates as automatic/enforced rather than "Android automatic, iOS manual."

### 3. AlarmKit entitlement claim corrected — it was not actually confirmed

The user specifically flagged this: *"verify whether a separate AlarmKit entitlement is actually required by your Xcode/account configuration... Apple's public setup documentation emphasizes `NSAlarmKitUsageDescription` and user authorization. Don't add an entitlement merely because Cursor expects one."* This was the right challenge — on inspection, §1a's C1 finding ("AlarmKit entitlement missing") and `IOS_ALARMKIT_ENTITLEMENT.md` had stated the entitlement requirement as settled fact, sourced from third-party blog posts, not from Apple.

Research done this pass (see `IOS_ALARMKIT_ENTITLEMENT.md`, fully rewritten):
- **Every official Apple source** (WWDC25 "Wake up to the AlarmKit API", `developer.apple.com/documentation/alarmkit`, the "Scheduling an alarm with AlarmKit" sample doc) describes AlarmKit setup as **only** `NSAlarmKitUsageDescription` in `Info.plist` + `AlarmManager.requestAuthorization()` / `authorizationState`. **No official Apple page mentions an entitlement for AlarmKit at all.**
- Two third-party blog posts (Medium, BleepingSwift) claim a special Apple-approved entitlement is required, citing `com.apple.AlarmKit.Alarm error 1` as evidence, and both repeat the same request URL (`developer.apple.com/contact/request/alarmkit`). Fetching that URL directly returns an **empty page**, unlike genuine capability-request docs (e.g. Apple's own "Requesting the Family Controls entitlement" page, which returns full content when fetched the same way).
- On Apple's own Developer Forums, one developer reports `requestAuthorization()` **working with no entitlement and no special setup** beyond the two official steps, while another hits `error 1` — the reply suggests an iOS-version difference (targeting 26.2+), not an approval gate. This is not conclusive proof either way, but it directly contradicts the blog posts' framing that `error 1` unconditionally means "entitlement not granted."

**Conclusion: whether an entitlement is required is unconfirmed, not a known blocker.** `IOS_ALARMKIT_ENTITLEMENT.md`, `Runner.entitlements`'s comment, `RELEASE_CHECKLIST.md`'s AlarmKit item, and `tool/ios_mac_validation.sh` were all rewritten to stop asserting this as fact and instead give a concrete, on-device way to resolve it: implement per Apple's official two-step setup (already done in this app), test on a real iOS 26+ device, and only if authorization genuinely fails with `error 1`, check Xcode's own **Signing & Capabilities → + Capability** list for an "AlarmKit" entry — if it doesn't appear there, no entitlement exists to request and the error has a different cause; if it does, follow Xcode's own guidance rather than a hand-typed key from a blog post. **No entitlement was added to `Runner.entitlements` — that part of the original decision was correct and unchanged; only the confident "it's definitely required and gated by Apple approval" framing was wrong and has been corrected.**

### Updated verdict

**Still not release-ready for iOS** — this was never in question; nothing in this follow-up changes the fundamental Windows-host limitation (no Xcode, no Simulator, no physical iPhone). What changed: Android is now empirically (not just inferentially) confirmed unaffected and release-buildable; the privacy-URL gate is now a real packaging-time block on iOS instead of a runtime warning; and the AlarmKit entitlement question is now accurately framed as **unresolved and to be determined on a Mac**, not as a known, named blocker with a defined resolution path that isn't actually corroborated by Apple.

### What could not be executed from this environment

The user's requested next steps — running `tool/ios_mac_validation.sh` for real, compiling Debug/Release in Xcode 26, building an Archive, testing on a physical iOS 26+ iPhone (locked/terminated/Silent/Focus/Answer/Dismiss/fallback), and uploading to TestFlight — **all require a Mac with Xcode and a physical iOS 26+ device, neither of which exists in this environment.** None of these were run, and none are claimed to have been run. `tool/ios_mac_validation.sh` was updated (new release-gate sanity check, corrected AlarmKit guidance) so it is ready to execute as soon as a Mac is available; it has not been executed.

---

## 1c. Mac compile validation (2026-07-25, MacinCloud — Xcode 26 / macOS Sequoia 15.7.3)

A rented Mac (MacinCloud managed server, macOS Sequoia 15.7.3) was used to actually run the compile-time checks that §1a/§1b could not. **This section only covers compilation and the release gate — it does NOT cover Archive/codesign, TestFlight, or physical-device AlarmKit behavior (Answer/Dismiss/lock-screen/terminated-state), which still require a provisioning profile and a physical iOS 26+ iPhone and were not attempted.**

### What was actually run and confirmed

1. **CocoaPods integration fixed.** `ios/Flutter/Debug.xcconfig` / `Release.xcconfig` were missing the `#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.{debug,release}.xcconfig"` line, which `flutter create`-generated iOS projects normally have. Without it, `pod install`'s settings never reach the Xcode build, causing plugin build failures. Added both lines (comment-only build-setting includes; no signing, capability, or deployment-target change).
2. **`AlarmKitPlugin.swift` targeted an iOS-26.1-only API on an iOS-26.0 minimum.** `AlarmPresentation.Alert.init(title:secondaryButton:secondaryButtonBehavior:)` (implicit system stop button) is only available starting iOS 26.1; building against the iOS 26.0 SDK floor failed with `'init(...)' is only available in iOS 26.1 or newer`. Fixed by switching to the iOS-26.0-compatible `init(title:stopButton:secondaryButton:secondaryButtonBehavior:)` overload with an explicit `Dismiss` `AlarmButton`, matching Apple's WWDC25 "Wake up to the AlarmKit API" sample exactly. No behavior change — same Answer/Dismiss buttons — just a wider SDK floor.
3. **`flutter build ios --debug --no-codesign`** — **succeeded** (`✓ Built build/ios/iphoneos/Runner.app`).
4. **`flutter build ios --profile --no-codesign`** — **succeeded** ("Xcode build done." in 12.6s).
5. **Release-gate negative test:** `flutter build ios --release --no-codesign` **with no `--dart-define`s** — **failed as designed**, with `error: RELEASE CONFIGURATION INVALID (build stopped before packaging): PRIVACY_POLICY_URL is missing or not a valid https URL … SUPPORT_EMAIL is missing or invalid`, sourced from the new `check_release_config.sh` Xcode Run Script phase (§1b item 2). This is the first real confirmation, on real Xcode, that the packaging-time gate actually fires and actually blocks the build (previously only reasoned about statically from Windows).
6. **Release-gate positive test:** `flutter build ios --release --no-codesign --dart-define=PRIVACY_POLICY_URL=https://… --dart-define=SUPPORT_EMAIL=support@…` — **succeeded** (`✓ Built build/ios/iphoneos/Runner.app (36.1MB)`, "Xcode build done." in 32.6s), confirming the gate does not falsely block a well-formed release configuration.

So: **Debug, Profile, and Release (gated) all now compile successfully against the real Xcode 26 / iOS 26 SDK**, including the AlarmKit plugin code, with the release build-time privacy gate proven to both block invalid config and allow valid config.

### Caveats / what this does NOT prove

- **No code signing was exercised** (`--no-codesign` was used throughout, since no provisioning profile/Apple Developer team is configured on this rented Mac). Archive, TestFlight upload, and any entitlement-driven signing behavior remain unverified.
- **No physical device or Simulator run.** AlarmKit's actual runtime behavior — authorization prompt, whether `AlarmManager.requestAuthorization()` succeeds without a special entitlement (the open question from `IOS_ALARMKIT_ENTITLEMENT.md`), lock-screen alert rendering, Answer/Dismiss from a terminated app, Silent/Focus-mode interruption — is **still completely unverified**. This section closes the "does it even compile against the real SDK" gap, nothing more.
- **`IPHONEOS_DEPLOYMENT_TARGET` raised from 12.0 to 13.0 — now committed.** This was first bumped experimentally only on the Mac clone to get `pod install` to resolve (current Flutter/plugin versions require ≥13.0). After confirming the compile results above, the user explicitly approved raising the floor for real (iOS 12 devices are effectively extinct in 2026), so `ios/Runner.xcodeproj/project.pbxproj` (all three build configs) and `ios/Flutter/AppFrameworkInfo.plist` were updated to `13.0` and committed. This supersedes the original "do not update deployment targets" restriction for this one setting, by explicit user decision, because the alternative (pinning old plugin versions indefinitely) was worse. Time Sensitive Notifications (15+) and AlarmKit (26+) both still degrade gracefully at runtime below their respective floors, unchanged.
- **`jarsigner`-style post-build artifact verification was not applicable here** (no signing); only build success/failure and the release-gate's stdout were checked.

### Updated verdict after §1c

**Still not release-ready for iOS** — Archive, TestFlight, and all physical-device AlarmKit behavior remain untested. What changed: the app (with every Critical/High Dart-side fix from §1a/§1b applied) is now confirmed to actually **compile** against Xcode 26 in Debug, Profile, and Release, and the release packaging gate is confirmed to work correctly in both directions on real tooling — closing the single largest "we can't even prove this compiles" risk called out in §1/§1a/§1b. The remaining gates (§10–14: Archive + codesign, physical-device destruction matrix, TestFlight, on-device AlarmKit authorization) are unchanged and still block a release claim.

---

## 2. Critical blockers

| ID | Finding | Owner | Evidence |
|----|---------|-------|----------|
| C1 | **AlarmKit entitlement missing** from `Runner.entitlements`. Only Time Sensitive Notifications is present. Without Apple-approved AlarmKit capability, `requestAuthorization` / schedule may fail (commonly AlarmKit error 1). | `ios/Runner/Runner.entitlements` | Static read; Apple AlarmKit docs / WWDC25 |
| C2 | **`schedulePrayerAlarm` has no try/catch** while cancel/auth swallow errors. A native schedule failure **aborts the entire `rescheduleAll` batch** mid-flight — remaining primaries, all follow-ups, and refresh never schedule. | `lib/services/ios_alarmkit_service.dart` (~121–138), `lib/services/prayer_scheduler_service.dart` (~272) | Automated test: `scheduling torture schedule failure midway aborts remaining primaries` **Passed** (documents the abort) |
| C3 | **No fallback when AlarmKit schedule fails** — hybrid cancels the local notification first, then calls AlarmKit. If AlarmKit throws after cancel, that primary is **lost** (neither AlarmKit nor notification). | `lib/services/ios_hybrid_notification_scheduler.dart` (~45–58) | Static inspection |
| C4 | **iOS release crash without dart-define** — `AppConfig.validateForRelease()` throws `StateError` in release if `PRIVACY_POLICY_URL` unset, before `runApp`. | `lib/config/app_config.dart`, `lib/main.dart` | Static inspection |
| C5 | **AlarmKit / iOS builds Not Run on this host** — cannot verify compile against Xcode 26 SDK, Archive, or device. | — | `flutter doctor`: no Xcode; `flutter build ios` unavailable on Windows |

---

## 3. High-risk failures

| ID | Finding | Owner | Severity |
|----|---------|-------|----------|
| H1 | **Hybrid `pendingIds()` ignores AlarmKit primaries** → reconciliation can treat primaries as stale and **wipe persistence** after Decline / budget admit on AlarmKit-authorized devices. | `ios_hybrid_notification_scheduler.dart`, `notification_reconciliation.dart`, `notification_budget.dart` | High |
| H2 | **`_alarmIdsByNotificationId` is in-memory only** — after process death, `cancel(id)` cannot map notification ID → AlarmKit UUID (relies on full `cancelAll` reschedule). | `ios_hybrid_notification_scheduler.dart` | High |
| H3 | **`AppController` cancels via raw `notificationService`**, bypassing hybrid — cannot cancel AlarmKit alarms on delivered-primary / follow-up cancel paths. | `lib/state/app_controller.dart` | High |
| H4 | **Native bookkeeping uses UserDefaults array**, not `AlarmManager.shared.alarms` — orphans possible; no reconcile mirror of notification path. | `AlarmKitPlugin.swift` | High |
| H5 | **Fixed AlarmKit schedule vs zoned local notifications** — different DST/travel semantics until next resume (no background refresh mode). | Hybrid + `AlarmKitPlugin` `.fixed(fireDate)` | High |
| H6 | **No app-level `PrivacyInfo.xcprivacy`** despite UserDefaults in AlarmKit bridge + location + network Quran APIs. | `ios/` | High (App Store) |
| H7 | **`IPHONEOS_DEPLOYMENT_TARGET = 12.0`** while Time Sensitive needs 15+ and AlarmKit needs 26 — runtime gating exists, but plugin mins may conflict; Archive risks. | `project.pbxproj` | High |
| H8 | **Polar high-latitude times can be unordered / cross-day** (Tromsø summer & winter Maghrib). | `prayer_time_service.dart` / adhan_dart | High for arctic users |
| H9 | **Empty `RunnerTests`** — zero native XCTest coverage of AlarmKit bridge. | `ios/RunnerTests/RunnerTests.swift` | High |
| H10 | **No custom prayer sounds in iOS bundle** — AlarmKit always `.default`; `preferredSoundName` never set; `validateSoundInBundle` dead from Dart. | Assets / hybrid | High vs product claim “selected prayer sound” |

---

## 4. Medium and low findings

### Medium
- M1: Duplicate Answer delivery path (stream + `getPendingAnswer` on resume); narrow race despite `incomingScreenOpen` guard. `clearPendingAnswer` before successful navigation can **lose** Answer if push fails. (`main.dart`, `app_controller.dart`)
- M2: `AlarmKitBridgeKeys.suiteHint` unused; no App Group — OK only while intent is in-process.
- M3: `pendingAnswerChanged` written, never read.
- M4: Channel round-trips: `isAvailable` + `isAuthorized` per primary, twice (hybrid + schedule) — noisy on launch.
- M5: Missing `ITSAppUsesNonExemptEncryption` → App Store Connect prompt every upload.
- M6: Missing `LSApplicationQueriesSchemes` while using `url_launcher`.
- M7: No `UIBackgroundModes` — cannot refresh schedules when app never opened (by design today; refresh notification depends on user opening).
- M8: iOS notification category labels Answer/Dismiss but Decline ID still snoozes — UX mismatch vs AlarmKit system Dismiss.
- M9: Incoming screen on iOS uses haptics only (`Vibration` Android-gated) — silent for background/locked (system alert must carry sound).
- M10: `dart format --set-exit-if-changed .` **Failed** (10 files would change) — hygiene.
- M11: `flutter analyze` exits 1 with 2 **info**-level RadioListTile deprecations in settings.

### Low
- L1: Dead Dart APIs: `validateSoundInBundle`, unused `pendingAlarmIds` callers.
- L2: Debug assert on notification cap can hard-crash Debug under stress (`prayer_scheduler_service.dart`).
- L3: Bundle ID casing `allahInvitesYouToSalah` vs Android `allah_invites_you_to_salah` — fine if intentional, easy to confuse in console.
- L4: No integration_test package / folder.
- L5: No IAP/premium — N/A (not a defect).

---

## 5. Architecture — iOS call flow

```
┌──────────────────────────────────────────────────────────────────────┐
│ LAUNCH                                                                │
│ main() → TimezoneService → AppConfig.validateForRelease()             │
│ → LocalNotificationService + (iOS) IosAlarmKitService                 │
│ → IosHybridNotificationScheduler wraps notifications                  │
│ → AppController + PrayerSchedulerService                              │
│ → runApp → controller.initialize() (async after first frame)          │
│ → getLaunchDetails / getPendingAnswer → IncomingSalahScreen           │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ PRAYER TIMES                                                          │
│ Settings (lat/lng/tz/method/asr/high-lat/offsets)                     │
│ → PrayerTimeService (adhan_dart) → PrayerDayTimes                     │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ RESCHEDULE (launch / resume / settings / midnight / location)         │
│ AppController.recalculateAndReschedule                                │
│ → PrayerSchedulerService.rescheduleAll                                │
│    → cancel orphans (notification pendingIds only)                    │
│    → IosHybrid.cancelAllAlarmKitAlarms (if hybrid)                    │
│    → cancel persisted (keep future snoozes)                           │
│    → schedule primaries → Hybrid: AlarmKit OR local notif             │
│    → follow-ups / refresh → always LocalNotificationService           │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ ALARMKIT (iOS 26+, authorized)                                        │
│ MethodChannel com.salahinvite.allah_invites_you_to_salah/alarmkit     │
│ → AlarmKitPlugin.schedulePrayerAlarm → AlarmManager.schedule          │
│ → Alert title "Allah Is Calling — {Prayer} Prayer"                    │
│ → Answer → AnswerPrayerAlarmIntent → UserDefaults pending             │
│ → NotificationCenter → onAlarmAnswered / getPendingAnswer             │
│ → presentIncomingScreen(prayer, scheduledAt, alarmId)                 │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ FALLBACK LOCAL NOTIFICATIONS (older iOS / denied / unavailable)       │
│ flutter_local_notifications · Darwin category salah_reminder_category │
│ Answer (pray_now) / Dismiss (decline→snooze) · timeSensitive          │
└──────────────────────────────────────────────────────────────────────┘
```

**Native components:** `AppDelegate`, `AlarmKitPlugin`, `AnswerPrayerAlarmIntent`, `AlarmKitBridgeKeys`  
**Flutter components:** `main`, `AppController`, `PrayerSchedulerService`, `IosHybridNotificationScheduler`, `IosAlarmKitService`, `LocalNotificationService`, `IncomingSalahScreen`, settings/location/timezone/Quran/Qibla screens

**Premium / StoreKit / deep URL schemes:** Not present.

---

## 6. Complete command log (Windows host)

### 2026-07-24 (original audit)

| Command | Exit | Result class |
|---------|------|--------------|
| `flutter doctor -v` | 0 | **Passed** (no Xcode; Android SDK 36 warning unrelated to iOS) |
| `flutter --version` | 0 | **Passed** — 3.44.7 / Dart 3.12.2 |
| `dart format --output=none --set-exit-if-changed .` | 1 | **Failed** — would reformat 10 files (tests/tools) |
| `flutter analyze` | 1 | **Failed** (exit≠0) — 0 errors, 2 info deprecations |
| `flutter test` | 0 | **Passed** — **181** tests |
| `flutter test --coverage` | 0 | **Passed** — lcov written; see §8 |
| `flutter build ios` | — | **Blocked by Windows** / **Requires Mac** |
| Integration tests | — | **Not Run** (no `integration_test/`) |
| XCTest / Swift Testing | — | **Requires Mac** |
| Device / TestFlight / AlarmKit live fire | — | **Requires physical iPhone** / **TestFlight** / **AlarmKit entitlement** |

### 2026-07-25 (after fix pass)

| Command | Exit | Result class |
|---------|------|--------------|
| `dart format --output=none --set-exit-if-changed .` | 0 | **Passed** — 0 files changed |
| `flutter analyze` | 0 | **Passed** — "No issues found!" |
| `flutter test` | 0 | **Passed** — **339** tests (up from 181) |
| `flutter test --coverage` | 0 | **Passed** — lcov written; see §8 for before/after |
| `flutter build ios` | — | **Still blocked by Windows** / **Requires Mac** (unchanged) |
| Integration tests | — | **Still Not Run** (unchanged) |
| XCTest / Swift Testing | — | **Still requires Mac** (unchanged) |
| Device / TestFlight / AlarmKit live fire | — | **Still requires physical iPhone / TestFlight / AlarmKit entitlement** (unchanged) |

Raw captures (workspace root, if retained): `stress_flutter_doctor.txt`, `stress_flutter_version.txt`, `stress_dart_format.txt`, `stress_flutter_analyze.txt`, `stress_flutter_test.txt`, `stress_flutter_coverage.txt`, `coverage/lcov.info`. The `stress_*` text files were overwritten in place with the 2026-07-25 results; the tables above capture the 2026-07-24 baseline for comparison.

### flutter --version (excerpt)
```
Flutter 3.44.7 • channel stable
Framework • revision 84fc5cbb22 • 2026-07-17
Dart 3.12.2 • DevTools 2.57.0
```

### flutter doctor (excerpt)
```
[√] Flutter (Channel stable, 3.44.7, on Microsoft Windows)
[!] Android toolchain (SDK 35; Flutter wants SDK 36)
[√] Chrome / Visual Studio / Connected device (Windows, Chrome, Edge)
[√] Network resources
! Doctor found issues in 1 category.
```
No Xcode / no iOS toolchain listed.

### dart format (2026-07-24, before the fix pass)
```
Changed test\decline_flow_test.dart
... (10 files)
Formatted 55 files (10 changed)
FORMAT_EXIT:1
```

### flutter analyze (2026-07-24, before the fix pass)
```
info - groupValue deprecated - settings_screen.dart:646
info - onChanged deprecated - settings_screen.dart:647
2 issues found. ANALYZE_EXIT:1
```

### flutter test (2026-07-24, before the fix pass)
```
00:04 +181: All tests passed!
TEST_EXIT:0
```

### dart format (2026-07-25, after the fix pass)
```
Formatted 63 files (0 changed) in 0.54 seconds.
FORMAT_EXIT:0
```

### flutter analyze (2026-07-25, after the fix pass)
```
Analyzing Allah Invites You to Salah...
No issues found! (ran in 5.4s)
ANALYZE_EXIT:0
```

### flutter test (2026-07-25, after the fix pass)
```
00:08 +339: All tests passed!
TEST_EXIT:0
```

---

## 7. Automated-test results

### Existing suite (2026-07-24 baseline)
Prior tests for scheduler, budget, decline, IDs, prayer times, location, settings, responses — all included in 181.

### Added for the 2026-07-24 audit (no production behavior change at that time)
| File | Purpose |
|------|---------|
| `test/alarmkit_answer_payload_test.dart` | Answer map parsing + stable UUID |
| `test/alarmkit_answer_routing_test.dart` | Payload edge cases + re-entrancy guard contract |
| `test/prayer_calculation_stress_test.dart` | Methods, madhhab, DST, cities, polar defects |
| `test/scheduling_torture_test.dart` | 100× reschedule, concurrent, DST, failure abort, etc. |
| `test/platform_routing_contract_test.dart` | AlarmKit decision table (logic mirror; hybrid Not Run on Windows) |

### 2026-07-24 findings that were **intentionally documented as failing/defective risks**, now fixed (see §1a)
- Mid-batch schedule failure aborted follow-ups (**C2**) — fixed; the "aborts remaining prayers" test was replaced with a "does NOT abort" test.
- AlarmKit-style primaries were absent from `pendingIds` (**H1** contract) — fixed; `IosHybridNotificationScheduler` is now directly unit-tested (previously only mirrored in a contract table since it couldn't run on Windows at all).
- Tromsø midsummer / winter pathological times (**H8**) — fixed; the two "KNOWN DEFECT" tests were removed and replaced with tests asserting correct, chronologically valid output.

### Added in the 2026-07-25 fix pass
| File | Purpose |
|------|---------|
| `test/ios_hybrid_notification_scheduler_test.dart` | Directly unit-tests `IosHybridNotificationScheduler` (previously untestable on Windows) via a fake `AlarmKitClient` — AlarmKit success, fallback on every failure mode, `pendingIds()`, cancellation routing, cross-restart bookkeeping |
| `test/app_config_test.dart` | `PRIVACY_POLICY_URL` validation: valid / missing / empty / malformed / placeholder; asserts `validateForRelease()` never throws |
| `test/ios_alarmkit_service_test.dart` | Direct tests of the concrete `IosAlarmKitService`'s non-iOS gated branches (the only branches reachable on this host) |

### Not covered by automation on Windows (unchanged after the fix pass — structural, not a gap in effort)
- The real `IosAlarmKitService` MethodChannel invoke branches (only reachable when `Platform.isIOS` is genuinely true)
- `flutter_local_notifications` plugin-channel call sites inside `LocalNotificationService`
- Native Swift / XCTest (`AlarmKitPlugin.swift`, `AnswerPrayerAlarmIntent.swift`)
- `IncomingSalahScreen` / `main` navigation
- Quran/Qibla UI, VoiceOver, performance

---

## 8. Code coverage summary

### 2026-07-24 (before the fix pass)

From `coverage/lcov.info` after `flutter test --coverage` (181 tests):

| File | Lines hit / total | % |
|------|-------------------|--|
| `ios_hybrid_notification_scheduler.dart` | 0 / 27 | **0%** |
| `local_notification_service.dart` | 6 / 134 | **4.5%** |
| `ios_alarmkit_service.dart` | 16 / 77 | **20.8%** |
| `decline_flow.dart` | 27 / 63 | 42.9% |
| `prayer_scheduler_service.dart` | 136 / 144 | 94.4% |
| `prayer_time_service.dart` | 69 / 74 | 93.2% |
| `notification_budget.dart` | 69 / 80 | 86.2% |

**Zero / absent from lcov (never imported by tests):**  
`main.dart`, `app_controller.dart`, `incoming_salah_screen.dart`, `settings_screen.dart`, all Quran/Qibla screens, **all Swift**.

**2026-07-24 verdict:** Critical iOS alert path has **weak or zero** coverage. Scheduler math is strong; platform bridge is not.

### 2026-07-25 (after the fix pass)

From `coverage/lcov.info` after `flutter test --coverage` (339 tests):

| File | Lines hit / total | % | Change |
|------|-------------------|---|--------|
| `ios_hybrid_notification_scheduler.dart` | 32 / 36 | **88.9%** | 0% → 88.9% |
| `ios_alarmkit_service.dart` | 51 / 83 | **61.4%** | 20.8% → 61.4% |
| `app_config.dart` | 9 / 11 | **81.8%** | new file coverage (not previously tracked) |
| `local_notification_service.dart` | 13 / 145 | 9.0% | 4.5% → 9.0% |
| `decline_flow.dart` | 27 / 65 | 41.5% | 42.9% → 41.5% (denominator grew with the new scheduler param; the async I/O body of `performDecline` itself remains untested — see below) |
| `prayer_scheduler_service.dart` | 160 / 181 | 88.4% | 94.4% → 88.4% (denominator grew ~26% with new failure-handling/report code; absolute covered lines rose 136→160) |
| `prayer_time_service.dart` | 115 / 127 | 90.6% | 93.2% → 90.6% (denominator grew with the new exception/fallback logic; absolute covered lines rose 69→115) |
| `notification_budget.dart` | 69 / 80 | 86.2% | unchanged |

Still zero / absent from lcov (unchanged — never imported by tests): `main.dart`, `app_controller.dart`, `incoming_salah_screen.dart`, `settings_screen.dart`, all Quran/Qibla screens, **all Swift**.

**2026-07-25 verdict:** The two files this pass specifically targeted for coverage (`ios_hybrid_notification_scheduler.dart`, `ios_alarmkit_service.dart`) improved substantially — the hybrid scheduler's routing/fallback logic, which was completely untested, now has the highest coverage of any AlarmKit-adjacent file. The remaining gaps in `ios_alarmkit_service.dart` (channel invoke branches), `local_notification_service.dart` (plugin-channel call sites), and `decline_flow.dart`'s `performDecline` I/O body are not from lack of effort — they require either a real iOS host (`Platform.isIOS == true`) or mocking the `flutter_local_notifications` MethodChannel end-to-end, which was judged out of scope for a pass focused on the AlarmKit handoff/persistence/privacy/high-latitude fixes rather than a broader notification-plugin test-infrastructure investment. `prayer_scheduler_service.dart` and `prayer_time_service.dart` show a *lower percentage* only because their denominators grew substantially with new, well-tested code (per-primary failure handling; high-latitude fallback) — their absolute covered-line counts both increased.

---

## 9. Static iOS audit

### Info.plist — Pass (keys present) / gaps
| Item | Status |
|------|--------|
| `NSLocationWhenInUseUsageDescription` | Present |
| `NSAlarmKitUsageDescription` | Present (exact required copy) |
| URL schemes | **Absent** |
| Background modes | **Absent** |
| `ITSAppUsesNonExemptEncryption` | **Absent** |
| `LSApplicationQueriesSchemes` | **Absent** |
| Privacy manifest | **Absent** (`*.xcprivacy` not found) |

### Runner.entitlements
| Item | Status |
|------|--------|
| Time Sensitive | Present |
| AlarmKit entitlement | **Absent** — Critical C1 |
| App Groups | Absent |

### project.pbxproj
| Item | Status |
|------|--------|
| AlarmKit Swift in Runner Sources | **Pass** (all three files) |
| `IPHONEOS_DEPLOYMENT_TARGET` | 12.0 at time of original audit; **raised to 13.0 in §1c** (2026-07-25) |
| Bundle ID | `com.salahinvite.allahInvitesYouToSalah` |
| `DEVELOPMENT_TEAM` | Not set in repo |
| Podfile | **None** (Flutter SwiftPM mode) |

### Swift static review (not a compile proof)
| Check | Result |
|-------|--------|
| Invented AlarmKit APIs | Uses documented `AlarmManager`, `Configuration.alarm`, `AlertConfiguration.AlertSound`, non-deprecated `Alert` init — **plausible**; **Requires Mac** to compile |
| `#if canImport(AlarmKit)` + `#available(iOS 26.0, *)` | Present |
| Forced unwraps `as!` / `try!` | **None found** |
| MainActor for FlutterResult | Used after async Task |
| MethodChannel type mismatches | `scheduledAtMs` as `NSNumber` — Dart int usually OK; verify on device |
| App Intent `openAppWhenRun` | true |
| UserDefaults suite | standard (no App Group) |
| Duplicate plugin registration | Single manual register in AppDelegate after GeneratedPluginRegistrant |
| Stable IDs | Minute-granularity UUID; tested in Dart |
| ms vs s | `scheduledAtMs / 1000.0` — correct if Dart sends ms |
| Errors swallowed | cancel `try?`; schedule path throws to Dart (**C2**) |
| Debug vs Release | Same sources; release blocked by AppConfig without dart-define |

### Podfile / CocoaPods
Not used in checked-in tree. Mac script handles optional `pod install` if Podfile appears after `flutter create` migration.

---

## 10. Mac / Xcode tests still required

Script: `tool/ios_mac_validation.sh`

Checklist (every item **Not Run** on this audit):

- [ ] Xcode 26 SDK installed  
- [ ] `flutter clean` / `pub get`  
- [ ] Open `ios/Runner.xcworkspace`  
- [ ] Debug / Profile / Release `flutter build ios --no-codesign`  
- [ ] Signed device build  
- [ ] Archive + Validate  
- [ ] XCTest for AlarmKitPlugin (write tests first — template empty)  
- [ ] Flutter integration_test on Simulator  
- [ ] Dump signed entitlements (`codesign -d --entitlements`)  
- [ ] Confirm Swift objects in Runner binary  
- [ ] Confirm **no** custom prayer sound files in bundle (expected today)  
- [ ] Categorize **every** Xcode warning as release-affecting or not  

---

## 11. Physical-device destruction matrix (Not Run)

Minimum matrix — mark Pass/Fail only after device runs:

| Device class | Min iOS | Pre-26 | iOS 26+ | Notes |
|--------------|---------|--------|---------|-------|
| Small screen (SE-class) | Not Run | Not Run | Not Run | |
| Dynamic Island | — | Not Run | Not Run | |

**States × alerts** (each cell Not Run): app open / background / terminated / force-quit / locked / other app / silent / Focus / Low Power / airplane / no net / weak net / reboot locked / reboot unlocked / notif denied / AlarmKit denied / revoked / location denied / auto time off / TZ change / language / Dynamic Type / dark / light.

**Per firing record:** scheduled vs actual time, delay, title, prayer name, sound, Silent/Focus breakthrough, buttons, Dismiss, Answer, destination screen, native alert stopped?, duplicate fallback?, console logs.

---

## 12. TestFlight tests still required

| Test | Status |
|------|--------|
| External/internal TestFlight install | Not Run |
| AlarmKit entitlement on distribution profile | Not Run |
| Answer from killed app via TestFlight build | Not Run |
| Background delivery overnight | Not Run |
| Crashlytics/console log review | Not Run |

---

## 13. AlarmKit entitlement-dependent tests

| Test | Status |
|------|--------|
| Authorization prompt shows usage string | Requires entitlement + iOS 26 |
| Alarm fires locked / Focus / Silent | Requires entitlement |
| Answer secondary intent opens app | Requires entitlement |
| Schedule without entitlement error handling / fallback | Requires device (expect fail → must not lose reminder — **C3**) |
| Settings → Open Settings when denied | Requires device |

---

## 14. Exact reproduction steps for every failure / blocker

### C2 / C3 — schedule failure loses reminders
1. On iOS 26 without AlarmKit entitlement (or mock native `schedule_failed`).  
2. Authorize AlarmKit if possible, or force hybrid AlarmKit path.  
3. Trigger reschedule (launch / recalculate).  
4. Observe: first N primaries may cancel local notifs; throw aborts batch; follow-ups missing.  
5. Automated proof on Windows: `flutter test test/scheduling_torture_test.dart --name "schedule failure midway"`.

### C1 — signing / auth
1. Archive without AlarmKit capability.  
2. Call Settings → Prayer alarms.  
3. Expect auth/schedule failure; confirm whether fallback still schedules notifications (**today: likely not if hybrid thought it was authorized then failed mid-batch**).

### C4 — release without privacy URL
1. `flutter build ios --release` without `--dart-define=PRIVACY_POLICY_URL=https://...`  
2. Launch → expect crash `StateError` from `AppConfig.validateForRelease`.

### H8 — Tromsø
1. `flutter test test/prayer_calculation_stress_test.dart --name "KNOWN DEFECT"`  
2. Or set location to Tromsø in app and inspect Maghrib/Fajr order midsummer.

### Format / analyze hygiene
1. `dart format --output=none --set-exit-if-changed .` → exit 1  
2. `flutter analyze` → exit 1 (infos)

---

## 15. Recommended fix order (original 2026-07-24 list — status updated 2026-07-25)

See also `IOS_PROPOSED_FIXES_FOR_APPROVAL.md`.

1. ~~**C3/C2:** Wrap AlarmKit schedule in try/catch; on failure, **restore local notification** for that primary; never abort whole batch.~~ **Done — see §1a.**
2. **C1:** ~~Apply for AlarmKit entitlement; add capability; verify signed entitlements.~~ **Corrected in §1b: do not apply for anything yet — it isn't confirmed one is needed.** First action on a Mac is to test real-device authorization behavior per Apple's official (entitlement-free) setup steps; only pursue a capability request if Xcode's own Signing & Capabilities panel actually lists an "AlarmKit" entry. See `IOS_ALARMKIT_ENTITLEMENT.md`.
3. ~~**H1/H2/H3:** Persist AlarmKit ID map; make `pendingIds` / cancel paths hybrid-aware; stop wiping primaries.~~ **Done — see §1a.**
4. ~~**C4:** Ensure CI/Xcode schemes always pass privacy dart-define.~~ **Done — see §1b: this is now a hard packaging-time gate on both platforms (Gradle for Android, a new Xcode Run Script build phase for iOS), not just a runtime warning or a manual script.**
5. ~~**H6:** Add `PrivacyInfo.xcprivacy`.~~ **Done — see §1a.**
6. **H10:** Bundle prayer sounds or drop product claim; wire `preferredSoundName`. **Not actioned — Medium/product scope, not part of the Critical/High list actioned this pass.**
7. **H7:** Raise deployment target to a supported floor (15+ or 26-aware). **Not actioned in §1a ("do not update … deployment targets"); later raised to 13.0 in §1c by explicit user decision** (forced by current Flutter/CocoaPods minimums, not fully to 15+/26 — Time Sensitive and AlarmKit still degrade gracefully below their own floors).
8. ~~**H8:** High-latitude UX guard / alternative rule messaging.~~ **Done differently — fixed the calculation itself (Aqrab al-Ayyam fallback + chronological validation) rather than just adding UX messaging around a known-bad result. See §1a.**
9. **H9:** Native XCTest for channel + intent payload. **Not actioned — requires a Mac; no native Swift test coverage is claimed.**
10. **M1:** Clear pending Answer only after successful navigation. **Not actioned — Medium scope, not part of the Critical/High list actioned this pass.**

---

## 16. Final checklist — Pass / Fail / Not Run

### Host / tooling — 2026-07-24 → 2026-07-25
| Test | 2026-07-24 | 2026-07-25 |
|------|------------|------------|
| flutter doctor | Pass (with Android note) | Pass (unchanged) |
| flutter --version | Pass | Pass (unchanged) |
| dart format check | Fail | **Pass** |
| flutter analyze | Fail (infos only) | **Pass** (0 issues) |
| flutter test | Pass (181) | **Pass (339)** |
| flutter test --coverage | Pass | **Pass** (see §8 for before/after) |
| integration_test | Not Run (missing) | Not Run (unchanged) |
| iOS compile / Archive | Blocked by Windows / Requires Mac | Unchanged — still requires Mac |
| Simulator | Requires Mac | Unchanged |
| Physical iPhone | Requires physical iPhone | Unchanged |
| TestFlight | Requires TestFlight | Unchanged |
| AlarmKit entitlement live | Requires AlarmKit entitlement | Unchanged — documented in `IOS_ALARMKIT_ENTITLEMENT.md`, not yet grantable |

### Features (Windows-automatable vs not)
| Feature | 2026-07-24 | 2026-07-25 |
|---------|------------|------------|
| Prayer calculation (methods, DST, cities) | Pass (unit) | Pass (unit) — expanded matrix |
| Polar Tromsø pathology | Pass as **known defect lock** | **Fixed** — Pass as correct behavior, not a defect lock |
| Scheduling torture / budget | Pass (unit) | Pass (unit) — added non-abort tests |
| Answer payload parsing | Pass (unit) | Pass (unit) |
| Platform routing contract | Pass (unit mirror only) | **Pass (directly unit-tested)** via fake `AlarmKitClient` |
| Real hybrid AlarmKit routing | Not Run (Platform.isIOS) | **Logic now unit-tested via fake**; real MethodChannel invoke still Not Run (requires Mac) |
| Local notification OS delivery | Not Run | Not Run (unchanged) |
| AlarmKit OS alert | Not Run | Not Run (unchanged) |
| Answer terminated/background/foreground | Not Run | Not Run (unchanged) |
| IncomingSalahScreen UX | Not Run | Not Run (unchanged) |
| Location / timezone on device | Not Run | Not Run (unchanged) |
| Quran / Qibla / audio | Not Run | Not Run (unchanged) |
| VoiceOver / Dynamic Type / RTL | Not Run | Not Run (unchanged) |
| Performance Profile/Release | Not Run | Not Run (unchanged) |
| IAP | N/A (none) | N/A (none) |
| Android unchanged | Pass | **Pass** — this fix pass touched zero files under `android/` (see §1a) |

### Config audit
| Item | 2026-07-24 | 2026-07-25 |
|------|------------|------------|
| Swift files in Runner target | Pass (pbxproj) | Pass (unchanged) |
| NSAlarmKitUsageDescription | Pass | Pass (unchanged) |
| AlarmKit entitlement in repo | Fail | **Deliberately still absent** — see C1 in §1a; documented, not a defect |
| Privacy manifest | Fail (missing) | **Pass** — `PrivacyInfo.xcprivacy` added |
| Deployment target 12 vs AlarmKit 26 | Fail / risk | **Resolved in §1c** — raised to 13.0 (committed); Time Sensitive (15+) and AlarmKit (26+) still degrade gracefully below their own floors |
| Sound assets | Fail vs "selected sound" claim | Unchanged (out of scope — Medium/product decision, not actioned) |

---

## 17. Harsh bottom line

**2026-07-24:** 181 green Windows unit tests did not mean the iOS app worked. The AlarmKit path was unproven on device, missing the entitlement, and had a schedule-failure mode that could delete primary reminders without fallback.

**2026-07-25, after this fix pass:** 339 green Windows unit tests **still** do not mean the iOS app works on a device — that has not changed and cannot change without a Mac. What *has* changed: the specific defect this report called out most sharply — **"a schedule-failure mode that can delete primary reminders without fallback"** — is fixed and covered by tests that fail if it regresses (`test/ios_hybrid_notification_scheduler_test.dart`, `test/scheduling_torture_test.dart`'s partial-failure tests). The hybrid persistence/cancellation gaps (H1–H3), the release-crash risk (C4), the missing privacy manifest (H6), and the high-latitude calculation defect (H8) are all fixed the same way — root-caused and tested, not just documented as known issues. No AlarmKit entitlement has been added — the local-notification fallback carries every prayer alert correctly regardless. **Ship iOS only after Mac Archive + the physical destruction matrix in §11 pass with recorded firing logs** — that gate is unchanged.

**2026-07-25, later same day (§1b):** Android was actually verified, not just inferred — a genuinely signed release `.aab` was built and `jarsigner`-verified, plus 252 core scheduling tests re-run in isolation. The privacy-URL gate is now a hard packaging-time failure on iOS too (a new Xcode Run Script build phase), not just a non-crashing runtime warning. And the AlarmKit entitlement claim in the original audit and in §1a's C1 finding was **corrected**: it was based on third-party blog posts, not Apple's own documentation, which describes AlarmKit setup as requiring only `NSAlarmKitUsageDescription` + `requestAuthorization()` with no entitlement mentioned anywhere. Whether an entitlement is needed at all is now honestly unresolved rather than asserted as a known blocker with a defined (but unconfirmed) resolution path — see `IOS_ALARMKIT_ENTITLEMENT.md`. None of the requested Mac-side work (Xcode 26 compile, Archive, physical-device matrix, TestFlight) could be executed from this Windows environment; `tool/ios_mac_validation.sh` is updated and ready for whenever a Mac is available, but has not been run.

**2026-07-25, later still (§1c, real Mac):** A rented Mac with Xcode 26 was used to close the biggest remaining unknown — whether any of this actually compiles against the real SDK. It does: Debug, Profile, and Release all build successfully, after two real (not hypothetical) issues surfaced and were fixed — a missing CocoaPods `xcconfig` include, and an AlarmKit API call that only exists on iOS 26.1+ being used on an iOS-26.0 floor. The release packaging gate from §1b was proven on real Xcode to both correctly block a build missing `PRIVACY_POLICY_URL`/`SUPPORT_EMAIL` and correctly allow one that has them. **This is still not a release clearance** — no code signing, no Archive, no physical device, no AlarmKit authorization/lock-screen/Answer/Dismiss behavior has been exercised. `IPHONEOS_DEPLOYMENT_TARGET` had to be raised from 12.0 to 13.0 for CocoaPods to resolve at all (current Flutter/plugin versions require ≥13.0); the user explicitly approved making this permanent, and it is now committed to `project.pbxproj` / `AppFrameworkInfo.plist`, superseding the original "do not touch deployment targets" restriction for this one setting. **Ship iOS only after Archive + codesign + the physical destruction matrix in §11 pass with recorded firing logs on a real iOS 26+ device** — that gate is unchanged and is the only thing left between here and a release claim.
