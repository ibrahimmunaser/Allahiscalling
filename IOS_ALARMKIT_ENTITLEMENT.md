# AlarmKit entitlement — verify before assuming one is needed

**Correction (2026-07-25):** An earlier version of this document asserted, as
fact, that AlarmKit requires a special Apple-granted entitlement (like
CallKit or Family Controls) and gave a specific request URL. That claim was
sourced from third-party blog posts, not from Apple's own documentation, and
should not have been stated as settled fact. This version corrects that.

## What Apple's own documentation actually says

Every **official** Apple source for AlarmKit (WWDC25 "Wake up to the
AlarmKit API", the `developer.apple.com/documentation/alarmkit` reference,
and the "Scheduling an alarm with AlarmKit" sample project doc) describes
setup as exactly two steps, with no mention of a special entitlement
anywhere:

1. Add `NSAlarmKitUsageDescription` to `Info.plist` with a string explaining
   why the app schedules alarms. *"If the `NSAlarmKitUsageDescription` key is
   missing or its value is an empty string, apps can't schedule alarms with
   AlarmKit."* (already present in this app's `Info.plist`.)
2. Call `AlarmManager.shared.requestAuthorization()` (or let AlarmKit
   auto-request on the first `schedule(id:configuration:)` call), then branch
   on `AlarmManager.AuthorizationState` (`.notDetermined` / `.authorized` /
   `.denied`).

This app's Swift bridge (`AlarmKitPlugin.swift`) already implements exactly
this two-step setup and nothing more — see `ios/Runner/Info.plist`'s
`NSAlarmKitUsageDescription` key and the plugin's `requestAuthorization`
handler.

## What third-party sources claim, and why it's not being taken at face value

Several third-party blog posts (not Apple documentation) claim AlarmKit
additionally requires an Apple-approved entitlement — similar to CallKit or
the legacy Critical Alerts entitlement — and that without it,
`requestAuthorization()` throws `com.apple.AlarmKit.Alarm error 1`. One
specific request URL (`developer.apple.com/contact/request/alarmkit`) is
repeated across these posts, but fetching it directly returns an empty page
(unlike genuine capability-request docs such as Apple's own "Requesting the
Family Controls entitlement" page, which returns full content), and no
official Apple page enumerates an AlarmKit entitlement key.

Meanwhile, on Apple's own Developer Forums, at least one developer reports
`requestAuthorization()` "working fine" with no entitlement and no special
setup beyond the two official steps above, while another hits `error 1` —
which reads as more consistent with an OS-version or setup difference (one
reply suggests targeting iOS 26.2+ specifically) than with a hard-gated,
Apple-approved-only capability. **This is not conclusive either way** — it's
exactly why this app does not add a speculative entitlement key on the
strength of blog posts alone.

## Why nothing has been added to `Runner.entitlements`

Given the above, adding an entitlement key would mean guessing:
- Whether AlarmKit actually gates on a real entitlement at all (unconfirmed
  by Apple's own docs).
- The exact entitlement key name, if one exists (no official source states
  one; the only value in circulation is second-hand from blog posts, not
  from Apple).

Adding a **wrong or unsupported entitlement key** can break code signing for
the *entire app*, not just AlarmKit — a strictly worse outcome than AlarmKit
alarms simply not firing yet. This app's design already tolerates AlarmKit
being completely unavailable on any given install: `IosHybridNotification
Scheduler` falls back to local notifications on `isAvailable() == false`,
`isAuthorized == false`, or any native scheduling error, so **prayer alerts
are never lost regardless of how this question resolves** (see
`IOS_STRESS_TEST_REPORT.md` §1a, fixes C2/C3).

## How to actually resolve this, on a Mac, before assuming anything

1. Build and run the app as-is (already has `NSAlarmKitUsageDescription` +
   `requestAuthorization()`) on a physical device running a real iOS 26+
   build — not the Simulator, which has historically had gaps for
   entitlement-gated frameworks.
2. Call the debug "Answer" / AlarmKit test action already wired into
   Settings → Diagnostics and watch `AlarmManager.authorizationState` /
   the result of `requestAuthorization()`.
   - If it returns `.authorized` (or `.denied` from a real user choice) and
     alarms actually fire: **no entitlement is needed**, full stop — update
     this document to say so and remove the uncertainty above.
   - If it throws `error 1` specifically: open Xcode → Runner target →
     **Signing & Capabilities** → **+ Capability** and search for
     "AlarmKit".
     - If **no such capability appears in the list at all**, it is not a
       requestable managed capability the way Family Controls/CallKit are —
       the error has a different cause (iOS version, provisioning profile
       regeneration, a stale simulator/device cache, or an Xcode/SDK bug).
       Investigate those instead of assuming an entitlement is missing.
     - If it **does** appear in the capability list, that is the
       authoritative confirmation this document needs. At that point:
       add the capability in Xcode (Xcode will write whatever entitlement
       key it actually requires — don't hand-type one), check whether it
       shows as immediately available or as "request access" (some
       capabilities are self-service, others require Apple approval first),
       and follow whatever Xcode's own UI says from there.
3. Only after step 2 gives a real answer, update this document, `Runner.
   entitlements`, and `RELEASE_CHECKLIST.md` to match reality instead of a
   blog post.

## What NOT to do

- Do not hand-write an entitlement key into `Runner.entitlements` by
  copying one from a blog post — it is not corroborated by Apple's own
  documentation and, if wrong, can break signing for the whole app.
- Do not disable code-signing validation or switch to a wildcard/ad-hoc
  profile to "get past" a signing mismatch — that hides the real problem
  instead of resolving the question above.
- Do not conclude an entitlement is required purely because `error 1`
  occurred once — first rule out iOS version, device vs. Simulator, and
  Info.plist/provisioning-profile regeneration, per step 2 above.
