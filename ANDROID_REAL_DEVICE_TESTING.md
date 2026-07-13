# Android Real-Device Testing Checklist

Run this matrix before any release. Emulators are useful for smoke tests
but do NOT validate OEM battery managers, Doze behavior, vibration
hardware, or full-screen intent policy — those require physical devices.

## Device matrix (minimum)

| Device | Why |
| --- | --- |
| Google Pixel (stock Android, latest OS) | Reference behavior, Android 14+ FSI policy |
| Samsung Galaxy (One UI) | Most common OEM; aggressive "sleeping apps" battery manager |
| Xiaomi / Redmi (MIUI/HyperOS), if available | Most aggressive autostart/battery restrictions in the field |
| OnePlus or Oppo (ColorOS), if available | Known alarm-killing battery optimization |

Run the full scenario list on Pixel and Samsung at minimum; on
Xiaomi/OnePlus prioritize the background, reboot, Doze, and battery
scenarios.

## IMPORTANT: force-stop caveat (document for testers and support)

When the user **force-stops** the app (Settings > Apps > Force stop — and
on some OEMs, aggressive battery managers or swiping away in a task-killer
mode do the same), Android puts the app in the *stopped state*:

- ALL scheduled alarms and notifications are cancelled by the OS.
- Notification action buttons stop working.
- Nothing can run again until the user **manually opens the app**.

This is an OS rule that applies to every alarm app; it cannot be worked
around. Expected result in testing: after force-stop, no reminders fire
until the app is reopened, and reopening reschedules everything (verify on
the debug screen). Beta communications and the store listing must not
promise delivery through force-stop.

## Scenarios

Delivery states:

- [ ] Foreground: reminder fires at prayer time while the app is open
- [ ] Background: home-button the app; reminder fires on time
- [ ] App swiped away from recents (normal swipe, not force-stop):
      reminder still fires; Decline action still works (background isolate)
- [ ] Reboot: reminder fires after restart without opening the app
- [ ] Doze: `adb shell dumpsys deviceidle force-idle`, wait for a prayer
      time; reminder arrives on time (exact alarm)
- [ ] Battery-restricted mode: set the app to "Restricted" battery, verify
      delivery, then verify the in-app OEM battery guidance appears
- [ ] Force-stopped: per the caveat above, verify reminders resume after
      the app is manually reopened and rescheduled

Time and location:

- [ ] Timezone change: change device timezone; app reschedules on next open
      and shows correct wall-clock times
- [ ] DST change: set the date near a transition (or use a timezone
      currently transitioning); times remain correct across the boundary
- [ ] Travel/location change: select a city > 10 km away (or move);
      recalculation and rescheduling happen; debug screen confirms

Permission denial paths:

- [ ] Exact alarm denied (Android 12–13: revoke "Alarms & reminders"):
      reminders still arrive via inexact scheduling; Settings shows the
      honest "timing is approximate" notice
- [ ] Full-screen intent denied (Android 14+): notification still arrives
      as a normal heads-up notification; tapping it opens the incoming
      salah screen

Actions (each must behave identically in foreground, background, and
swiped-away states):

- [ ] Answer from the notification ("Pray Now"): answered recorded, NO
      immediate completion dialog, follow-up cancelled, gentle completion
      card appears on the home screen later
- [ ] Decline from the notification: exactly ONE snooze after the
      configured minutes; the automatic follow-up does NOT also fire
- [ ] Answer from the full-screen UI: same as above
- [ ] Decline from the full-screen UI: same as above, with confirmation
      snackbar
- [ ] Backing out of the full-screen UI without choosing: recorded as
      dismissed, NO snooze scheduled, the unanswered follow-up still fires
- [ ] Duplicate-action callback: press Decline twice rapidly / re-deliver
      the action; still exactly one snooze (idempotent)

Ringing and cleanup:

- [ ] Ringing vibration stops IMMEDIATELY on Answer
- [ ] Ringing vibration stops IMMEDIATELY on Decline
- [ ] Ringing stops when the screen is backed out of
- [ ] Ringing stops when the app is interrupted (incoming phone call, task
      switch, screen lock) while the reminder screen is up
- [ ] Animations freeze the moment a choice is made (no lingering pulse)

Longevity:

- [ ] Leave the device untouched (app unopened) for 7+ days: reminders
      continue for the whole scheduled window, then the "Open the app to
      refresh salah reminders" safety notification arrives
- [ ] Reopening at any point restores full coverage (debug screen: days of
      primary coverage back to ~7)

Diagnostics:

- [ ] Settings > Diagnostics (beta) generates a report, Copy works, and the
      report contains no coordinates, prayer history, or personal data
