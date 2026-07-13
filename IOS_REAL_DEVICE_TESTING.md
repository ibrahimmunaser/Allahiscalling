# iOS Real-Device Testing Checklist

iOS behavior in this app is **unverified until every item below passes on a
physical iPhone**. Simulators do not deliver scheduled notifications
reliably, do not enforce the 64-pending limit realistically, and cannot test
Focus, restart, or Time Sensitive delivery. Static analysis and simulator
runs prove nothing here.

Test device requirements: physical iPhone, iOS 15+ (Time Sensitive requires
15+), signed with a provisioning profile that includes the Time Sensitive
Notifications capability.

## One-time Xcode verification

1. Open `ios/Runner.xcworkspace` in Xcode.
2. Select the **Runner** target.
3. Open **Signing & Capabilities**.
4. Confirm **Time Sensitive Notifications** is present (backed by
   `ios/Runner/Runner.entitlements`).
5. Confirm the signing team and provisioning profile support it — there
   must be no signing warnings.

## Permissions

- [ ] First launch shows the notification permission prompt exactly once
- [ ] Denying notifications: app keeps working; Settings shows the
      "Notifications are not permitted" row; tapping it re-requests/settings
- [ ] First "Use current location" tap shows the location prompt exactly once
- [ ] Denying location: no repeated prompts on app resume (background the
      app and reopen 3×; zero permission dialogs may appear)
- [ ] Permanently denied location: dialog explains and offers "Open settings"

## Notification delivery

- [ ] Foreground: reminder appears at prayer time while the app is open
- [ ] Background: reminder appears with the app backgrounded
- [ ] Terminated: swipe the app away, wait for prayer time, reminder appears
- [ ] Notification title is "Allah Invites You to Salah", body
      "[Prayer] has entered"
- [ ] Pending count stays ≤ 60 (debug screen → Pending count) after several
      reschedules

## Actions

- [ ] Tapping the notification body opens the incoming salah screen
      (Answer green / Decline red)
- [ ] "Pray Now" action records the answer; NO immediate completion dialog;
      the gentle completion card appears on the home screen later
- [ ] "Decline" action (app terminated) schedules exactly ONE snooze after
      the configured minutes and the automatic follow-up does NOT also fire
      (no double reminder)
- [ ] Pressing Decline twice quickly does not create two snoozes
- [ ] Answer on the incoming screen cancels the "You have not answered yet"
      follow-up

## Time Sensitive / Focus

- [ ] Enable a Focus mode (e.g. Do Not Disturb) that silences the app; the
      prayer reminder still breaks through as Time Sensitive
- [ ] Settings → Notifications → app → toggle "Time Sensitive" OFF; the
      reminder still arrives as an ordinary notification (graceful fallback,
      nothing dropped)

## Timezone & DST

- [ ] Change device timezone (Settings → General → Date & Time); reopening
      the app reschedules and shows correct local times
- [ ] Select a city in a different timezone in-app; times and reminders match
      that city's IANA timezone
- [ ] If testable near a DST transition: reminder fires at the correct
      post-transition wall-clock time

## Restart & longevity

- [ ] Restart the iPhone; the next prayer reminder still arrives without
      opening the app (iOS keeps scheduled UNNotifications across restarts)
- [ ] Leave the app unopened for several days: reminders continue for the
      full scheduled window, then the "Open the app to refresh salah
      reminders" safety notification arrives after the last scheduled prayer
- [ ] Opening the app any time re-extends the window (verify on the debug
      screen: days of primary coverage returns to ~9–10 on iOS — the
      dynamic budget fills all safe capacity under the 60-notification cap)
- [ ] Debug screen / diagnostics: pending count stays ≤ 60 after repeated
      reschedules with an active snooze pending
