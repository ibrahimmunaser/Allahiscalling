import Foundation

/// Shared UserDefaults keys for bridging AlarmKit Answer actions into Flutter.
enum AlarmKitBridgeKeys {
  static let suiteHint = "alarmkit_bridge"
  static let pendingAnswer = "alarmkit_pending_answer"
  static let pendingAnswerChanged = "alarmkit_pending_answer_changed"
}

/// Payload written when the user taps Answer on an AlarmKit alert.
struct PendingAlarmAnswer: Codable {
  let alarmId: String
  let prayerName: String
  let scheduledAtISO: String
  let prayerDisplayName: String
}
