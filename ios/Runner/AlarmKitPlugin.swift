import Flutter
import Foundation
import UIKit

#if canImport(AlarmKit)
import AlarmKit
import ActivityKit
import SwiftUI
import AppIntents
#endif

/// MethodChannel bridge for AlarmKit (iOS 26+) prayer alerts.
///
/// Channel: `com.salahinvite.allah_invites_you_to_salah/alarmkit`
final class AlarmKitPlugin: NSObject, FlutterPlugin {
  static let channelName = "com.salahinvite.allah_invites_you_to_salah/alarmkit"

  private var channel: FlutterMethodChannel?
  private var answerObserver: NSObjectProtocol?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = AlarmKitPlugin()
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    instance.startObservingAnswers()
  }

  deinit {
    if let answerObserver {
      NotificationCenter.default.removeObserver(answerObserver)
    }
  }

  private func startObservingAnswers() {
    answerObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name("AlarmKitAnswerPending"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.emitPendingAnswerIfAny()
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAlarmKitAvailable":
      result(Self.isAlarmKitRuntimeAvailable())
    case "authorizationStatus":
      result(Self.authorizationStatusString())
    case "requestAuthorization":
      Self.requestAuthorization(result: result)
    case "schedulePrayerAlarm":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad_args", message: "Expected map", details: nil))
        return
      }
      Self.schedulePrayerAlarm(args: args, result: result)
    case "cancelAlarm":
      guard let args = call.arguments as? [String: Any],
            let alarmId = args["alarmId"] as? String else {
        result(FlutterError(code: "bad_args", message: "alarmId required", details: nil))
        return
      }
      Self.cancelAlarm(alarmId: alarmId, result: result)
    case "cancelAllAlarms":
      Self.cancelAllAlarms(result: result)
    case "pendingAlarmIds":
      Self.pendingAlarmIds(result: result)
    case "getPendingAnswer":
      result(Self.readPendingAnswerMap())
    case "clearPendingAnswer":
      UserDefaults.standard.removeObject(forKey: AlarmKitBridgeKeys.pendingAnswer)
      result(nil)
    case "openSystemSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    case "validateSoundInBundle":
      let name = (call.arguments as? [String: Any])?["soundName"] as? String
      result(Self.soundExistsInBundle(name))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func emitPendingAnswerIfAny() {
    guard let map = Self.readPendingAnswerMap() else { return }
    channel?.invokeMethod("onAlarmAnswered", arguments: map)
  }

  // MARK: - Availability / auth

  private static func isAlarmKitRuntimeAvailable() -> Bool {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      return true
    }
    #endif
    return false
  }

  private static func authorizationStatusString() -> String {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      switch AlarmManager.shared.authorizationState {
      case .notDetermined: return "notDetermined"
      case .authorized: return "authorized"
      case .denied: return "denied"
      @unknown default: return "notDetermined"
      }
    }
    #endif
    return "unavailable"
  }

  private static func requestAuthorization(result: @escaping FlutterResult) {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      Task {
        do {
          let state = try await AlarmManager.shared.requestAuthorization()
          let value: String
          switch state {
          case .authorized: value = "authorized"
          case .denied: value = "denied"
          case .notDetermined: value = "notDetermined"
          @unknown default: value = "notDetermined"
          }
          await MainActor.run { result(value) }
        } catch {
          await MainActor.run {
            result(
              FlutterError(
                code: "auth_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          }
        }
      }
      return
    }
    #endif
    result("unavailable")
  }

  // MARK: - Schedule / cancel

  private static func schedulePrayerAlarm(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      Task {
        do {
          try await schedulePrayerAlarmAvailable(args: args)
          await MainActor.run { result(true) }
        } catch {
          await MainActor.run {
            result(
              FlutterError(
                code: "schedule_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          }
        }
      }
      return
    }
    #endif
    result(
      FlutterError(
        code: "unavailable",
        message: "AlarmKit requires iOS 26+",
        details: nil
      )
    )
  }

  #if canImport(AlarmKit)
  @available(iOS 26.0, *)
  private static func schedulePrayerAlarmAvailable(args: [String: Any]) async throws {
    guard let alarmIdString = args["alarmId"] as? String,
          let uuid = UUID(uuidString: alarmIdString),
          let prayerName = args["prayerName"] as? String,
          let scheduledAtMs = args["scheduledAtMs"] as? NSNumber else {
      throw NSError(
        domain: "AlarmKitPlugin",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing alarm fields"]
      )
    }

    let prayerDisplayName =
      (args["prayerDisplayName"] as? String)
      ?? "\(prayerName.prefix(1).uppercased())\(prayerName.dropFirst())"
    let title = (args["title"] as? String) ?? "Allah Is Calling"
    // AlarmKit's alert UI exposes a single title string; include the prayer
    // name so both required pieces of copy appear on the system alert.
    let alertTitle = "\(title) — \(prayerDisplayName) Prayer"
    let scheduledAtISO =
      (args["scheduledAtISO"] as? String)
      ?? ISO8601DateFormatter().string(
        from: Date(timeIntervalSince1970: scheduledAtMs.doubleValue / 1000.0)
      )
    let soundName = args["soundName"] as? String
    let fireDate = Date(timeIntervalSince1970: scheduledAtMs.doubleValue / 1000.0)

    // Replace any existing alarm with this id (prevents duplicates on reschedule).
    try? AlarmManager.shared.cancel(id: uuid)

    // System supplies the stop/Dismiss control; customize only the Answer
    // secondary button (non-deprecated Alert initializer).
    let answerButton = AlarmButton(
      text: "Answer",
      textColor: .white,
      systemImageName: "phone.fill"
    )
    let alertPresentation = AlarmPresentation.Alert(
      title: LocalizedStringResource(stringLiteral: alertTitle),
      secondaryButton: answerButton,
      secondaryButtonBehavior: .custom
    )
    let metadata = PrayerAlarmMetadata(
      prayerName: prayerName,
      prayerDisplayName: prayerDisplayName,
      scheduledAtISO: scheduledAtISO
    )
    let attributes = AlarmAttributes<PrayerAlarmMetadata>(
      presentation: AlarmPresentation(alert: alertPresentation),
      metadata: metadata,
      tintColor: Color(red: 0.055, green: 0.231, blue: 0.180) // AppTheme.deepGreen
    )

    let answerIntent = AnswerPrayerAlarmIntent(
      alarmID: alarmIdString,
      prayerName: prayerName,
      scheduledAtISO: scheduledAtISO,
      prayerDisplayName: "\(prayerDisplayName) Prayer"
    )

    typealias Configuration = AlarmManager.AlarmConfiguration<PrayerAlarmMetadata>
    let sound = resolvedSound(soundName: soundName)
    let configuration = Configuration.alarm(
      schedule: .fixed(fireDate),
      attributes: attributes,
      secondaryIntent: answerIntent,
      sound: sound
    )

    _ = try await AlarmManager.shared.schedule(id: uuid, configuration: configuration)
    rememberScheduledAlarm(id: alarmIdString)
  }

  private static let scheduledIdsKey = "alarmkit_scheduled_ids"

  private static func rememberScheduledAlarm(id: String) {
    var ids = Set(UserDefaults.standard.stringArray(forKey: scheduledIdsKey) ?? [])
    ids.insert(id)
    UserDefaults.standard.set(Array(ids), forKey: scheduledIdsKey)
  }

  private static func forgetScheduledAlarm(id: String) {
    var ids = Set(UserDefaults.standard.stringArray(forKey: scheduledIdsKey) ?? [])
    ids.remove(id)
    UserDefaults.standard.set(Array(ids), forKey: scheduledIdsKey)
  }
  #endif

  private static func cancelAlarm(alarmId: String, result: @escaping FlutterResult) {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      guard let uuid = UUID(uuidString: alarmId) else {
        result(
          FlutterError(code: "bad_id", message: "Invalid UUID", details: nil)
        )
        return
      }
      Task {
        try? AlarmManager.shared.cancel(id: uuid)
        forgetScheduledAlarm(id: alarmId)
        await MainActor.run { result(true) }
      }
      return
    }
    #endif
    result(true)
  }

  private static func cancelAllAlarms(result: @escaping FlutterResult) {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      Task {
        let ids = UserDefaults.standard.stringArray(forKey: scheduledIdsKey) ?? []
        for id in ids {
          if let uuid = UUID(uuidString: id) {
            try? AlarmManager.shared.cancel(id: uuid)
          }
        }
        UserDefaults.standard.set([String](), forKey: scheduledIdsKey)
        await MainActor.run { result(true) }
      }
      return
    }
    #endif
    result(true)
  }

  private static func pendingAlarmIds(result: @escaping FlutterResult) {
    let ids = UserDefaults.standard.stringArray(forKey: "alarmkit_scheduled_ids") ?? []
    result(ids)
  }

  // MARK: - Helpers

  private static func readPendingAnswerMap() -> [String: Any]? {
    guard let data = UserDefaults.standard.data(forKey: AlarmKitBridgeKeys.pendingAnswer),
          let pending = try? JSONDecoder().decode(PendingAlarmAnswer.self, from: data)
    else {
      return nil
    }
    return [
      "alarmId": pending.alarmId,
      "prayerName": pending.prayerName,
      "scheduledAtISO": pending.scheduledAtISO,
      "prayerDisplayName": pending.prayerDisplayName,
    ]
  }

  private static func soundExistsInBundle(_ soundName: String?) -> Bool {
    guard let soundName, !soundName.isEmpty else { return false }
    let ns = soundName as NSString
    let base = ns.deletingPathExtension
    let ext = ns.pathExtension
    if !ext.isEmpty {
      return Bundle.main.url(forResource: base, withExtension: ext) != nil
    }
    for candidate in ["caf", "wav", "aiff", "mp3", "m4a"] {
      if Bundle.main.url(forResource: soundName, withExtension: candidate) != nil {
        return true
      }
    }
    return Bundle.main.url(forResource: soundName, withExtension: nil) != nil
  }

  #if canImport(AlarmKit)
  @available(iOS 26.0, *)
  private static func resolvedSound(soundName: String?) -> AlertConfiguration.AlertSound {
    guard let soundName, soundExistsInBundle(soundName) else {
      return .default
    }
    let ns = soundName as NSString
    let named = ns.pathExtension.isEmpty ? soundName : ns.deletingPathExtension
    return .named(named)
  }
  #endif
}

#if canImport(AlarmKit)
/// Codable metadata attached to each prayer AlarmKit alert.
@available(iOS 26.0, *)
struct PrayerAlarmMetadata: AlarmMetadata {
  var prayerName: String
  var prayerDisplayName: String
  var scheduledAtISO: String
}
#endif
