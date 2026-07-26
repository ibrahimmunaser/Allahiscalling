# Proposed iOS production fixes — pending approval

**Status:** NOT IMPLEMENTED  
**Source audit:** `IOS_STRESS_TEST_REPORT.md` (2026-07-24)  
**Rule:** Do not apply these changes until explicitly approved.

---

## Fix 1 — Critical: never lose a primary on AlarmKit failure

**Problem:** Hybrid cancels local notification, then schedules AlarmKit without try/catch; failure aborts `rescheduleAll`.

**Proposed change:**
- In `IosAlarmKitService.schedulePrayerAlarm`, catch `PlatformException` and rethrow a typed error **or** return `bool success`.
- In `IosHybridNotificationScheduler.schedulePrayerReminder`, on AlarmKit failure, schedule via `notifications.schedulePrayerReminder` (restore fallback).
- In `PrayerSchedulerService.rescheduleAll`, catch per-primary errors and continue the batch (log via `diagnostics_log`).

**Files:** `ios_alarmkit_service.dart`, `ios_hybrid_notification_scheduler.dart`, `prayer_scheduler_service.dart`

---

## Fix 2 — Critical: AlarmKit entitlement + signing

**Problem:** Entitlement absent; production alarms will not work.

**Proposed change:**
- Apply at https://developer.apple.com/contact/request/alarmkit  
- Add AlarmKit capability in Xcode; commit resulting entitlements key once Apple issues it.  
- Document provisioning profile requirements in RELEASE_CHECKLIST.

**Files:** `ios/Runner/Runner.entitlements`, Apple Developer portal

---

## Fix 3 — High: hybrid pendingIds / persistence wipe

**Problem:** AlarmKit primaries invisible to `pendingIds()` → reconciliation/budget can drop persisted primaries.

**Proposed change:**
- Persist `Map<notificationId, alarmKitUuid>` in SharedPreferences.  
- Hybrid `pendingIds()` should include tracked AlarmKit primary IDs (synthetic or queried).  
- Or exclude AlarmKit primaries from stale-in-persistence classification.

**Files:** `ios_hybrid_notification_scheduler.dart`, possibly `notification_reconciliation.dart`, `app_controller.dart` cancel paths

---

## Fix 4 — High: cancel paths must use hybrid scheduler

**Problem:** `notificationService.cancel` bypasses AlarmKit.

**Proposed change:** Inject `NotificationScheduler` (hybrid on iOS) into Decline / delivered-primary cancel, or expose `cancelPrimary(prayer, time)` on hybrid.

**Files:** `app_controller.dart`, `decline_flow.dart`, `main.dart` wiring

---

## Fix 5 — High: PrivacyInfo.xcprivacy

**Proposed change:** Add app privacy manifest declaring UserDefaults / file timestamps reasons and data types (location, not collected for tracking).

**Files:** new `ios/Runner/PrivacyInfo.xcprivacy`

---

## Fix 6 — High: privacy policy dart-define in iOS release schemes

**Proposed change:** Xcode scheme / CI always passes `PRIVACY_POLICY_URL`; fail Archive early via `tool/check_release_config.dart`.

---

## Fix 7 — Medium: Answer clear-after-navigate

**Proposed change:** Call `clearPendingAnswer` only after `IncomingSalahScreen` route successfully pushed.

**Files:** `lib/main.dart`

---

## Fix 8 — Medium/product: prayer sounds

**Proposed change:** Bundle caf/wav sounds in Runner, set `preferredSoundName`, call `validateSoundInBundle` before schedule; or update UX copy to “system alarm sound”.

---

## Fix 9 — Medium: deployment target

**Proposed change:** Raise `IPHONEOS_DEPLOYMENT_TARGET` to at least 15.0 (Time Sensitive) or document 12.0 with soft degradation; align plugin mins.

---

## Fix 10 — High-latitude UX

**Proposed change:** Detect pathological order (Maghrib before Dhuhr / cross-day) and show settings guidance / force a safer high-latitude rule.

**Files:** `prayer_time_service.dart`, settings UI

---

## Explicitly out of scope unless requested
- Redesign of IncomingSalahScreen  
- Android behavior changes  
- Adding Live Activities / Widget Extension  
- Quiet drive-by refactors
