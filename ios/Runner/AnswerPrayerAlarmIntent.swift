import Foundation
import AppIntents

#if canImport(AlarmKit)
import AlarmKit

/// Opens the Flutter app and delivers the answered prayer payload when the
/// user taps "Answer" on an AlarmKit system alert.
@available(iOS 26.0, *)
struct AnswerPrayerAlarmIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Answer"
  static var description = IntentDescription("Opens the prayer call screen")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Alarm ID")
  var alarmID: String

  @Parameter(title: "Prayer")
  var prayerName: String

  @Parameter(title: "Scheduled At")
  var scheduledAtISO: String

  @Parameter(title: "Prayer Display Name")
  var prayerDisplayName: String

  init() {
    self.alarmID = ""
    self.prayerName = ""
    self.scheduledAtISO = ""
    self.prayerDisplayName = ""
  }

  init(
    alarmID: String,
    prayerName: String,
    scheduledAtISO: String,
    prayerDisplayName: String
  ) {
    self.alarmID = alarmID
    self.prayerName = prayerName
    self.scheduledAtISO = scheduledAtISO
    self.prayerDisplayName = prayerDisplayName
  }

  func perform() async throws -> some IntentResult {
    let pending = PendingAlarmAnswer(
      alarmId: alarmID,
      prayerName: prayerName,
      scheduledAtISO: scheduledAtISO,
      prayerDisplayName: prayerDisplayName.isEmpty
        ? "\(prayerName.prefix(1).uppercased())\(prayerName.dropFirst()) Prayer"
        : prayerDisplayName
    )
    if let data = try? JSONEncoder().encode(pending) {
      UserDefaults.standard.set(data, forKey: AlarmKitBridgeKeys.pendingAnswer)
      UserDefaults.standard.set(
        Date().timeIntervalSince1970,
        forKey: AlarmKitBridgeKeys.pendingAnswerChanged
      )
    }
    NotificationCenter.default.post(
      name: Notification.Name("AlarmKitAnswerPending"),
      object: nil
    )
    return .result()
  }
}
#endif
