import Flutter
import UIKit

#if canImport(FamilyControls)
import DeviceActivity
import FamilyControls
import ManagedSettings
import SwiftUI
#endif

/// Dart-facing bridge for App Guard on iOS: FamilyControls authorization,
/// the system app/category picker, and arming the per-prayer
/// `DeviceActivitySchedule`s that drive the Screen Time shield.
///
/// Requires Apple's Family Controls distribution entitlement to actually
/// work on a real build — see IOS_SCREEN_TIME_SETUP.md. Every method
/// degrades gracefully ("unsupported"/false) when the entitlement/SDK/OS
/// version isn't available, so the rest of the app is never affected.
class AppGuardManager: NSObject {
    static let channelName = "com.salahinvite.allah_invites_you_to_salah/app_guard_ios"

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        let instance = AppGuardManager()
        channel.setMethodCallHandler(instance.handle)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        #if canImport(FamilyControls)
        if #available(iOS 16.0, *) {
            switch call.method {
            case "isSupported":
                // FamilyControls imports on any iOS 16 SDK, including builds
                // that were not granted the distribution entitlement. The
                // Settings toggle must stay hidden in that case — requesting
                // authorization then fails immediately and App Review treats
                // the error as a broken core feature.
                result(screenTimeGuardEnabled())
            case "authorizationStatus":
                result(authorizationStatusString())
            case "requestAuthorization":
                Task {
                    do {
                        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                    } catch {
                        // Reported via the status string below either way.
                    }
                    await MainActor.run { result(self.authorizationStatusString()) }
                }
            case "presentPicker":
                presentPicker(result: result)
            case "setGuardEnabled":
                let args = call.arguments as? [String: Any]
                GuardShared.enabled = (args?["enabled"] as? Bool) ?? false
                result(nil)
            case "scheduleGuardWindows":
                scheduleGuardWindows(call: call, result: result)
            case "cancelAllGuardWindows":
                cancelAllGuardWindows(result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
            return
        }
        #endif
        // Pre-iOS 16 / SDK without FamilyControls: every method reports
        // "unsupported" rather than erroring, so the Dart side can simply
        // hide the feature.
        switch call.method {
        case "isSupported":
            result(false)
        case "authorizationStatus":
            result("unavailable")
        default:
            result(nil)
        }
    }

    /// True only when this build was signed with Family Controls. The
    /// Codemagic Screen Time setup script sets the Info.plist flag in the
    /// same step that injects the entitlement.
    private func screenTimeGuardEnabled() -> Bool {
        Bundle.main.object(forInfoDictionaryKey: "ScreenTimeGuardEnabled") as? Bool ?? false
    }

    #if canImport(FamilyControls)
    @available(iOS 16.0, *)
    private func authorizationStatusString() -> String {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .approved: return "approved"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unavailable"
        }
    }

    @available(iOS 16.0, *)
    private func presentPicker(result: @escaping FlutterResult) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController
        else {
            result(FlutterError(code: "no_root_vc", message: "No root view controller", details: nil))
            return
        }

        let model = GuardPickerModel()
        model.selection = GuardShared.loadSelection()
        let picker = GuardPickerView(model: model) { [weak self] in
            guard let self else { return }
            GuardShared.saveSelection(model.selection)
            root.dismiss(animated: true) {
                result([
                    "appsCount": model.selection.applicationTokens.count,
                    "categoriesCount": model.selection.categoryTokens.count,
                ])
            }
        }
        let hosting = UIHostingController(rootView: picker)
        hosting.modalPresentationStyle = .formSheet
        root.present(hosting, animated: true)
    }

    @available(iOS 16.0, *)
    private static let allPrayerActivityNames: [DeviceActivityName] =
        ["Fajr", "Dhuhr", "Asr", "Maghrib", "Isha"].map { DeviceActivityName($0) }

    /// Arguments: `{"windows": [{"prayer": "Dhuhr", "hour": 13, "minute": 7}, ...]}`.
    /// Replaces ALL five prayers' schedules every call (idempotent, mirrors
    /// the daily full reschedule already done for notifications/AlarmKit —
    /// see PrayerSchedulerService.rescheduleAll) rather than tracking diffs.
    @available(iOS 16.0, *)
    private func scheduleGuardWindows(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let center = DeviceActivityCenter()
        center.stopMonitoring(Self.allPrayerActivityNames)

        guard GuardShared.enabled else {
            result(nil)
            return
        }
        guard
            let args = call.arguments as? [String: Any],
            let windows = args["windows"] as? [[String: Any]]
        else {
            result(FlutterError(code: "bad_args", message: "windows is required", details: nil))
            return
        }

        for window in windows {
            guard
                let prayer = window["prayer"] as? String,
                let hour = window["hour"] as? Int,
                let minute = window["minute"] as? Int
            else { continue }

            var endMinute = minute + 15
            var endHour = hour
            if endMinute >= 60 {
                endMinute -= 60
                endHour += 1
            }
            endHour %= 24

            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: hour, minute: minute),
                intervalEnd: DateComponents(hour: endHour, minute: endMinute),
                repeats: true
            )
            do {
                try center.startMonitoring(DeviceActivityName(prayer), during: schedule)
            } catch {
                // A single prayer's schedule failing (e.g. the 20-schedule
                // device limit from some OTHER app) must never silently
                // abort the rest — Decline/skip, mirroring
                // PrayerSchedulerService's per-primary failure handling on
                // the notification side.
            }
        }
        result(nil)
    }

    @available(iOS 16.0, *)
    private func cancelAllGuardWindows(result: @escaping FlutterResult) {
        DeviceActivityCenter().stopMonitoring(Self.allPrayerActivityNames)
        GuardShared.enabled = false
        result(nil)
    }
    #endif
}

#if canImport(FamilyControls)
@available(iOS 16.0, *)
private class GuardPickerModel: ObservableObject {
    @Published var selection = FamilyActivitySelection()
}

@available(iOS 16.0, *)
private struct GuardPickerView: View {
    @ObservedObject var model: GuardPickerModel
    let onDone: () -> Void

    var body: some View {
        NavigationView {
            FamilyActivityPicker(selection: $model.selection)
                .navigationTitle("Apps to guard")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
    }
}
#endif
