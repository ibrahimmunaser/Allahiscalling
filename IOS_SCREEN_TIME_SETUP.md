# iOS Screen Time ("App Guard") setup

This feature shields the apps a user picks for the 15 minutes after each
prayer, showing an Apple-rendered "Allah Is Calling" shield instead of the
app. It is built on Apple's FamilyControls / ManagedSettings / DeviceActivity
/ ManagedSettingsUI stack and is **additive** — it never touches the
existing AlarmKit prayer-time alert or the already-shipped Android App Guard.

It ships **disabled by default**. Nothing below is required for normal app
releases to keep working.

## Current status

- All Swift source for the 3 required extensions (DeviceActivityMonitor,
  ShieldConfiguration, ShieldAction) and the main-app bridge
  (`AppGuardManager.swift`) is written and sits in the repo under `ios/`.
- The 3 extension **Xcode targets are NOT yet added** to
  `Runner.xcodeproj`. `ios/scripts/setup_screen_time_targets.rb` adds them,
  but only runs when `ENABLE_SCREEN_TIME_EXTENSIONS=1` is set — until then
  it's a guaranteed no-op, so every ordinary `v*` release build is
  unaffected.
- `GuardShared.swift` and `AppGuardManager.swift` ARE already compiled into
  the main `Runner` target unconditionally. They're safe on their own: every
  FamilyControls/DeviceActivity call is guarded by `#if canImport(FamilyControls)`
  and `@available(iOS 16.0, *)`, and without the entitlement below they just
  report "unsupported" to Dart.

## Why this can't be fully automated from this repo

1. **Apple must approve a capability.** The `com.apple.developer.family-controls`
   distribution entitlement requires a manual request to Apple — there is no
   API for it. Request it at:
   https://developer.apple.com/contact/request/family-controls-distribution
   Apple's review can take anywhere from a few days to a few weeks.
2. **No local Mac/Xcode.** The project targets are added by a Ruby script
   using the `xcodeproj` gem, run on Codemagic's macOS CI — nothing here can
   be verified by compiling locally first.
3. **Provisioning profiles don't exist yet.** Each of the 3 extensions needs
   its own bundle ID + App Store provisioning profile, which can only be
   created after step 1 is approved (Apple won't let the entitlement attach
   to a profile before that).

## One-time steps, once Apple approves the entitlement

1. **App Store Connect / Developer Portal**
   - Confirm the `com.apple.developer.family-controls` entitlement is
     approved for this team (Certificates, Identifiers & Profiles →
     Identifiers → `com.salahinvite.allahInvitesYouToSalah` → Capabilities).
   - Register the App Group `group.com.salahinvite.allahInvitesYouToSalah`
     for the main app ID (Capabilities → App Groups).
   - The 3 extension bundle IDs
     (`com.salahinvite.allahInvitesYouToSalah.deviceactivitymonitor`,
     `...shieldconfiguration`, `...shieldaction`) get registered
     automatically by the `ios-create-profile` Codemagic workflow (step 3
     below) — no need to create them by hand first.

2. **Codemagic environment variable**
   - On both the `ios-create-profile` and `ios-release` workflows, add
     `ENABLE_SCREEN_TIME_EXTENSIONS=1`.

3. **Create the 3 new provisioning profiles**
   - Push a `profile-*` tag (or re-run `ios-create-profile` manually). With
     `ENABLE_SCREEN_TIME_EXTENSIONS=1` set, it now also creates/fetches
     profiles for the 3 extension bundle IDs, each registering the App
     Group + Family Controls capability for that bundle ID automatically
     (inherited from the main app's enabled capabilities on the portal —
     double check in the portal UI that each new identifier shows both
     capabilities enabled; if not, enable them by hand once).
   - In the Codemagic UI: Code signing → iOS provisioning profiles →
     Fetch profiles → select and save each of:
     - `salah_appstore_deviceactivitymonitor`
     - `salah_appstore_shieldconfiguration`
     - `salah_appstore_shieldaction`

4. **codemagic.yaml**
   - Uncomment/add the 3 new profile reference names to `ios-release`'s
     `ios_signing.provisioning_profiles` list (see the comment already left
     there).

5. **Push a `v*` tag.** `setup_screen_time_targets.rb` now actually adds the
   3 extension targets to `Runner.xcodeproj` at build time, they get signed
   with the profiles above, and the IPA ships with the real feature.
   **Expect a few failed Codemagic builds while the Xcode project wiring
   gets ironed out** — nothing here can be verified ahead of time without a
   Mac. Read the failing step's log; most likely issues are a missing/
   mismatched provisioning profile, a wrong `PRODUCT_BUNDLE_IDENTIFIER`, or
   a missing capability on one of the 3 new identifiers in the portal.

## Rolling back

Set `ENABLE_SCREEN_TIME_EXTENSIONS=0` (or remove the variable) on both
Codemagic workflows. The next build drops the 3 extensions entirely and
goes back to exactly today's behavior — nothing else changes.
