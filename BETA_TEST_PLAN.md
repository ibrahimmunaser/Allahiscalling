# Beta Test Plan — Allah Invites You to Salah

## Goal

Prove, on real devices and real schedules, that prayer reminders are
delivered on time, exactly once, for at least two weeks without the user
babysitting the app.

## Cohort

- 20–50 testers.
- Recruit across the Android device matrix (Pixel/stock, Samsung, Xiaomi,
  OnePlus/Oppo) and, when TestFlight is ready, iPhone (iOS 15+).
- Include at least a few testers in different timezones and calculation-
  method regions (North America/ISNA, Turkey/Diyanet, Southeast
  Asia/JAKIM-MUIS-Kemenag), and at least one tester who travels during the
  test window.

## Duration

Two weeks minimum per build. The scheduling window is ~7 days, so two weeks
exercises the rolling-refresh path and the safety notification at least
once for infrequent users.

## Distribution

- Android: Play Console internal/closed testing track.
- iOS: TestFlight (only after `IOS_REAL_DEVICE_TESTING.md` passes on a
  physical iPhone).

## What testers report

Ask every tester to report, with the in-app diagnostics attached
(Settings > Diagnostics (beta) > Copy report):

1. **Missed reminder** — prayer time passed with no notification.
2. **Late reminder** — arrived more than 2 minutes after the prayer time.
3. **Duplicate reminder** — two notifications for the same prayer
   occurrence (especially after pressing Decline).
4. **Stopped reminders** — reminders ceased entirely; note whether the
   phone was rebooted, the app force-stopped, or a battery manager was
   involved, and whether the "Open the app to refresh salah reminders"
   notification appeared.
5. **Ringing problems** — vibration not stopping immediately on
   Answer/Decline, or continuing after leaving the screen.
6. **Wrong times** — comparison with their local masjid or trusted source
   (note the masjid's calculation method; differences within a few minutes
   are usually method offsets, addressed via manual adjustments).

## Directed scenarios (assign to specific testers)

- Timezone travel: at least one tester flies or drives across a timezone
  boundary and reports the first reminder after arrival.
- OEM battery restriction: Samsung/Xiaomi testers deliberately leave
  battery optimization ON for week one, then follow the in-app battery
  guidance for week two; compare delivery.
- Focus/DND (iOS): enable a Focus mode overnight; verify Fajr breaks
  through as Time Sensitive.
- Decline discipline: one tester declines every reminder for a day and
  confirms exactly one snooze per decline and no double reminders.
- Dismissal: back out of the full-screen reminder without choosing;
  confirm the unanswered follow-up still arrives and no snooze appears.

## Privacy rules for the beta

- Prayer-response history (answered/declined/dismissed/completed) stays on
  the device. It is NOT collected, synchronized, or included in diagnostics.
- The diagnostics report contains no GPS coordinates, no prayer history,
  and no personal identifiers; testers share it manually and voluntarily.
- Any future synchronization of prayer history would require explicit,
  separate, opt-in consent — out of scope for this beta.

## Exit criteria

- Zero reproducible missed/duplicate reminders on Pixel and Samsung across
  two weeks (excluding force-stop, which is an OS limitation — see
  ANDROID_REAL_DEVICE_TESTING.md).
- Late deliveries only where exact alarms were denied, with the in-app
  notice correctly shown.
- No crash reports in the notification action paths.
- iOS: full IOS_REAL_DEVICE_TESTING.md pass plus two clean weeks on
  TestFlight devices.
